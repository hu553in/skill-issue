import { once } from "node:events";
import { connect, createServer } from "node:net";

import { base64 } from "@scure/base";

import type { ViewState } from "../../protocol";
import { acknowledgment, decrypt, empty } from "../../web/session";
import { expect, test } from "./fixtures";
import { Peer } from "./peer";

async function silentPeer(base: string, room: string, ip: string) {
  const url = new URL(base);
  // Raw TCP peers never acknowledge WebSocket Close frames.
  const socket = connect(Number(url.port), url.hostname);
  const response = Promise.withResolvers<number>();
  let bytes = Buffer.alloc(0);
  let upgraded = false;
  socket.setTimeout(5000, () => {
    socket.destroy(new Error("Timed out opening the silent WebSocket"));
  });
  socket.once("error", response.reject);
  socket.once("close", () => {
    if (!upgraded) {
      response.reject(new Error("Socket closed before the HTTP response"));
    }
  });
  socket.once("connect", () => {
    socket.write(
      `GET /rooms/${room}/socket HTTP/1.1\r\nHost: ${url.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nCF-Connecting-IP: ${ip}\r\n\r\n`
    );
  });
  socket.on("data", (chunk) => {
    bytes = Buffer.concat([
      bytes,
      typeof chunk === "string" ? Buffer.from(chunk) : chunk,
    ]);
    if (!upgraded) {
      const end = bytes.indexOf("\r\n\r\n");
      if (end === -1) {
        return;
      }
      const status = Number(bytes.toString("ascii", 0, end).split(" ")[1]);
      bytes = bytes.subarray(end + 4);
      upgraded = true;
      socket.setTimeout(0);
      response.resolve(status);
    }
  });
  try {
    const status = await response.promise;
    return { socket, status };
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

test("silent peers report a truncated HTTP response instead of hanging", async () => {
  const server = createServer((socket) => {
    socket.end("HTTP/1.1 400 Bad Request\r\n");
  });
  server.listen(0, "127.0.0.1");
  try {
    await once(server, "listening");
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("The fixture did not bind a TCP port");
    }
    await expect(
      silentPeer(
        `http://127.0.0.1:${address.port}`,
        "00000000-0000-0000-0000-000000000001",
        "192.0.2.1"
      )
    ).rejects.toThrow("Socket closed before the HTTP response");
  } finally {
    server.close();
  }
});

test("queued snapshot packets are delivered once and in order", async ({
  relay,
}) => {
  const { peer } = await relay.connect("reader");
  const first = peer.next("state");
  for (const seq of [1, 2]) {
    peer.socket.emit(
      "message",
      JSON.stringify({ box: "probe", seq, type: "state" })
    );
  }
  const firstPacket = await first;
  const secondPacket = await peer.next("state");
  expect(firstPacket.seq).toBe(1);
  expect(secondPacket.seq).toBe(2);
});

test("large snapshots, replacement snapshots and per-reader acknowledgments survive reconnects", async ({
  relay,
}) => {
  const first = await relay.connect("reader");
  const state: ViewState = {
    ...empty,
    answers: [
      {
        id: "large",
        status: "complete",
        text: "A private answer.\n".repeat(12_000),
      },
    ],
    command: { answerID: "large", direction: 1, id: 1 },
    live: true,
    selectedID: "large",
  };
  const sent = await relay.publish(state);
  const packet = await first.peer.next("state");
  expect(packet).toEqual({ ...sent, publisher: relay.publisher });
  expect(await decrypt(relay.key, relay.room.id, packet)).toEqual(state);
  first.peer.send(
    await acknowledgment(relay.key, relay.room.id, first.client, packet.seq, 1)
  );
  const ack = await relay.writer.next("ack");
  expect(ack.client).toBe(first.client);
  const bytes = base64.decode(ack.box);
  const open = async (client: string) =>
    await crypto.subtle.decrypt(
      {
        additionalData: new TextEncoder().encode(
          `${relay.room.id}:ack:${client}:${ack.seq}`
        ),
        iv: bytes.slice(0, 12),
        name: "AES-GCM",
      },
      relay.key,
      bytes.slice(12)
    );
  expect(
    JSON.parse(new TextDecoder().decode(await open(first.client)))
  ).toEqual({ command: 1, seq: packet.seq });

  const late = await relay.connect("reader");
  expect(await late.peer.next("state")).toEqual(packet);
  await expect(open(late.client)).rejects.toThrow();
  late.peer.send(
    await acknowledgment(relay.key, relay.room.id, late.client, packet.seq, 1)
  );
  const lateAck = await relay.writer.next("ack");
  expect(lateAck.client).toBe(late.client);
  const small: ViewState = {
    ...state,
    answers: [
      { id: "small", status: "complete", text: "A shorter replacement." },
    ],
    selectedID: "small",
    selection: 1,
  };
  await relay.publish(small);
  expect(
    await decrypt(relay.key, relay.room.id, await late.peer.next("state"))
  ).toEqual(small);
  await late.peer.close();
  const reconnected = await relay.connect("reader");
  expect(
    await decrypt(
      relay.key,
      relay.room.id,
      await reconnected.peer.next("state")
    )
  ).toEqual(small);
});

test("selection requests use authenticated reader identities and cannot cross publisher connections", async ({
  relay,
}) => {
  const reader = await relay.connect("reader");
  const snapshot = await relay.publish({ ...empty, live: true });
  expect(await reader.peer.next("state")).toEqual({
    ...snapshot,
    publisher: relay.publisher,
  });
  const select = {
    box: "YQ==",
    id: 1,
    publisher: relay.publisher,
    type: "select",
  };
  reader.peer.send({ ...select, client: "forged-reader" });
  expect(await relay.writer.next("select")).toEqual({
    ...select,
    client: reader.client,
  });

  await relay.writer.close();
  expect(await reader.peer.next("offline")).toEqual({ type: "offline" });
  const offlineReader = await relay.connect("reader");
  expect(await offlineReader.peer.next("state")).toEqual({
    ...snapshot,
    publisher: null,
  });
  reader.peer.send({ ...select, id: 2 });

  const replacement = await relay.connect("writer");
  const reconnected = await relay.connect("reader");
  expect(await reconnected.peer.next("state")).toEqual({
    ...snapshot,
    publisher: replacement.client,
  });
  // An old connection's delayed request must not be replayed on its replacement.
  reader.peer.send({ ...select, id: 3 });
  reader.peer.send({ ...select, id: 4, publisher: replacement.client });
  expect(await replacement.peer.next("select")).toEqual({
    ...select,
    client: reader.client,
    id: 4,
    publisher: replacement.client,
  });
  const fresh = await relay.publish({ ...empty, live: true }, replacement.peer);
  expect(await reader.peer.next("state")).toEqual({
    ...fresh,
    publisher: replacement.client,
  });
});

test("malformed selection requests close only their reader", async ({
  relay,
}) => {
  const valid = {
    box: "YQ==",
    id: 1,
    publisher: relay.publisher,
    type: "select",
  };
  for (const fields of [
    { id: 0 },
    { publisher: null },
    { box: "A".repeat(1025) },
  ]) {
    // Each malformed peer closes independently while the writer remains available.
    // oxlint-disable-next-line no-await-in-loop
    const reader = await relay.connect("reader");
    reader.peer.send({ ...valid, ...fields });
    // oxlint-disable-next-line no-await-in-loop
    const closed = await reader.peer.closed;
    expect(closed.code).toBe(1008);
  }
  const reader = await relay.connect("reader");
  reader.peer.send(valid);
  expect(await relay.writer.next("select")).toEqual({
    ...valid,
    client: reader.client,
  });
});

test("reader tokens cannot authenticate writers, publish snapshots or end the room", async ({
  relay,
  request,
}) => {
  const rejected = new Peer(
    `${relay.base.replace(/^http/u, "ws")}/rooms/${relay.room.id}/socket`,
    "writer",
    relay.room.reader
  );
  relay.peers.push(rejected);
  const rejectedClose = await rejected.closed;
  expect(rejectedClose.code).toBe(1006);
  const reader = await relay.connect("reader");
  const packet = await relay.publish({ ...empty, live: true });
  await reader.peer.next("state");
  reader.peer.send({ ...packet, seq: packet.seq + 1 });
  const readerClose = await reader.peer.closed;
  expect(readerClose.code).toBe(1008);
  const denied = await fetch(`${relay.base}/rooms/${relay.room.id}/end`, {
    headers: { Authorization: `Bearer ${relay.room.reader}` },
    method: "POST",
  });
  expect(denied.status).toBe(400);
  await relay.end();
  expect(await relay.writer.next("ended")).toEqual({ type: "ended" });
  const writerClose = await relay.writer.closed;
  expect(writerClose.code).toBe(1000);
  const deleted = await request.get(
    `${relay.base}/rooms/${relay.room.id}/socket`,
    {
      headers: { Upgrade: "websocket" },
    }
  );
  expect(deleted.status()).toBe(400);
});

test("unauthorized raw sockets are denied before upgrade across repeated no-close-ack waves", async ({
  relay,
}) => {
  const reader = await relay.connect("reader");
  const attempts: Awaited<ReturnType<typeof silentPeer>>[] = [];
  try {
    for (let wave = 0; wave < 3; wave += 1) {
      // Distinct fixture IPs isolate authorization from the per-IP rate quota.
      // oxlint-disable-next-line no-await-in-loop
      const results = await Promise.allSettled(
        Array.from(
          { length: 30 },
          async (_, index) =>
            await silentPeer(
              relay.base,
              relay.room.id,
              `192.0.${wave + 2}.${index + 1}`
            )
        )
      );
      const peers = results.flatMap((result) =>
        result.status === "fulfilled" ? [result.value] : []
      );
      attempts.push(...peers);
      for (const result of results) {
        if (result.status === "rejected") {
          throw result.reason;
        }
      }
      expect(peers.map((peer) => peer.status)).toEqual(
        Array.from({ length: 30 }, () => 400)
      );
    }
    const replacement = await relay.connect("writer");
    const replaced = await relay.writer.closed;
    expect(replaced.code).toBe(1000);
    const state = {
      ...empty,
      answers: [
        {
          id: "replacement",
          status: "complete" as const,
          text: "A new publisher.",
        },
      ],
      live: true,
      selectedID: "replacement",
    };
    await relay.publish(state, replacement.peer);
    expect(
      await decrypt(relay.key, relay.room.id, await reader.peer.next("state"))
    ).toEqual(state);
  } finally {
    for (const peer of attempts) {
      peer.socket.destroy();
    }
  }
});

test("HTTP routes and asset security headers match the deployed Worker contract", async ({
  request,
}) => {
  const viewer = await request.get("/");
  expect(viewer.status()).toBe(200);
  expect(viewer.headers()["referrer-policy"]).toBe("no-referrer");
  expect(viewer.headers()["x-content-type-options"]).toBe("nosniff");
  expect(
    viewer.headers()["content-security-policy"]?.split("; ").toSorted()
  ).toEqual(
    [
      "base-uri 'none'",
      "connect-src 'self' ws: wss:",
      "default-src 'self'",
      "frame-ancestors 'none'",
      "img-src 'self' data:",
      "script-src 'self'",
      "style-src 'self'",
    ].toSorted()
  );
  for (const path of [
    "/rooms/",
    "/rooms-extra",
    "/rooms/id/socket",
    "/rooms/00000000-0000-0000-0000-000000000001/socket/",
    "/rooms/%300000000-0000-0000-0000-000000000001/socket",
  ]) {
    // Verify each HTTP response before issuing the next malformed request.
    // oxlint-disable-next-line no-await-in-loop
    const invalid = await request.get(path);
    expect(invalid.status()).toBe(400);
    // oxlint-disable-next-line no-await-in-loop
    expect(await invalid.text()).toBe("Couldn't complete that. Try again.");
    expect(invalid.headers()["content-security-policy"]).toBeUndefined();
  }
});

test("invalid packets close only their peer while extended snapshots and acknowledgments retain compatibility", async ({
  relay,
}) => {
  const valid = await relay.publish({ ...empty, live: true });
  const reader = await relay.connect("reader");
  expect(await reader.peer.next("state")).toEqual({
    ...valid,
    publisher: relay.publisher,
  });
  const offender = new Peer(
    `${relay.base.replace(/^http/u, "ws")}/rooms/${relay.room.id}/socket?_pk=attacker-chosen`,
    "reader",
    relay.room.reader
  );
  relay.peers.push(offender);
  const ready = await offender.next("ready");
  expect(ready.client).toMatch(/^[0-9a-f-]{36}$/u);
  expect(ready.client).not.toBe("attacker-chosen");
  offender.send({ box: "YQ==", seq: valid.seq + 1, type: "ack" });
  const ackClose = await offender.closed;
  expect(ackClose.code).toBe(1008);
  const extended = {
    ...valid,
    extension: { ignored: true },
    publisher: "forged-publisher",
    seq: valid.seq + 1,
  };
  relay.writer.send(extended);
  expect(await reader.peer.next("state")).toEqual({
    ...extended,
    publisher: relay.publisher,
  });
  reader.peer.send({
    box: "YQ==",
    ignored: true,
    seq: extended.seq,
    type: "ack",
  });
  expect(await relay.writer.next("ack")).toEqual({
    box: "YQ==",
    client: reader.client,
    seq: extended.seq,
    type: "ack",
  });
  const replacement = await relay.connect("writer");
  replacement.peer.send({ ...extended, seq: extended.seq });
  const staleClose = await replacement.peer.closed;
  expect(staleClose.code).toBe(1008);
  const restored = await relay.connect("writer");
  restored.peer.send({ ...extended, box: "?", seq: extended.seq + 1 });
  const malformedClose = await restored.peer.closed;
  expect(malformedClose.code).toBe(1008);
  const replay = await relay.connect("reader");
  expect(await replay.peer.next("state")).toEqual({
    ...extended,
    publisher: null,
  });
});
