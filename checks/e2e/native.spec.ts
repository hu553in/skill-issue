import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

import type { Packet } from "../../protocol";
import {
  acknowledgment,
  decrypt,
  empty,
  parseLink,
  unbase64,
} from "../../web/session";
import { expect, test } from "./fixtures";
import { Peer } from "./peer";

interface NativeFixture {
  room: string;
  viewerURL: string;
  packet: Packet;
}
// node:util intentionally discards execFile's returned ChildProcess in this overload.
// oxlint-disable-next-line typescript/strict-void-return
const execute = promisify(execFile);

test("CryptoKit snapshots and WebCrypto acknowledgments interoperate through the Worker", async ({
  baseURL,
}, testInfo) => {
  test.skip(
    process.platform !== "darwin",
    "The native URLSession/CryptoKit probe requires macOS"
  );
  if (baseURL === undefined || baseURL.length === 0) {
    throw new Error("The integration server URL is missing");
  }
  const binary = testInfo.outputPath("native-relay-check");
  const fixturePath = testInfo.outputPath("native-fixture.json");
  await execute("swift", [
    "build",
    "--target",
    "JOSESwift",
    "--jobs",
    "4",
    "--force-resolved-versions",
  ]);
  const { stdout } = await execute("swift", [
    "build",
    "--show-bin-path",
    "--force-resolved-versions",
  ]);
  const products = stdout.trim();
  await execute("xcrun", [
    "swiftc",
    "-swift-version",
    "6",
    "-warnings-as-errors",
    "-I",
    products,
    path.join(products, "JOSESwift.o"),
    "native/Core.swift",
    "native/Relay.swift",
    "checks/native_relay.swift",
    "-o",
    binary,
  ]);
  let peer: Peer | undefined;
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
      return { error, ok: false as const };
    }
  })();
  try {
    await expect
      .poll(async () => {
        try {
          return JSON.parse(
            await readFile(fixturePath, "utf-8")
          ) as NativeFixture;
        } catch (error) {
          if (
            error instanceof Error &&
            "code" in error &&
            error.code === "ENOENT"
          ) {
            return null;
          }
          throw error;
        }
      })
      .not.toBeNull();
    const fixture = JSON.parse(
      await readFile(fixturePath, "utf-8")
    ) as NativeFixture;
    const link = parseLink(new URL(fixture.viewerURL).hash);
    expect(link.room).toBe(fixture.room);
    const key = await crypto.subtle.importKey(
      "raw",
      unbase64(link.key),
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
    expect(packet).toEqual(fixture.packet);
    expect(await decrypt(key, fixture.room, packet)).toEqual({
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
    });
    peer.send(
      await acknowledgment(key, fixture.room, ready.client, packet.seq, 3)
    );
    expect(await peer.next("ended")).toEqual({ type: "ended" });
    const result = await execution;
    if (!result.ok) {
      throw result.error;
    }
    expect(result.output.stderr).toBe("");
    const closed = await peer.closed;
    expect(closed.code).toBe(1000);
  } finally {
    controller.abort();
    await execution;
    await peer?.close();
  }
});
