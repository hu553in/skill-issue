import { expect, test } from "bun:test";

import { RelaySession } from "./relay";

for (const cleanupStatus of [200, 503]) {
  test(`relay startup preserves the handshake error when cleanup returns ${cleanupStatus}`, async () => {
    const room = "00000000-0000-0000-0000-000000000001";
    const requests: string[] = [];
    const server = Bun.serve({
      fetch(request) {
        const path = new URL(request.url).pathname;
        requests.push(path);
        if (path === "/rooms") {
          return Response.json({
            id: room,
            reader: "r".repeat(43),
            writer: "w".repeat(43),
          });
        }
        if (path === `/rooms/${room}/socket`) {
          return new Response("Upgrade rejected", { status: 400 });
        }
        return new Response("Room cleanup", { status: cleanupStatus });
      },
      hostname: "127.0.0.1",
      port: 0,
    });
    try {
      let failure: unknown;
      try {
        await RelaySession.create(server.url.origin);
      } catch (error) {
        failure = error;
      }
      expect(requests).toEqual([
        "/rooms",
        `/rooms/${room}/socket`,
        `/rooms/${room}/end`,
      ]);
      const handshakeError = {
        message: expect.stringContaining(`/rooms/${room}/socket`) as unknown,
      };
      if (cleanupStatus === 503) {
        expect(failure).toBeInstanceOf(AggregateError);
        if (!(failure instanceof AggregateError)) {
          throw new Error("Expected both startup and cleanup errors");
        }
        expect(failure.errors).toMatchObject([
          handshakeError,
          { message: "Room deletion failed: 503" },
        ]);
        expect(failure.message).toContain(`/rooms/${room}/socket`);
        expect(failure.cause).toMatchObject({
          message: "Room deletion failed: 503",
        });
        expect(failure.cause).toBe(failure.errors[1]);
      } else {
        expect(failure).toMatchObject(handshakeError);
        expect(failure).not.toBeInstanceOf(AggregateError);
      }
    } finally {
      await server.stop(true);
    }
  });
}
