import { base64urlnopad, hex } from "@scure/base";
import { DurableObject } from "cloudflare:workers";
import type { MiddlewareHandler } from "hono";
import { HonoBase } from "hono/hono-base";
import { TrieRouter } from "hono/router/trie-router";
import { secureHeaders } from "hono/secure-headers";
import { parse } from "valibot";

import {
  AckPacketSchema,
  AuthMessageSchema,
  maxPacketLength,
  StatePacketSchema,
} from "../protocol";

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
const secret = () =>
  base64urlnopad.encode(crypto.getRandomValues(new Uint8Array(32)));
const hash = async (value: string) =>
  hex.encode(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
    )
  );
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

const app = new HonoBase<{ Bindings: Env }>({
  // Room URLs deliberately use the raw path; encoded IDs are not room aliases.
  getPath: (request) => new URL(request.url).pathname,
  router: new TrieRouter(),
});
const roomPath = "/rooms/:room{[0-9a-f-]{36}}";
const rateLimit =
  (bucket: "create" | "connect"): MiddlewareHandler<{ Bindings: Env }> =>
  async (context, proceed) => {
    const ip = context.req.header("CF-Connecting-IP") ?? "local";
    const limit = await context.env.ROOM_LIMIT.limit({
      key: `${bucket}:${ip}`,
    });
    if (!limit.success) {
      return error();
    }
    await proceed();
    return context.res;
  };
// A reconnect burst must never prevent an authenticated publisher from
// deleting its room. Only creation and new socket attempts share IP limits.
app.use("/rooms", rateLimit("create"));
app.use(`${roomPath}/socket`, rateLimit("connect"));
app.post("/rooms", async (context) => {
  const id = crypto.randomUUID();
  const writer = secret();
  const reader = secret();
  const session: Session = {
    expires: Date.now() + ROOM_TTL,
    readerHash: await hash(reader),
    writerHash: await hash(writer),
  };
  await context.env.ROOMS.getByName(id).fetch(
    new Request("https://room/init", {
      body: JSON.stringify(session),
      method: "POST",
    })
  );
  return context.json(
    { id, reader, writer },
    { headers: { "Cache-Control": "no-store" } }
  );
});
app.on(
  "ALL",
  [`${roomPath}/socket`, `${roomPath}/end`],
  async (context) =>
    await context.env.ROOMS.getByName(context.req.param("room")).fetch(
      context.req.raw
    )
);
app.all("/:invalid{rooms.*}", error);
app.all(
  "*",
  secureHeaders({
    contentSecurityPolicy: {
      baseUri: ["'none'"],
      connectSrc: ["'self'", "ws:", "wss:"],
      defaultSrc: ["'self'"],
      frameAncestors: ["'none'"],
      imgSrc: ["'self'", "data:"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'"],
    },
    crossOriginOpenerPolicy: false,
    crossOriginResourcePolicy: false,
    originAgentCluster: false,
    removePoweredBy: false,
    strictTransportSecurity: false,
    xDnsPrefetchControl: false,
    xDownloadOptions: false,
    xFrameOptions: false,
    xPermittedCrossDomainPolicies: false,
    xXssProtection: false,
  }),
  async (context) => {
    const response = await context.env.ASSETS.fetch(context.req.raw);
    return new Response(response.body, response);
  }
);
export default app;

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
      if (typeof message !== "string" || message.length > maxPacketLength) {
        throw new Error("Invalid room message");
      }
      const session = await this.ctx.storage.get<Session>("session");
      if (!session || session.expires <= Date.now()) {
        throw new Error("Invalid room message");
      }
      const body: unknown = JSON.parse(message);
      const peer = attachment(socket);
      if (!peer.role) {
        const auth = parse(AuthMessageSchema, body);
        const digest = await hash(auth.token);
        if (auth.role === "writer" && digest === session.writerHash) {
          peer.role = "writer";
        } else if (auth.role === "reader" && digest === session.readerHash) {
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
        const ack = parse(AckPacketSchema, body);
        if (ack.seq > (latest?.seq ?? 0)) {
          throw new Error("Invalid room message");
        }
        for (const writer of this.ctx.getWebSockets()) {
          if (attachment(writer).role === "writer") {
            notify(
              writer,
              JSON.stringify({
                box: ack.box,
                client: peer.id,
                seq: ack.seq,
                type: "ack",
              })
            );
          }
        }
        return;
      }
      const state = parse(StatePacketSchema, body);
      if (peer.role !== "writer" || state.seq <= (latest?.seq ?? 0)) {
        throw new Error("Invalid room message");
      }
      // Small storage values also support snapshots larger than one KV value.
      const chunks = Math.ceil(message.length / 64_000);
      await this.ctx.storage.transaction(async (transaction) => {
        const values: Record<string, unknown> = {
          snapshot: { chunks, seq: state.seq },
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
