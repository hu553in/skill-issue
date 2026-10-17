import { expect, test } from "bun:test";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(
  new URL("../scripts/prompt-eval/cli.ts", import.meta.url)
);

async function runCLI(args: string[]) {
  const child = Bun.spawn([process.execPath, cli, ...args], {
    cwd: tmpdir(),
    // Offline modes must stop before Swift builds or saved-account access.
    env: { PATH: "" },
    stderr: "pipe",
    stdout: "pipe",
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { exitCode, stderr, stdout };
}

test("prompt eval CLI help runs without tools or a repository working directory", async () => {
  const result = await runCLI(["--help"]);
  expect(result.exitCode).toBe(0);
  expect(result.stderr).toBe("");
  expect(result.stdout).toContain("Usage: bun eval:prompts");
  expect(result.stdout).toContain("--models");
});

test("prompt eval CLI lists a selected real fixture without building the worker", async () => {
  const result = await runCLI(["--list", "--case", "hash-collisions"]);
  expect(result.exitCode).toBe(0);
  expect(result.stderr).toBe("");
  expect(result.stdout.trim().split("\n")).toEqual([
    "hash-collisions\tRussian\tExplain hash collisions without conflating hashing and equality",
  ]);
});

test("prompt eval CLI rejects a nonexistent case before starting the worker", async () => {
  const result = await runCLI(["--case", "does-not-exist"]);
  expect(result.exitCode).toBe(1);
  expect(result.stdout).toBe("");
  expect(result.stderr).toBe(
    "Prompt eval stopped: Unknown case IDs: does-not-exist\n"
  );
});
