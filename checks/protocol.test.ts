import { expect, mock, test } from "bun:test";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { Answer } from "../web/Answer";
import {
  cancelScroll,
  readingAnchor,
  restoreAnchor,
  scrollPage,
} from "../web/reading";
import {
  acknowledgment,
  base64,
  decrypt,
  empty,
  parseLink,
  unbase64,
} from "../web/session";

test("encrypted history authenticates room, sequence and version", async () => {
  const key = await crypto.subtle.generateKey(
    { length: 256, name: "AES-GCM" },
    true,
    ["encrypt", "decrypt"]
  );
  const state = {
    ...empty,
    answers: [
      {
        id: "a",
        status: "complete" as const,
        text: "Private code: <script>alert(1)</script>",
      },
    ],
    live: true,
    selectedID: "a",
  };
  const encrypt = async (snapshot: unknown) => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const cipher = new Uint8Array(
      await crypto.subtle.encrypt(
        {
          additionalData: new TextEncoder().encode("room:1"),
          iv,
          name: "AES-GCM",
        },
        key,
        new TextEncoder().encode(JSON.stringify(snapshot))
      )
    );
    const combined = new Uint8Array(iv.length + cipher.length);
    combined.set(iv);
    combined.set(cipher, iv.length);
    return { box: base64(combined), seq: 1, type: "state" as const };
  };
  const packet = await encrypt(state);
  expect(await decrypt(key, "room", packet)).toEqual(state);
  const noCommand = { ...state, command: null };
  expect(await decrypt(key, "room", await encrypt(noCommand))).toEqual(
    noCommand
  );
  await Promise.all(
    [
      { ...state, version: 2 },
      { ...state, command: 0 },
      { ...state, command: false },
      { ...state, command: "" },
    ].map(async (snapshot) => {
      const invalid = await encrypt(snapshot);
      expect(decrypt(key, "room", invalid)).rejects.toThrow();
    })
  );
  expect(decrypt(key, "other-room", packet)).rejects.toThrow();
  expect(decrypt(key, "room", { ...packet, seq: 2 })).rejects.toThrow();
  expect(() => parseLink("#broken")).toThrow();
  expect(() =>
    parseLink(
      `#${crypto.randomUUID()}.${"a".repeat(43)}.${"b".repeat(43)}.extra`
    )
  ).toThrow();
  const ack = JSON.parse(
    await acknowledgment(key, "room", "viewer1", 1, 7)
  ) as {
    box: string;
  };
  const bytes = unbase64(ack.box);
  const open = async (client: string) =>
    await crypto.subtle.decrypt(
      {
        additionalData: new TextEncoder().encode(`room:ack:${client}:1`),
        iv: bytes.slice(0, 12),
        name: "AES-GCM",
      },
      key,
      bytes.slice(12)
    );
  expect(JSON.parse(new TextDecoder().decode(await open("viewer1")))).toEqual({
    command: 7,
    seq: 1,
  });
  expect(open("viewer2")).rejects.toThrow();
});

test("Markdown retains nested lists, reference links and original code", () => {
  const text =
    "- Outer item\n\n  Continued explanation.\n\n  - Nested item\n\nUse [the docs][d].\n\n```python\ndef f():\n\n    return '<&>'\n```\n\n[d]: https://example.com\n";
  const html = renderToStaticMarkup(createElement(Answer, { text }));
  expect(html).toMatch(
    /<li[^>]*>\s*<p[^>]*>Outer item<\/p>\s*<p[^>]*>Continued explanation\.<\/p>\s*<ul>/u
  );
  expect(html).toContain('href="https://example.com"');
  expect(html).toContain('rel="noreferrer noopener"');
  expect(html).toContain("    return &#x27;&lt;&amp;&gt;&#x27;\n");
  expect(html).toMatch(/data-anchor="code\.\d+\.2"/u);
});

test("reading chooses a visible leaf inside nested list and code anchors", () => {
  const line = {
    contains: () => false,
    dataset: { anchor: "code.30.2" },
    getBoundingClientRect: () => ({ bottom: 130, top: 105 }),
  };
  const code = {
    contains: (child: unknown) => child === line,
    dataset: { anchor: "pre.30" },
    getBoundingClientRect: () => ({ bottom: 200, top: 20 }),
  };
  const list = {
    contains: (child: unknown) => child === code || child === line,
    dataset: { anchor: "li.0" },
    getBoundingClientRect: () => ({ bottom: 300, top: 0 }),
  };
  const pane = {
    clientHeight: 150,
    getBoundingClientRect: () => ({ top: 100 }),
    querySelectorAll: () => [list, code, line],
  };
  expect(readingAnchor(pane as unknown as HTMLElement)).toEqual({
    id: "code.30.2",
    offset: 5,
  });
});

test("manual scroll accumulates targets, survives snapshots and yields to direct input", () => {
  const originalMedia = globalThis.matchMedia;
  const originalCSS = globalThis.CSS;
  const originalFrame = globalThis.requestAnimationFrame;
  const originalCancel = globalThis.cancelAnimationFrame;
  const frames = new Map<number, FrameRequestCallback>();
  let frameID = 0;
  // The mock implements requestAnimationFrame's callback contract.
  // oxlint-disable-next-line promise/prefer-await-to-callbacks
  globalThis.requestAnimationFrame = (callback) => {
    frameID += 1;
    frames.set(frameID, callback);
    return frameID;
  };
  globalThis.cancelAnimationFrame = (id) => {
    frames.delete(id);
  };
  let reduced = false;
  globalThis.matchMedia = (() => ({
    matches: reduced,
  })) as unknown as typeof matchMedia;
  globalThis.CSS = { escape: (value: string) => value } as typeof CSS;
  const calls: ScrollToOptions[] = [];
  const pane = Object.assign(new EventTarget(), {
    clientHeight: 400,
    getBoundingClientRect: () => ({ top: 0 }),
    querySelector: () => ({
      getBoundingClientRect: () => ({ top: 260 - pane.scrollTop }),
    }),
    scrollHeight: 2000,
    scrollTo: (options: ScrollToOptions) => {
      calls.push(options);
      if (options.behavior !== "smooth") {
        if (options.top === undefined) {
          throw new Error("Expected a vertical scroll target");
        }
        pane.scrollTop = options.top;
      }
    },
    scrollTop: 100,
  }) as unknown as HTMLElement;
  try {
    scrollPage(pane, 1);
    pane.scrollTop = 110;
    scrollPage(pane, 1);
    scrollPage(pane, -1);
    expect(calls.map((call) => call.top)).toEqual([300, 500, 300]);
    restoreAnchor(pane, { id: "paragraph", offset: 0 }, false);
    expect(pane.scrollTop).toBe(110);
    expect(calls.length).toBe(3);
    pane.dispatchEvent(new Event("wheel"));
    scrollPage(pane, 1);
    expect(calls.at(-1)).toEqual({ behavior: "smooth", top: 310 });
    restoreAnchor(pane, { id: "paragraph", offset: 50 });
    expect(pane.scrollTop).toBe(210);
    // One late compositor frame after the instant restore.
    pane.scrollTop = 217;
    restoreAnchor(pane, { id: "paragraph", offset: 43 }, false);
    expect(pane.scrollTop).toBe(217);
    const correction = frames.get(frameID);
    if (!correction) {
      throw new Error("Expected a scheduled scroll correction");
    }
    frames.delete(frameID);
    correction(0);
    expect(pane.scrollTop).toBe(210);
    scrollPage(pane, 1);
    restoreAnchor(pane);
    expect(frames.size).toBe(1);
    scrollPage(pane, 1);
    expect(frames.size).toBe(0);
    expect(calls.at(-1)?.top).toBe(200);
    pane.scrollTop = 200;
    pane.dispatchEvent(new Event("scrollend"));
    scrollPage(pane, 1);
    pane.scrollTop = 400;
    pane.dispatchEvent(new Event("scrollend"));
    pane.scrollTop = 500;
    scrollPage(pane, 1);
    expect(calls.at(-1)?.top).toBe(700);
    cancelScroll(pane);
    reduced = true;
    pane.scrollTop = 1500;
    scrollPage(pane, 1);
    scrollPage(pane, 1);
    expect(pane.scrollTop).toBe(1600);
    expect(calls.at(-1)).toEqual({ behavior: "auto", top: 1600 });
  } finally {
    globalThis.matchMedia = originalMedia;
    globalThis.CSS = originalCSS;
    globalThis.requestAnimationFrame = originalFrame;
    globalThis.cancelAnimationFrame = originalCancel;
  }
});

// The room's business logic runs against an in-memory platform context. The
// integration check still exercises the real Durable Object/WebSocket runtime.
await mock.module("cloudflare:workers", () => ({
  DurableObject: class {
    ctx: unknown;
    env: unknown;

    constructor(ctx: unknown, env: unknown) {
      this.ctx = ctx;
      this.env = env;
    }
  },
}));
const { default: worker, Room } = await import("../relay/worker");

test("reconnect rate limiting cannot block authenticated room deletion", async () => {
  const forwarded: string[] = [];
  let attempts = 0;
  const env = {
    ROOMS: {
      getByName: () => ({
        fetch: async (request: Request) => {
          forwarded.push(new URL(request.url).pathname);
          return new Response("OK");
        },
      }),
    },
    ROOM_LIMIT: {
      limit: async () => {
        attempts += 1;
        return { success: attempts <= 20 };
      },
    },
  } as unknown as Parameters<typeof worker.fetch>[1];
  const base = "https://relay.test/rooms/00000000-0000-0000-0000-000000000001";
  for (let i = 0; i < 20; i += 1) {
    // Each connection attempt must consume its quota before the next request.
    // oxlint-disable-next-line no-await-in-loop
    await worker.fetch(new Request(`${base}/socket`), env);
  }
  const limited = await worker.fetch(new Request(`${base}/socket`), env);
  expect(limited.status).toBe(400);
  const ended = await worker.fetch(
    new Request(`${base}/end`, {
      headers: { Authorization: "Bearer publisher" },
      method: "POST",
    }),
    env
  );
  expect(ended.status).toBe(200);
  expect(forwarded.at(-1)).toBe(new URL(`${base}/end`).pathname);
});

test("room deletion survives both closing and failed open peers", async () => {
  const token = "publisher";
  const writerHash = Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
    ),
    (byte) => byte.toString(16).padStart(2, "0")
  ).join("");
  const values = new Map<string, unknown>([
    ["session", { expires: Date.now() + 60_000, readerHash: "", writerHash }],
    ["snapshot", { chunks: 1, seq: 1 }],
    ["part:0", "encrypted"],
  ]);
  let alarm = true;
  const messages: string[] = [];
  const closing = {
    close: () => {
      throw new Error("already closed");
    },
    readyState: 2,
    send: () => {
      throw new Error("already closing");
    },
  };
  const failed = {
    close: () => {
      throw new Error("network gone");
    },
    readyState: 1,
    send: () => {
      throw new Error("network gone");
    },
  };
  const healthy = {
    close: () => {},
    readyState: 1,
    send: (text: string) => messages.push(text),
  };
  const context = {
    getWebSockets: () => [closing, failed, healthy],
    storage: {
      deleteAlarm: async () => {
        alarm = false;
      },
      deleteAll: async () => {
        values.clear();
      },
      get: async (key: string) => values.get(key),
    },
  };
  const room = new Room(
    context as unknown as DurableObjectState,
    {} as Parameters<typeof worker.fetch>[1]
  );
  const response = await room.fetch(
    new Request("https://room/rooms/id/end", {
      headers: { Authorization: `Bearer ${token}` },
      method: "POST",
    })
  );
  expect(response.status).toBe(200);
  expect(values.size).toBe(0);
  expect(alarm).toBe(false);
  expect(messages).toEqual(['{"type":"ended"}']);
  const missingRoom = await room.fetch(
    new Request("https://room/socket", {
      headers: { Upgrade: "websocket" },
    })
  );
  expect(missingRoom.status).toBe(400);
});
