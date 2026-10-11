import type { ViewState } from "../../protocol";
import { acknowledgment, decrypt, empty, unbase64 } from "../../web/session";
import { expect, test } from "./fixtures";
import { Peer } from "./peer";

test("queued snapshot packets are delivered once and in order", async ({
  relay,
}) => {
  const { peer } = await relay.connect("reader");
  const first = peer.next("state");
  for (const seq of [1, 2]) {
    peer.socket.dispatchEvent(
      new MessageEvent("message", {
        data: JSON.stringify({ box: "probe", seq, type: "state" }),
      })
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
  expect(packet).toEqual(sent);
  expect(await decrypt(relay.key, relay.room.id, packet)).toEqual(state);
  first.peer.send(
    await acknowledgment(relay.key, relay.room.id, first.client, packet.seq, 1)
  );
  const ack = await relay.writer.next("ack");
  expect(ack.client).toBe(first.client);
  const bytes = unbase64(ack.box);
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
  expect(rejectedClose.code).toBe(1008);
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

test("a replacement writer closes its predecessor and publishes to existing readers", async ({
  relay,
}) => {
  const reader = await relay.connect("reader");
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
  expect(await reader.peer.next("state")).toEqual(valid);
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
    seq: valid.seq + 1,
  };
  relay.writer.send(extended);
  expect(await reader.peer.next("state")).toEqual(extended);
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
  expect(await replay.peer.next("state")).toEqual(extended);
});
