import { afterEach, expect, mock, spyOn, test } from "bun:test";

await mock.module("cloudflare:workers", () => ({
  DurableObject: class {
    readonly ctx: unknown;
    constructor(ctx: unknown) {
      this.ctx = ctx;
    }
  },
}));
const { Room } = await import("../relay/worker");
const roomTTL = 2 * 60 * 60 * 1000;
const token = "w".repeat(43);
const readerToken = "r".repeat(43);
const upgrade = (
  role = "writer",
  bearer = role === "reader" ? readerToken : token
) =>
  new Request("https://room.test/socket", {
    headers: {
      "Sec-WebSocket-Protocol": `skill-issue, skill-issue.${role}.${bearer}`,
      Upgrade: "websocket",
    },
  });

interface Attachment {
  id: string;
  role?: "writer" | "reader";
  retired?: true;
}
function socketFixture(initial: Attachment) {
  let peer = structuredClone(initial);
  const socket = {
    close(code: number, reason?: string) {
      socket.readyState = WebSocket.CLOSING;
      socket.closures.push(reason === undefined ? { code } : { code, reason });
    },
    closures: [] as { code: number; reason?: string }[],
    deserializeAttachment: () => structuredClone(peer),
    messages: [] as string[],
    readyState: WebSocket.OPEN as number,
    send(message: string) {
      socket.messages.push(message);
    },
    serializeAttachment(value: Attachment) {
      peer = structuredClone(value);
    },
    get socket(): WebSocket {
      // The fixture implements the WebSocket operations used by this room.
      return socket as unknown as WebSocket;
    },
  };
  return socket;
}

function storageFixture() {
  const values = new Map<string, unknown>();
  const storage = {
    alarm: null as number | null,
    async delete(key: string) {
      return values.delete(key);
    },
    async deleteAlarm() {
      storage.alarm = null;
    },
    async deleteAll() {
      values.clear();
    },
    async get(key: string | string[]) {
      if (typeof key === "string") {
        return values.get(key);
      }
      return new Map(key.map((name) => [name, values.get(name)]));
    },
    async put(key: string | Record<string, unknown>, value?: unknown) {
      if (typeof key === "string") {
        values.set(key, value);
        return;
      }
      for (const [name, entry] of Object.entries(key)) {
        values.set(name, entry);
      }
    },
    async setAlarm(time: number) {
      storage.alarm = time;
    },
    async transaction(
      run: (transaction: DurableObjectTransaction) => Promise<void>
    ): Promise<void> {
      // The fixture supplies the transaction operations used by this room.
      await run(storage as unknown as DurableObjectTransaction);
    },
    values,
  };
  return storage;
}

async function roomFixture() {
  let now = 1_000_000;
  spyOn(Date, "now").mockImplementation(() => now);
  const writerHash = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
  ).toHex();
  const readerHash = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(readerToken))
  ).toHex();
  const storage = storageFixture();
  const expires = now + roomTTL;
  storage.values.set("session", {
    expires,
    readerHash,
    writerHash,
  });
  storage.alarm = expires;
  const peers: ReturnType<typeof socketFixture>[] = [];
  const ctx = {
    acceptWebSocket: (socket: WebSocket) => {
      // WebSocketPair supplies only socket fixtures in these tests.
      peers.push(socket as unknown as ReturnType<typeof socketFixture>);
    },
    getWebSockets: () => peers.map((peer) => peer.socket),
    storage,
  };
  const restorePair = Object.getOwnPropertyDescriptor(
    globalThis,
    "WebSocketPair"
  );
  Object.defineProperty(globalThis, "WebSocketPair", {
    configurable: true,
    value: function value() {
      return {
        0: socketFixture({ id: "client" }),
        1: socketFixture({ id: "server" }),
      };
    },
  });
  // The fixture implements the state methods and storage operations used here.
  const state = ctx as unknown as DurableObjectState;
  const create = () => new Room(state, {} as Env);
  return {
    advance: (milliseconds: number) => {
      now += milliseconds;
    },
    create,
    expires,
    peers,
    restore: () => {
      if (restorePair) {
        Object.defineProperty(globalThis, "WebSocketPair", restorePair);
      } else {
        Reflect.deleteProperty(globalThis, "WebSocketPair");
      }
    },
    room: create(),
    storage,
  };
}

afterEach(() => {
  mock.restore();
});

test("missing, malformed and wrong-role credentials are rejected before admission", async () => {
  const fixture = await roomFixture();
  try {
    for (const protocols of [
      undefined,
      "skill-issue",
      `skill-issue, skill-issue.reader.${"x".repeat(43)}`,
      `skill-issue, skill-issue.owner.${token}`,
      `skill-issue, skill-issue.writer.${readerToken}`,
      `skill-issue, skill-issue.writer.${token}, extra`,
      `skill-issue, skill-issue.writer.${token}/`,
    ]) {
      const request = new Request("https://room.test/socket", {
        headers:
          protocols === undefined
            ? { Upgrade: "websocket" }
            : { "Sec-WebSocket-Protocol": protocols, Upgrade: "websocket" },
      });
      // Each denial must finish before inspecting the retained socket count.
      // oxlint-disable-next-line no-await-in-loop
      const response = await fixture.room.fetch(request);
      expect(response.status).toBe(400);
      expect(fixture.peers).toHaveLength(0);
    }
  } finally {
    fixture.restore();
  }
});

test("authenticated handshakes send ready without exposing the credential in the response", async () => {
  const fixture = await roomFixture();
  try {
    const response = await fixture.room.fetch(upgrade("reader"));
    expect(response.status).toBe(101);
    expect(response.headers.get("Sec-WebSocket-Protocol")).toBe("skill-issue");
    expect(fixture.peers).toHaveLength(1);
    expect(fixture.peers[0]?.deserializeAttachment()).toMatchObject({
      role: "reader",
    });
    expect(JSON.parse(fixture.peers[0]?.messages[0] ?? "{}")).toMatchObject({
      type: "ready",
    });
    expect(fixture.storage.alarm).toBe(fixture.expires);
  } finally {
    fixture.restore();
  }
});

test("retained closing readers consume capacity while publisher replacement has a reserved slot", async () => {
  const fixture = await roomFixture();
  try {
    const writer = socketFixture({ id: "writer", role: "writer" });
    fixture.peers.push(
      writer,
      ...Array.from({ length: 30 }, (_, i) =>
        socketFixture({ id: String(i), role: "reader" })
      )
    );
    for (const peer of fixture.peers.slice(1)) {
      peer.close(1000);
    }
    const denied = await fixture.room.fetch(upgrade("reader"));
    expect(denied.status).toBe(400);
    expect(fixture.peers).toHaveLength(31);
    const replacement = await fixture.create().fetch(upgrade());
    expect(replacement.status).toBe(101);
    expect(fixture.peers).toHaveLength(32);
    expect(writer.deserializeAttachment().retired).toBe(true);
    expect(writer.closures).toEqual([{ code: 1000 }]);
    const full = await fixture.room.fetch(upgrade());
    expect(full.status).toBe(400);
    expect(fixture.peers).toHaveLength(32);
  } finally {
    fixture.restore();
  }
});

test("a retired publisher cannot revive after hibernation reports its socket as open", async () => {
  const fixture = await roomFixture();
  try {
    const old = socketFixture({ id: "old", retired: true, role: "writer" });
    const current = socketFixture({ id: "current", role: "writer" });
    const reader = socketFixture({ id: "reader", role: "reader" });
    fixture.peers.push(old, current, reader);
    await fixture
      .create()
      .webSocketMessage(
        old.socket,
        JSON.stringify({ box: "YQ==", seq: 1, type: "state" })
      );
    expect(fixture.storage.values.has("snapshot")).toBe(false);
    expect(reader.messages).toEqual([]);
    expect(old.closures).toEqual([
      { code: 1008, reason: "Couldn't complete that. Try again." },
    ]);
    await fixture
      .create()
      .webSocketMessage(
        current.socket,
        JSON.stringify({ box: "YQ==", seq: 1, type: "state" })
      );
    expect(fixture.storage.values.get("snapshot")).toMatchObject({ seq: 1 });
    expect(reader.messages).toHaveLength(1);
  } finally {
    fixture.restore();
  }
});

test("expiration during handshake verification cannot admit a publisher", async () => {
  const fixture = await roomFixture();
  try {
    const digest = crypto.subtle.digest.bind(crypto.subtle);
    spyOn(crypto.subtle, "digest").mockImplementation(
      async (algorithm, data) => {
        fixture.advance(roomTTL);
        return await digest(algorithm, data);
      }
    );
    const response = await fixture.room.fetch(upgrade());
    expect(response.status).toBe(400);
    expect(fixture.peers).toHaveLength(0);
  } finally {
    fixture.restore();
  }
});

test("room renewal and expiry survive reconstruction without authentication deadline alarms", async () => {
  const fixture = await roomFixture();
  try {
    fixture.advance(61_000);
    const writer = socketFixture({ id: "writer", role: "writer" });
    fixture.peers.push(writer);
    await fixture
      .create()
      .webSocketMessage(
        writer.socket,
        JSON.stringify({ box: "YQ==", seq: 1, type: "state" })
      );
    expect(fixture.storage.alarm).toBe(1_061_000 + roomTTL);
    fixture.advance(roomTTL);
    await fixture.create().alarm();
    expect(fixture.storage.values.size).toBe(0);
    expect(fixture.storage.alarm).toBeNull();
    expect(writer.messages).toContain('{"type":"ended"}');
  } finally {
    fixture.restore();
  }
});

test("a publisher can delete a room whose retained socket capacity is full", async () => {
  const fixture = await roomFixture();
  try {
    fixture.peers.push(
      ...Array.from({ length: 32 }, (_, i) =>
        socketFixture({ id: String(i), role: "reader" })
      )
    );
    const response = await fixture.room.fetch(
      new Request("https://room.test/end", {
        headers: { Authorization: `Bearer ${token}` },
        method: "POST",
      })
    );
    expect(response.status).toBe(200);
    expect(fixture.storage.values.size).toBe(0);
    expect(fixture.storage.alarm).toBeNull();
    expect(
      fixture.peers.every((peer) => peer.messages.includes('{"type":"ended"}'))
    ).toBe(true);
  } finally {
    fixture.restore();
  }
});

test("deletion during handshake verification cannot revive a room", async () => {
  const fixture = await roomFixture();
  try {
    const digest = crypto.subtle.digest.bind(crypto.subtle);
    spyOn(crypto.subtle, "digest").mockImplementation(
      async (algorithm, data) => {
        await fixture.storage.deleteAll();
        return await digest(algorithm, data);
      }
    );
    const response = await fixture.room.fetch(upgrade());
    expect(response.status).toBe(400);
    expect(fixture.peers).toHaveLength(0);
  } finally {
    fixture.restore();
  }
});

test("concurrent authenticated readers cannot race past reserved publisher capacity", async () => {
  const fixture = await roomFixture();
  try {
    const responses = await Promise.all(
      Array.from(
        { length: 64 },
        async () => await fixture.room.fetch(upgrade("reader"))
      )
    );
    expect(
      responses.filter((response) => response.status === 101)
    ).toHaveLength(30);
    expect(
      responses.filter((response) => response.status === 400)
    ).toHaveLength(34);
    expect(fixture.peers).toHaveLength(30);
  } finally {
    fixture.restore();
  }
});
