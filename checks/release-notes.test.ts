import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";

const { join } = nodePath;
const deployButton =
  /\]\((?<url>https:\/\/deploy\.workers\.cloudflare\.com\/\?[^)]+)\)/u;

test("release instructions pin the app, source and Bun while preserving the changelog", async () => {
  const root = await mkdtemp(join(tmpdir(), "skill-issue-release-"));
  try {
    await mkdir(join(root, "scripts"));
    await Bun.write(
      join(root, "scripts/release-notes.ts"),
      Bun.file(new URL("../scripts/release-notes.ts", import.meta.url))
    );
    await Bun.write(
      join(root, "package.json"),
      JSON.stringify({ packageManager: "bun@1.2.3", version: "2.3.4" })
    );
    const changelog =
      "## Changes\n\nA fix with `code`, $variables and a [link](https://example.com).\n";
    await Bun.write(join(root, "changes.md"), changelog);
    const generate = async (tag: string) => {
      const process = Bun.spawn(
        ["bun", "scripts/release-notes.ts", tag, "changes.md"],
        { cwd: root, stderr: "pipe", stdout: "pipe" }
      );
      const [code, stdout, stderr] = await Promise.all([
        process.exited,
        new Response(process.stdout).text(),
        new Response(process.stderr).text(),
      ]);
      return { code, stderr, stdout };
    };
    const valid = await generate("v2.3.4");
    expect(valid.code).toBe(0);
    expect(valid.stdout).toContain(
      "/releases/download/v2.3.4/Skill-Issue-macos-arm64.zip"
    );
    const button = deployButton.exec(valid.stdout);
    expect(new URL(button?.groups?.["url"] ?? "").searchParams.get("url")).toBe(
      "https://github.com/hu553in/skill-issue/tree/v2.3.4"
    );
    expect(valid.stdout).toContain(
      "| Build variable `BUN_VERSION` | `1.2.3` |"
    );
    expect(valid.stdout).toContain(
      "git clone --branch v2.3.4 --depth 1 https://github.com/hu553in/skill-issue.git skill-issue-v2.3.4"
    );
    expect(valid.stdout).toContain("/blob/v2.3.4/README.md#cloudflare-access");
    expect(valid.stdout.endsWith(changelog)).toBe(true);

    const mismatched = await generate("v2.3.5");
    expect(mismatched.code).not.toBe(0);
    expect(mismatched.stdout).toBe("");
    expect(mismatched.stderr).toContain("Release tag must match package.json");

    await Bun.write(
      join(root, "package.json"),
      JSON.stringify({ packageManager: "bun@latest", version: "2.3.4" })
    );
    const unpinned = await generate("v2.3.4");
    expect(unpinned.code).not.toBe(0);
    expect(unpinned.stdout).toBe("");
    expect(unpinned.stderr).toContain("exact Bun version");
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});
