import { acknowledgment, decrypt, empty, unbase64 } from "../../web/session";
import type { ViewState } from "../../web/session";
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
