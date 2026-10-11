import { DurableObject } from "cloudflare:workers";

interface Session {
  writerHash: string;
  readerHash: string;
  expires: number;
}
interface Peer {
  id: string;
  role?: "writer" | "reader";
}
interface Latest {
  seq: number;
  chunks: number;
}
const ROOM_TTL = 2 * 60 * 60 * 1000;
const MAX_PACKET = 4_000_000;
const secret = () =>
  btoa(String.fromCodePoint(...crypto.getRandomValues(new Uint8Array(32))))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
const hash = async (value: string) =>
  Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
    ),
    (n) => n.toString(16).padStart(2, "0")
  ).join("");
const error = () =>
  new Response("Couldn't complete that. Try again.", { status: 400 });
function closePeer(socket: WebSocket, code: number, reason?: string) {
  try {
    socket.close(code, reason);
  } catch {
    /* A closing peer may already be gone. */
  }
}
function notify(socket: WebSocket, message: string) {
  if (socket.readyState !== WebSocket.OPEN) {
    return;
  }
  try {
    socket.send(message);
  } catch {
    closePeer(socket, 1011);
  }
}
function attachment(socket: WebSocket): Peer {
  // Only this Durable Object writes attachments, always using the Peer shape.
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  return socket.deserializeAttachment() as Peer;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const match =
      /^\/rooms\/(?<room>[0-9a-f-]{36})\/(?<action>socket|end)$/u.exec(
        url.pathname
      );
    const room = match?.groups?.["room"];
    const action = match?.groups?.["action"];
    // A reconnect burst must never prevent an authenticated publisher from
    // deleting its room. Only creation and new socket attempts share IP limits.
    if (url.pathname === "/rooms" || action === "socket") {
      const ip = request.headers.get("CF-Connecting-IP") ?? "local";
      const bucket = url.pathname === "/rooms" ? "create" : "connect";
      const limit = await env.ROOM_LIMIT.limit({ key: `${bucket}:${ip}` });
      if (!limit.success) {
        return error();
      }
    }
    if (url.pathname === "/rooms" && request.method === "POST") {
      const id = crypto.randomUUID();
      const writer = secret();
      const reader = secret();
      const writerHash = await hash(writer);
      const readerHash = await hash(reader);
      const session: Session = {
        expires: Date.now() + ROOM_TTL,
        readerHash,
        writerHash,
      };
      await env.ROOMS.getByName(id).fetch(
        new Request("https://room/init", {
          body: JSON.stringify(session),
          method: "POST",
        })
      );
      return Response.json(
        { id, reader, writer },
        { headers: { "Cache-Control": "no-store" } }
      );
    }
    if (room !== undefined) {
      return await env.ROOMS.getByName(room).fetch(request);
    }
    if (url.pathname.startsWith("/rooms")) {
      return error();
    }
    const response = await env.ASSETS.fetch(request);
    const secured = new Response(response.body, response);
    secured.headers.set("Referrer-Policy", "no-referrer");
    secured.headers.set("X-Content-Type-Options", "nosniff");
    secured.headers.set(
      "Content-Security-Policy",
      "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
    );
    return secured;
  },
};

export class Room extends DurableObject<Env> {
  override async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/init") {
      const session = await request.json<Session>();
      await this.ctx.storage.put("session", session);
      await this.ctx.storage.setAlarm(session.expires);
      return new Response("OK");
    }
    const session = await this.ctx.storage.get<Session>("session");
    if (!session || session.expires <= Date.now()) {
      return error();
    }
    if (path.endsWith("/end") && request.method === "POST") {
      const token =
        request.headers.get("Authorization")?.replace(/^Bearer /u, "") ?? "";
      if ((await hash(token)) !== session.writerHash) {
        return error();
      }
      await this.end();
      return new Response("OK");
    }
    if (
      !path.endsWith("/socket") ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket" ||
      this.ctx.getWebSockets().length >= 32
    ) {
      return error();
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({ id: crypto.randomUUID() } satisfies Peer);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  override async webSocketMessage(
    socket: WebSocket,
    message: string | ArrayBuffer
  ) {
    try {
      if (typeof message !== "string" || message.length > MAX_PACKET) {
        throw new Error("Invalid room message");
      }
      const session = await this.ctx.storage.get<Session>("session");
      if (!session || session.expires <= Date.now()) {
        throw new Error("Invalid room message");
      }
      const body: unknown = JSON.parse(message);
      if (typeof body !== "object" || body === null || !("type" in body)) {
        throw new Error("Invalid room message");
      }
      const peer = attachment(socket);
      if (!peer.role) {
        if (
          body.type !== "auth" ||
          !("token" in body) ||
          typeof body.token !== "string" ||
          body.token.length > 100 ||
          !("role" in body)
        ) {
          throw new Error("Invalid room message");
        }
        const digest = await hash(body.token);
        if (body.role === "writer" && digest === session.writerHash) {
          peer.role = "writer";
        } else if (body.role === "reader" && digest === session.readerHash) {
          peer.role = "reader";
        } else {
          throw new Error("Invalid room message");
        }
        if (peer.role === "writer") {
          for (const old of this.ctx.getWebSockets()) {
            if (old !== socket && attachment(old).role === "writer") {
              closePeer(old, 1000);
            }
          }
        }
        socket.serializeAttachment(peer);
        notify(socket, JSON.stringify({ client: peer.id, type: "ready" }));
        this.peersChanged();
        if (peer.role === "reader") {
          const latest = await this.latest();
          if (latest !== undefined && latest.length > 0) {
            notify(socket, latest);
          }
          if (
            !this.ctx
              .getWebSockets()
              .some(
                (s) =>
                  s.readyState === WebSocket.OPEN &&
                  attachment(s).role === "writer"
              )
          ) {
            notify(socket, '{"type":"offline"}');
          }
        }
        return;
      }
      const latest = await this.ctx.storage.get<Latest>("snapshot");
      if (peer.role === "reader") {
        if (
          body.type !== "ack" ||
          !("seq" in body) ||
          typeof body.seq !== "number" ||
          !Number.isSafeInteger(body.seq) ||
          body.seq < 1 ||
          body.seq > (latest?.seq ?? 0) ||
          !("box" in body) ||
          typeof body.box !== "string" ||
          body.box.length > 1024 ||
          !/^[A-Za-z0-9+/]+=*$/u.test(body.box)
        ) {
          throw new Error("Invalid room message");
        }
        for (const writer of this.ctx.getWebSockets()) {
          if (attachment(writer).role === "writer") {
            notify(
              writer,
              JSON.stringify({
                box: body.box,
                client: peer.id,
                seq: body.seq,
                type: "ack",
              })
            );
          }
        }
        return;
      }
      if (
        peer.role !== "writer" ||
        body.type !== "state" ||
        !("seq" in body) ||
        typeof body.seq !== "number" ||
        !Number.isSafeInteger(body.seq) ||
        body.seq <= (latest?.seq ?? 0) ||
        !("box" in body) ||
        typeof body.box !== "string" ||
        !/^[A-Za-z0-9+/]+=*$/u.test(body.box)
      ) {
        throw new Error("Invalid room message");
      }
      // Small storage values also support snapshots larger than one KV value.
      const chunks = Math.ceil(message.length / 64_000);
      await this.ctx.storage.transaction(async (transaction) => {
        const values: Record<string, unknown> = {
          snapshot: { chunks, seq: body.seq },
        };
        for (let i = 0; i < chunks; i += 1) {
          values[`part:${i}`] = message.slice(i * 64_000, (i + 1) * 64_000);
        }
        await transaction.put(values);
        for (let i = chunks; i < (latest?.chunks ?? 0); i += 1) {
          await transaction.delete(`part:${i}`);
        }
        if (session.expires - Date.now() < ROOM_TTL - 60_000) {
          session.expires = Date.now() + ROOM_TTL;
          await transaction.put("session", session);
          await transaction.setAlarm(session.expires);
        }
      });
      for (const reader of this.ctx.getWebSockets()) {
        if (attachment(reader).role === "reader") {
          notify(reader, message);
        }
      }
    } catch {
      closePeer(socket, 1008, "Couldn't complete that. Try again.");
    }
  }

  private async latest(): Promise<string | undefined> {
    const meta = await this.ctx.storage.get<Latest>("snapshot");
    if (!meta) {
      return undefined;
    }
    const keys = Array.from({ length: meta.chunks }, (_, i) => `part:${i}`);
    const parts = await this.ctx.storage.get<string>(keys);
    return keys.map((key) => parts.get(key) ?? "").join("");
  }
  private peersChanged() {
    const sockets = this.ctx
      .getWebSockets()
      .filter((socket) => socket.readyState === WebSocket.OPEN);
    const readers = sockets
      .filter((socket) => attachment(socket).role === "reader")
      .map((socket) => attachment(socket).id);
    for (const writer of sockets) {
      if (attachment(writer).role === "writer") {
        notify(writer, JSON.stringify({ readers, type: "peers" }));
      }
    }
  }
  override webSocketClose(socket: WebSocket) {
    this.peersChanged();
    if (
      attachment(socket).role === "writer" &&
      !this.ctx
        .getWebSockets()
        .some(
          (other) =>
            other !== socket &&
            other.readyState === WebSocket.OPEN &&
            attachment(other).role === "writer"
        )
    ) {
      for (const reader of this.ctx.getWebSockets()) {
        if (attachment(reader).role === "reader") {
          notify(reader, '{"type":"offline"}');
        }
      }
    }
  }
  override webSocketError(socket: WebSocket) {
    closePeer(socket, 1011);
    this.peersChanged();
  }
  override async alarm() {
    const session = await this.ctx.storage.get<Session>("session");
    if (session && session.expires > Date.now()) {
      await this.ctx.storage.setAlarm(session.expires);
      return;
    }
    await this.end();
  }
  private async end() {
    // Deletion is authoritative; notifying disconnected clients is best effort.
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    for (const socket of this.ctx.getWebSockets()) {
      notify(socket, '{"type":"ended"}');
      closePeer(socket, 1000);
    }
  }
}
