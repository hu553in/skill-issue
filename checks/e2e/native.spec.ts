import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

import { base64urlnopad } from "@scure/base";

import type { Packet } from "../../protocol";
import {
  acknowledgment,
  decrypt,
  empty,
  parseLink,
  selectAnswer,
} from "../../web/session";
import { expect, test } from "./fixtures";
import { Peer } from "./peer";

interface NativeFixture {
  room: string;
  viewerURL: string;
  packet: Packet;
  stage:
    | "published"
    | "non-controls-held"
    | "history-pending"
    | "history-stale-rejected"
    | "zoom-pending"
    | "zoom-stale-rejected"
    | "zoom-synced"
    | "scroll-pending"
    | "scroll-command-rejected"
    | "selection-ready"
    | "selection-repeat-ready"
    | "native-reader-disconnected";
}
async function readFixture(file: string): Promise<NativeFixture | null> {
  try {
    return JSON.parse(await readFile(file, "utf-8")) as NativeFixture;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}
async function waitForStage(file: string, stage: NativeFixture["stage"]) {
  await expect
    .poll(async () => {
      const current = await readFixture(file);
      return current?.stage;
    })
    .toBe(stage);
}
// node:util intentionally discards execFile's returned ChildProcess in this overload.
// oxlint-disable-next-line typescript/strict-void-return
const execute = promisify(execFile);
let binary: string;

// Playwright requires destructuring even when the hook uses no fixtures.
// oxlint-disable-next-line no-empty-pattern
test.beforeAll("Compile the native relay probe", async ({}, testInfo) => {
  test.skip(
    process.platform !== "darwin",
    "The native URLSession/CryptoKit probe requires macOS"
  );
  // Cold Swift package preparation has its own budget; the protocol check keeps 30s.
  const buildTimeout = 120_000;
  testInfo.setTimeout(buildTimeout);
  const signal = AbortSignal.timeout(buildTimeout);
  binary = testInfo.outputPath("native-relay-check");
  const buildDependency = async (target: string) =>
    await execute(
      "swift",
      ["build", "--target", target, "--jobs", "4", "--force-resolved-versions"],
      { signal }
    );
  await buildDependency("JOSESwift");
  await buildDependency("SimpleKeychain");
  const { stdout } = await execute(
    "swift",
    ["build", "--show-bin-path", "--force-resolved-versions"],
    { signal }
  );
  const products = stdout.trim();
  await execute(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "6",
      "-warnings-as-errors",
      "-I",
      products,
      path.join(products, "JOSESwift.o"),
      path.join(products, "SimpleKeychain.o"),
      "native/Core.swift",
      "native/ViewerAccess.swift",
      "native/Relay.swift",
      "checks/native_relay.swift",
      "-o",
      binary,
    ],
    { signal }
  );
});

test("native relay syncs selection, zoom and scroll without conflating viewer presence", async ({
  baseURL,
}, testInfo) => {
  if (baseURL === undefined || baseURL.length === 0) {
    throw new Error("The integration server URL is missing");
  }
  const fixturePath = testInfo.outputPath("native-fixture.json");
  let peer: Peer | undefined;
  let nativeFailure: Error | undefined;
  const controller = new AbortController();
  const execution = (async () => {
    try {
      return {
        ok: true as const,
        output: await execute(binary, [baseURL, fixturePath], {
          signal: controller.signal,
        }),
      };
    } catch (error) {
      nativeFailure = error instanceof Error ? error : new Error(String(error));
      return { error: nativeFailure, ok: false as const };
    }
  })();
  try {
    await expect
      .poll(async () => await readFixture(fixturePath))
      .not.toBeNull();
    const fixture = await readFixture(fixturePath);
    if (fixture === null) {
      throw new Error("The native relay fixture is missing");
    }
    expect(fixture.stage).toBe("published");
    const link = parseLink(new URL(fixture.viewerURL).hash);
    expect(link.room).toBe(fixture.room);
    const key = await crypto.subtle.importKey(
      "raw",
      Uint8Array.from(base64urlnopad.decode(link.key)),
      "AES-GCM",
      false,
      ["encrypt", "decrypt"]
    );
    peer = new Peer(
      `${baseURL.replace(/^http/u, "ws")}/rooms/${fixture.room}/socket`,
      "reader",
      link.token
    );
    const ready = await peer.next("ready");
    const packet = await peer.next("state");
    expect(packet).toMatchObject(fixture.packet);
    const initialState = {
      ...empty,
      answers: [
        {
          id: "a",
          status: "complete",
          text: "Use a hash map. Average lookup is O(1).",
        },
      ],
      command: { answerID: "a", direction: 1, id: 3 },
      live: true,
      selectedID: "a",
    };
    expect(await decrypt(key, fixture.room, packet)).toEqual(initialState);
    const firstAck = await acknowledgment(
      key,
      fixture.room,
      ready.client,
      packet.seq,
      3
    );
    peer.send(firstAck);
    const streamed = await peer.next("state");
    const streamedState = {
      ...initialState,
      answers: [
        {
          id: "a",
          status: "complete",
          text: "Use a hash map. Average lookup is O(1). A streamed conclusion.",
        },
        { id: "b", status: "complete", text: "Use a balanced tree." },
      ],
    };
    expect(streamed.seq).toBe(2);
    expect(await decrypt(key, fixture.room, streamed)).toEqual(streamedState);
    const heartbeat = await peer.next("state");
    expect(heartbeat.seq).toBe(3);
    expect(await decrypt(key, fixture.room, heartbeat)).toEqual(streamedState);
    // Neither text nor a heartbeat requires a new control confirmation.
    await waitForStage(fixturePath, "non-controls-held");
    peer.send(firstAck);

    const history = await peer.next("state");
    const historyState = { ...streamedState, selectedID: "b", selection: 1 };
    expect(history.seq).toBe(4);
    expect(await decrypt(key, fixture.room, history)).toEqual(historyState);
    await waitForStage(fixturePath, "history-pending");
    const historyAck = await acknowledgment(
      key,
      fixture.room,
      ready.client,
      history.seq,
      3
    );
    const forged = JSON.parse(historyAck) as { box: string };
    forged.box = `${forged.box.startsWith("A") ? "B" : "A"}${forged.box.slice(1)}`;
    peer.send(forged);
    peer.send(
      await acknowledgment(key, fixture.room, "another-reader", history.seq, 3)
    );
    peer.send(
      await acknowledgment(key, "another-room", ready.client, history.seq, 3)
    );
    const rebound = JSON.parse(
      await acknowledgment(key, fixture.room, ready.client, heartbeat.seq, 3)
    ) as { seq: number };
    rebound.seq = history.seq;
    peer.send(rebound);
    // This valid old ACK is an ordered barrier after all invalid ACKs.
    peer.send(firstAck);
    await waitForStage(fixturePath, "history-stale-rejected");
    peer.send(historyAck);

    const zoom = await peer.next("state");
    const zoomState = { ...historyState, fontSize: 28 };
    expect(zoom.seq).toBe(5);
    expect(await decrypt(key, fixture.room, zoom)).toEqual(zoomState);
    await waitForStage(fixturePath, "zoom-pending");
    peer.send(historyAck);
    peer.send(firstAck);
    await waitForStage(fixturePath, "zoom-stale-rejected");
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, zoom.seq, 3)
    );
    await waitForStage(fixturePath, "zoom-synced");
    // A late older ACK must not undo a newer confirmation.
    peer.send(historyAck);

    const scroll = await peer.next("state");
    const scrollState = {
      ...zoomState,
      command: { answerID: "b", direction: -1, id: 4 },
    };
    expect(scroll.seq).toBe(6);
    expect(await decrypt(key, fixture.room, scroll)).toEqual(scrollState);
    await waitForStage(fixturePath, "scroll-pending");
    // Receiving the new snapshot does not prove its scroll command was applied.
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, scroll.seq, 3)
    );
    // Even claiming the current command cannot make an older snapshot current.
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, zoom.seq, 4)
    );
    await waitForStage(fixturePath, "scroll-command-rejected");
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, scroll.seq, 4)
    );

    await waitForStage(fixturePath, "selection-ready");
    const { publisher } = scroll;
    if (publisher === null) {
      throw new Error("The native publisher is disconnected");
    }
    const select = async (id: number, answerID: string) =>
      await selectAnswer(key, fixture.room, ready.client, {
        answerID,
        id,
        publisher,
      });
    peer.send(await select(1, "a"));
    const selected = await peer.next("state");
    expect(selected.seq).toBe(7);
    expect(await decrypt(key, fixture.room, selected)).toEqual({
      ...scrollState,
      selectedID: "a",
      selection: 2,
      selectionRequest: { client: ready.client, id: 1 },
    });
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, selected.seq, 4)
    );

    const navigated = await peer.next("state");
    expect(navigated.seq).toBe(8);
    expect(await decrypt(key, fixture.room, navigated)).toEqual({
      ...scrollState,
      selection: 3,
    });
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, navigated.seq, 4)
    );
    await waitForStage(fixturePath, "selection-repeat-ready");
    peer.send(await select(2, "b"));
    const repeated = await peer.next("state");
    expect(repeated.seq).toBe(9);
    const repeatedState = {
      ...scrollState,
      selection: 4,
      selectionRequest: { client: ready.client, id: 2 },
    };
    expect(await decrypt(key, fixture.room, repeated)).toEqual(repeatedState);
    peer.send(await select(1, "a"));
    peer.send(await select(2, "a"));
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, repeated.seq, 4)
    );

    const pending = await peer.next("state");
    expect(pending.seq).toBe(10);
    expect(await decrypt(key, fixture.room, pending)).toEqual({
      ...repeatedState,
      command: { answerID: "b", direction: 1, id: 5 },
    });
    // Neither reader acknowledges this command. Presence remains independent.
    await waitForStage(fixturePath, "native-reader-disconnected");
    await peer.close();
    const result = await execution;
    if (!result.ok) {
      throw result.error;
    }
    expect(result.output.stderr).toBe("");
  } catch (error) {
    // A stopped probe cannot advance a fixture or send the next packet.
    throw nativeFailure ?? error;
  } finally {
    controller.abort();
    await execution;
    await peer?.close();
  }
});
