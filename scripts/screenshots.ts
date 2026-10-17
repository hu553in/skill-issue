import { cp, mkdir, mkdtemp, readdir, rename, rm } from "node:fs/promises";
import path from "node:path";

import type { Browser } from "@playwright/test";
import { chromium, expect } from "@playwright/test";

import { RelaySession } from "../checks/relay";
import { empty } from "../web/session";

const root = path.resolve(import.meta.dir, "..");
process.chdir(root);
if (process.platform !== "darwin") {
  throw new Error(
    "README screenshots require macOS with a logged-in desktop session."
  );
}
const build = path.join(root, ".build/screenshots");
await mkdir(build, { recursive: true });
const temporary = await mkdtemp(path.join(build, "capture-"));
const output = path.join(root, "assets/screenshots/overview.svg");
const nativePNG = path.join(temporary, "settings.png");
const settingsFrameSize = { height: 1760, width: 1400 };
const viewerFrameSize = { height: 1840, width: 1040 };
let child: ReturnType<typeof Bun.spawn> | undefined;
let browser: Browser | undefined;
let server: Bun.Subprocess<"ignore", "pipe", "pipe"> | undefined;
let serverLogs: Promise<unknown>[] = [];
let cleanupPromise: Promise<void> | undefined;
let browserSetup: Promise<Browser> | undefined;
const generationFinished = Promise.withResolvers<boolean>();

function checkInterrupted() {
  if (cleanupPromise) {
    throw new Error("Screenshot generation was interrupted.");
  }
}

function kill(pid: number) {
  try {
    process.kill(pid, "SIGTERM");
  } catch (error) {
    if (
      !(error instanceof Error) ||
      !("code" in error) ||
      error.code !== "ESRCH"
    ) {
      throw error;
    }
  }
}

async function stopCommand() {
  if (child && child.exitCode === null) {
    try {
      // open -W is a launcher; the application has its own PID.
      const pidFile = Bun.file(`${nativePNG}.pid`);
      if (await pidFile.exists()) {
        const pid = Number(await pidFile.text());
        if (Number.isInteger(pid) && pid > 0) {
          kill(pid);
        }
      }
    } finally {
      kill(-child.pid);
      await child.exited;
    }
  }
}

async function stopViewer() {
  // This server and its storage are disposable. Stopping it also releases any
  // pending room request and closes the session sockets without an HTTP deletion.
  if (server) {
    kill(-server.pid);
    await server.exited;
    await Promise.allSettled(serverLogs);
  }
}

async function stopBrowser() {
  // Chromium may exist before launch resolves; the capture path reports launch failures.
  const started = await browserSetup?.catch(() => null);
  await started?.close();
}

async function cleanup() {
  cleanupPromise ??= (async () => {
    const stopped = await Promise.allSettled([
      stopViewer(),
      stopCommand(),
      stopBrowser(),
    ]);
    // Let pending file operations finish before removing their destination.
    await generationFinished.promise;
    await rm(temporary, { force: true, recursive: true });
    const errors = stopped
      .filter((result) => result.status === "rejected")
      .map((result): unknown => result.reason);
    if (errors.length > 0) {
      throw new AggregateError(
        errors,
        "Could not clean up screenshot resources."
      );
    }
  })();
  await cleanupPromise;
}
for (const [signal, code] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
] as const) {
  process.once(signal, () => {
    void (async () => {
      try {
        await cleanup();
      } finally {
        process.exit(code);
      }
    })();
  });
}

async function run(command: string[]) {
  checkInterrupted();
  const running = Bun.spawn(command, {
    detached: true,
    env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
    stderr: "inherit",
    stdout: "pipe",
  });
  child = running;
  const [code, stdout] = await Promise.all([
    running.exited,
    new Response(running.stdout).text(),
  ]);
  checkInterrupted();
  if (code !== 0) {
    throw new Error(`${command.join(" ")} exited with ${code}\n${stdout}`);
  }
  return stdout.trim();
}

async function captureSettings() {
  console.log("Building the isolated Settings screenshot app…");
  const swift = ["swift", "build", "--scratch-path", build];
  await run([
    ...swift,
    "--jobs",
    "4",
    "--force-resolved-versions",
    "-Xswiftc",
    "-DREADME_SCREENSHOTS",
  ]);
  const binaries = await run([...swift, "--show-bin-path"]);
  const bundle = path.join(temporary, "Skill Issue Screenshots.app/Contents");
  await mkdir(path.join(bundle, "MacOS"), { recursive: true });
  await mkdir(path.join(bundle, "Resources"));
  await cp(
    path.join(binaries, "SkillIssue"),
    path.join(bundle, "MacOS/SkillIssue")
  );
  const resources = await readdir(binaries);
  for (const bundleName of resources.filter((name) =>
    name.endsWith(".bundle")
  )) {
    // Each copy must settle before cleanup can remove its destination after a failure.
    // eslint-disable-next-line no-await-in-loop
    await cp(
      path.join(binaries, bundleName),
      path.join(bundle, "Resources", bundleName),
      { recursive: true }
    );
  }
  const plist = path.join(bundle, "Info.plist");
  await cp(path.join(root, "scripts/Info.plist"), plist);
  await run([
    "plutil",
    "-replace",
    "CFBundleIdentifier",
    "-string",
    "com.github.hu553in.skill-issue.readme-screenshots",
    plist,
  ]);
  await run([
    "plutil",
    "-replace",
    "CFBundleName",
    "-string",
    "Skill Issue Screenshots",
    plist,
  ]);
  await run(["plutil", "-replace", "LSUIElement", "-bool", "NO", plist]);
  await run(["codesign", "--force", "--sign", "-", path.dirname(bundle)]);
  console.log("Exporting Settings with demo data…");
  await run([
    "open",
    "-n",
    "-W",
    path.dirname(bundle),
    "--args",
    nativePNG,
    "-AppleLanguages",
    "(en)",
    "-AppleLocale",
    "en_US",
    "-AppleAccentColor",
    "4",
  ]);
  await rm(`${nativePNG}.pid`, { force: true });
  if (!(await Bun.file(nativePNG).exists())) {
    const error = Bun.file(`${nativePNG}.error`);
    throw new Error(
      (await error.exists())
        ? await error.text()
        : "Settings did not export a PNG. Check that the macOS desktop is unlocked."
    );
  }
  return Buffer.from(await Bun.file(nativePNG).arrayBuffer());
}

async function captureViewer() {
  console.log("Building and capturing the local viewer…");
  await run(["bun", "run", "build:web"]);
  const base = await startViewer();
  const relay = await RelaySession.create(base);
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "index-demo",
        language: "English",
        status: "complete",
        text: await Bun.file(
          path.join(import.meta.dir, "screenshots-answer.md")
        ).text(),
      },
    ],
    canAnswer: true,
    live: true,
    selectedID: "index-demo",
  });
  checkInterrupted();
  browserSetup = chromium.launch();
  browser = await browserSetup;
  checkInterrupted();
  const page = await browser.newPage({
    colorScheme: "dark",
    deviceScaleFactor: 2,
    locale: "en-US",
    reducedMotion: "reduce",
    viewport: { height: 840, width: 450 },
  });
  await page.goto(await relay.viewerURL());
  await expect(
    page.getByRole("heading", { name: "Why use a database index?" })
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.locator(".answer")).toHaveAttribute("aria-busy", "false");
  await page.evaluate(async () => await document.fonts.ready);
  return await page.screenshot({ animations: "disabled" });
}

async function startViewer() {
  checkInterrupted();
  const ready = Promise.withResolvers<string>();
  server = Bun.spawn(
    [
      "bun",
      "x",
      "--no-install",
      "wrangler",
      "dev",
      "--local",
      "--ip",
      "127.0.0.1",
      "--port",
      "0",
      "--inspector-port",
      "0",
      "--persist-to",
      path.join(temporary, "relay"),
    ],
    {
      detached: true,
      env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" },
      stderr: "pipe",
      stdin: "ignore",
      stdout: "pipe",
    }
  );
  const timeout = setTimeout(() => {
    ready.reject(new Error("Local viewer startup timed out."));
  }, 30_000);
  async function read(stream: ReadableStream<Uint8Array>) {
    let log = "";
    const decoder = new TextDecoder();
    try {
      for await (const chunk of stream) {
        log += decoder.decode(chunk, { stream: true });
        // A pipe chunk can end in the middle of the port number.
        const address =
          /Ready on (?<address>http:\/\/127\.0\.0\.1:\d+)(?=\s)/u.exec(log)
            ?.groups?.["address"];
        if (address !== undefined) {
          ready.resolve(address);
        }
      }
      ready.reject(new Error(`Local viewer stopped before startup:\n${log}`));
    } catch (error) {
      ready.reject(error);
    }
  }
  serverLogs = [read(server.stdout), read(server.stderr)];
  try {
    return await ready.promise;
  } finally {
    clearTimeout(timeout);
  }
}

// Keep room around both windows, then scale their frames to the same displayed height.
async function frame(png: Buffer, settings: boolean) {
  if (!browser) {
    throw new Error("Chromium was not started");
  }
  const { height, width } = settings ? settingsFrameSize : viewerFrameSize;
  const page = await browser.newPage({
    deviceScaleFactor: 1,
    viewport: { height, width },
  });
  try {
    await page.setContent(`<!doctype html><html><head><style>
      html,body{margin:0;width:100%;height:100%;overflow:hidden}
      body{display:flex;align-items:center;justify-content:center;background:
        radial-gradient(ellipse at 12% 0%,#34564a 0,transparent 65%),
        radial-gradient(ellipse at 100% 100%,#3b3430 0,transparent 65%),#182222}
      img{display:block;width:${settings ? 1040 : 900}px;height:auto;
        border-radius:${settings ? 32 : 48}px;
        box-shadow:0 30px 50px #0003,0 80px 100px #0005,0 0 0 2px #a4c2b522}
      </style></head><body><img alt="" src="data:image/png;base64,${png.toString("base64")}"></body></html>`);
    const dimensions = await page.locator("img").evaluate(async (img) => {
      if (!(img instanceof HTMLImageElement)) {
        throw new Error("Missing frame image");
      }
      await img.decode();
      return { height: img.naturalHeight, width: img.naturalWidth };
    });
    if (
      dimensions.width !== (settings ? 1040 : 900) ||
      dimensions.height > height - 160
    ) {
      throw new Error(
        `Unexpected ${settings ? "Settings" : "viewer"} size: ${dimensions.width}×${dimensions.height}. Update the framing before publishing.`
      );
    }
    return await page.screenshot({ animations: "disabled" });
  } finally {
    await page.close();
  }
}

try {
  const settings = await captureSettings();
  const viewer = await captureViewer();
  const settingsFrame = await frame(settings, true);
  const viewerFrame = await frame(viewer, false);
  const { height } = settingsFrameSize;
  const viewerWidth = (viewerFrameSize.width * height) / viewerFrameSize.height;
  const viewerX = settingsFrameSize.width + 40;
  const width = viewerX + viewerWidth;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="none">
  <title>Skill Issue settings and phone viewer</title>
  <desc>macOS settings with a demo account and the phone viewer with a sample answer, shown at the same height.</desc>
  <defs>
    <clipPath id="settings-frame"><rect width="${settingsFrameSize.width}" height="${height}" rx="40" /></clipPath>
    <clipPath id="viewer-frame"><rect x="${viewerX}" width="${viewerWidth}" height="${height}" rx="40" /></clipPath>
  </defs>
  <image width="${settingsFrameSize.width}" height="${height}" clip-path="url(#settings-frame)" xlink:href="data:image/png;base64,${settingsFrame.toString("base64")}" />
  <image x="${viewerX}" width="${viewerWidth}" height="${height}" clip-path="url(#viewer-frame)" xlink:href="data:image/png;base64,${viewerFrame.toString("base64")}" />
</svg>
`;
  if (
    (await Bun.file(output).exists()) &&
    (await Bun.file(output).text()) === svg
  ) {
    console.log("README screenshots are unchanged.");
  } else {
    const staged = path.join(temporary, "overview.svg");
    await Bun.write(staged, svg);
    checkInterrupted();
    await rename(staged, output);
    console.log("Updated assets/screenshots/overview.svg");
  }
} finally {
  generationFinished.resolve(true);
  await cleanup();
}
