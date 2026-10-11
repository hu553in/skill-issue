import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const storage = await mkdtemp(path.join(tmpdir(), "skill-issue-relay-check-"));
let child: ReturnType<typeof Bun.spawn> | undefined;
const stop = () => {
  child?.kill("SIGTERM");
};
process.once("SIGTERM", stop);
process.once("SIGINT", stop);
try {
  child = Bun.spawn(["bun", "run", "build:web"], {
    stderr: "inherit",
    stdout: "inherit",
  });
  const build = await child.exited;
  if (build !== 0) {
    throw new Error(`Viewer build exited with ${build}`);
  }
  child = Bun.spawn(
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
      process.env["E2E_PORT"] ?? "8788",
      "--persist-to",
      storage,
    ],
    {
      env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
      stderr: "inherit",
      stdout: "inherit",
    }
  );
  process.exitCode = await child.exited;
} finally {
  stop();
  await rm(storage, { force: true, recursive: true });
}
