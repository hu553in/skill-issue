import { expect, test } from "bun:test";

import { ValiError } from "valibot";

import { Peer } from "./e2e/peer";

for (const [name, frame, errorType] of [
  ["malformed JSON", "{broken", SyntaxError],
  ["a binary frame", new Uint8Array([1, 2, 3]), TypeError],
  ["JSON null", "null", ValiError],
  ["a JSON primitive", "1", ValiError],
  ["a missing discriminator", "{}", ValiError],
  ["a nonstring discriminator", '{"type":1}', ValiError],
] as const) {
  test(`peer reports ${name} to pending and subsequent reads`, async () => {
    const server = Bun.serve({
      fetch(request, instance) {
        return instance.upgrade(request, {
          headers: { "Sec-WebSocket-Protocol": "skill-issue" },
        })
          ? undefined
          : new Response("Upgrade required", { status: 400 });
      },
      hostname: "127.0.0.1",
      port: 0,
      websocket: {
        message() {},
        open(socket) {
          socket.send(frame);
        },
      },
    });
    const peer = new Peer(
      server.url.origin.replace(/^http/u, "ws"),
      "writer",
      "w".repeat(43)
    );
    try {
      const results = await Promise.allSettled([
        peer.next("ready"),
        peer.next("peers"),
      ]);
      expect(results).toMatchObject([
        { reason: expect.any(errorType) as unknown, status: "rejected" },
        { reason: expect.any(errorType) as unknown, status: "rejected" },
      ]);
      expect(peer.next("state")).rejects.toBeInstanceOf(errorType);
    } finally {
      await server.stop(true);
      await peer.closed;
    }
  });
}
