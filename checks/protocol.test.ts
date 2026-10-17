import { expect, mock, test } from "bun:test";

import { base64 } from "@scure/base";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { parse, safeParse } from "valibot";

import {
  AckPacketSchema,
  maxPacketLength,
  parseViewerMessage,
  SelectPacketSchema,
  StatePacketSchema,
  ViewStateSchema,
} from "../protocol";
import type { ViewState } from "../protocol";
import { Answer } from "../web/Answer";
import {
  cancelScroll,
  readingAnchor,
  restoreAnchor,
  scrollPage,
} from "../web/reading";
import { acknowledgment, decrypt, empty, parseLink } from "../web/session";

test("decrypted snapshots reject invalid domain fields without coercion", () => {
  const valid = {
    ...empty,
    answers: [
      {
        id: "answer",
        language: "English",
        status: "complete",
        text: "Answer text",
      },
    ],
    command: { answerID: null, direction: -1, id: 1 },
    selectedID: null,
  };
  expect(safeParse(ViewStateSchema, valid).success).toBe(true);
  expect(safeParse(ViewStateSchema, { ...empty, command: null }).success).toBe(
    true
  );
  const invalid = [
    { version: 1 },
    { version: 2 },
    { live: "true" },
    { audioEnabled: "true" },
    { audioEnabled: null },
    { canAnswer: "true" },
    { canAnswer: undefined },
    { answers: null },
    { answers: [null] },
    {
      answers: [
        { id: 1, language: "English", status: "complete", text: "text" },
      ],
    },
    {
      answers: [{ id: "a", language: "English", status: "done", text: "text" }],
    },
    {
      answers: [{ id: "a", language: "English", status: "complete", text: [] }],
    },
    { selectedID: 1 },
    { selection: -1 },
    { selection: 1.5 },
    { selection: Number.MAX_SAFE_INTEGER + 1 },
    { selectionRequest: { client: 1, id: 1 } },
    { selectionRequest: { client: "viewer", id: 0 } },
    { selectionRequest: { client: "viewer", id: 1.5 } },
    { fontSize: 15 },
    { fontSize: 41 },
    { fontSize: "20" },
    { fontSize: Number.POSITIVE_INFINITY },
    { answers: [{ id: "a", status: "complete", text: "text" }] },
    {
      answers: [{ id: "a", language: null, status: "complete", text: "text" }],
    },
    { modifiers: 1 },
    { error: false },
    { command: false },
    { command: { direction: 1, id: 0 } },
    { command: { direction: 1, id: 1.5 } },
    { command: { direction: 0, id: 1 } },
    { command: { answerID: 1, direction: 1, id: 1 } },
  ];
  for (const fields of invalid) {
    expect(safeParse(ViewStateSchema, { ...valid, ...fields }).success).toBe(
      false
    );
  }
});

test("snapshots without audio configuration keep their existing listening behavior", () => {
  const legacy: Partial<ViewState> = { ...empty };
  delete legacy.audioEnabled;
  expect(parse(ViewStateSchema, legacy).audioEnabled).toBe(true);
  expect(
    parse(ViewStateSchema, { ...empty, audioEnabled: false }).audioEnabled
  ).toBe(false);
});

test("protocol schemas preserve ignored extensions and enforce recognized packet bounds", () => {
  for (const type of ["future", null, 1, { future: true }, []]) {
    expect(parseViewerMessage({ type })).toBeUndefined();
  }
  for (const invalid of [
    null,
    [],
    {},
    { type: undefined },
    { type: "ready" },
    { box: "AAAA", seq: "1", type: "state" },
  ]) {
    expect(() => parseViewerMessage(invalid)).toThrow();
  }
  expect(
    parseViewerMessage({ client: "viewer", extra: true, type: "ready" })
  ).toEqual({ client: "viewer", type: "ready" });
  expect(parseViewerMessage({ extra: true, type: "ended" })).toEqual({
    type: "ended",
  });
  for (const publisher of ["writer", null]) {
    expect(
      parseViewerMessage({ box: "AAAA", publisher, seq: 1, type: "state" })
    ).toEqual({ box: "AAAA", publisher, seq: 1, type: "state" });
  }
  for (const publisher of [undefined, 1, false]) {
    expect(() =>
      parseViewerMessage({ box: "AAAA", publisher, seq: 1, type: "state" })
    ).toThrow();
  }
  expect(
    safeParse(StatePacketSchema, {
      box: "A".repeat(maxPacketLength),
      seq: 1,
      type: "state",
    }).success
  ).toBe(true);
  for (const fields of [
    { seq: 0 },
    { seq: 1.5 },
    { seq: Number.MAX_SAFE_INTEGER + 1 },
    { box: "-_8=" },
    { box: "AA AA" },
    { box: "A".repeat(maxPacketLength + 1) },
  ]) {
    expect(
      safeParse(StatePacketSchema, {
        box: "AAAA",
        seq: 1,
        type: "state",
        ...fields,
      }).success
    ).toBe(false);
  }
  expect(
    safeParse(AckPacketSchema, { box: "A".repeat(1024), seq: 1, type: "ack" })
      .success
  ).toBe(true);
  expect(
    safeParse(AckPacketSchema, { box: "A".repeat(1025), seq: 1, type: "ack" })
      .success
  ).toBe(false);
});

test("selection packets bound request IDs and ciphertext without accepting malformed publishers", () => {
  const valid = {
    box: "A".repeat(1024),
    id: 1,
    publisher: "writer",
    type: "select",
  };
  expect(safeParse(SelectPacketSchema, valid).success).toBe(true);
  for (const fields of [
    { id: 0 },
    { id: -1 },
    { id: 1.5 },
    { id: Number.MAX_SAFE_INTEGER + 1 },
    { id: "1" },
    { publisher: null },
    { publisher: 1 },
    { box: "A".repeat(1025) },
    { box: "not base64" },
    { type: "state" },
  ]) {
    expect(safeParse(SelectPacketSchema, { ...valid, ...fields }).success).toBe(
      false
    );
  }
});

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
        language: "English",
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
    return { box: base64.encode(combined), seq: 1, type: "state" as const };
  };
  const packet = await encrypt(state);
  expect(await decrypt(key, "room", packet)).toEqual(state);
  const paddedState = packet.box.endsWith("=")
    ? state
    : { ...state, error: "." };
  const padded = packet.box.endsWith("=") ? packet : await encrypt(paddedState);
  expect(await decrypt(key, "room", padded)).toEqual(paddedState);
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const suffix = padded.box.endsWith("==") ? "==" : "=";
  const lastIndex = padded.box.length - suffix.length - 1;
  const last = alphabet.indexOf(padded.box.charAt(lastIndex));
  const noncanonical =
    padded.box.slice(0, lastIndex) + alphabet.charAt(last + 1) + suffix;
  // Nonzero unused pad bits represent the same ciphertext to permissive decoders.
  expect(atob(noncanonical)).toBe(atob(padded.box));
  for (const box of [padded.box.replace(/=+$/u, ""), noncanonical]) {
    expect(decrypt(key, "room", { ...padded, box })).rejects.toThrow();
  }
  const noCommand = { ...state, command: null };
  expect(await decrypt(key, "room", await encrypt(noCommand))).toEqual(
    noCommand
  );
  await Promise.all(
    [
      { ...state, version: 1 },
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
  const bytes = base64.decode(ack.box);
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
    "- Outer item\n\n  Continued explanation.\n\n  - Nested item\n\nUse [the docs][d].\n\n```\ndef f():\n\n    return '<&>'\n```\n\n[d]: https://example.com\n";
  const html = renderToStaticMarkup(createElement(Answer, { text }));
  expect(html).toMatch(
    /<li[^>]*>\s*<p[^>]*>Outer item<\/p>\s*<p[^>]*>Continued explanation\.<\/p>\s*<ul>/u
  );
  expect(html).toContain('href="https://example.com"');
  expect(html).toContain('rel="noreferrer noopener"');
  expect(html).toContain("    return &#x27;&lt;&amp;&gt;&#x27;\n");
  expect(html).toMatch(/data-anchor="code\.\d+\.2"/u);
});

test("highlighted code keeps distinct anchors for every line, including blank lines", () => {
  const html = renderToStaticMarkup(
    createElement(Answer, {
      text: "```python\ndef f():\n\n    return '<&>'\n```",
    })
  );
  expect(
    [...html.matchAll(/data-anchor="(?<id>[^"]+)"/gu)].map(
      (match) => match.groups?.["id"]
    )
  ).toEqual(["pre.0", "code.0.0", "code.0.1", "code.0.2"]);
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
  const room = new Room(context as unknown as DurableObjectState, {} as Env);
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
