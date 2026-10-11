import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";

import { writeNotices } from "../scripts/notices";

const { join } = nodePath;
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(
    roots.splice(0).map(async (root) => {
      await rm(root, { force: true, recursive: true });
    })
  );
});
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "skill-issue-notices-"));
  roots.push(root);
  await Promise.all([
    Bun.write(join(root, "LICENSE"), "Project license text\n"),
    Bun.write(join(root, "THIRD_PARTY.md"), "Upstream notices\n"),
  ]);
  return root;
}
async function file(root: string, path: string, content: string) {
  const target = join(root, path);
  await mkdir(join(target, ".."), { recursive: true });
  await Bun.write(target, content);
}

test("web notices include installed production texts and omit development dependencies and local paths", async () => {
  const root = await fixture();
  await Promise.all([
    file(
      root,
      "runtime/package.json",
      JSON.stringify({
        license: "MIT",
        name: "@fixture/runtime",
        version: "1.2.3",
      })
    ),
    file(root, "runtime/LICENSE", "Runtime permission text\n"),
    file(root, "runtime/NOTICE/authors.txt", "Runtime attribution\n"),
    file(
      root,
      "development/package.json",
      JSON.stringify({ license: "MIT", name: "development", version: "9.0.0" })
    ),
    file(root, "development/LICENSE", "Development-only permission\n"),
    file(
      root,
      "package.json",
      JSON.stringify({
        dependencies: { "@fixture/runtime": "file:./runtime" },
        devDependencies: { development: "file:./development" },
        name: "fixture",
        private: true,
      })
    ),
  ]);
  const install = Bun.spawn(
    ["bun", "install", "--ignore-scripts", "--offline"],
    { cwd: root, stderr: "pipe", stdout: "ignore" }
  );
  if ((await install.exited) !== 0) {
    throw new Error(await new Response(install.stderr).text());
  }
  const output = join(root, "artifact/notices");
  await writeNotices(root, "web", output);
  expect(
    await readFile(join(output, "npm/@fixture/runtime/1.2.3/LICENSE"), "utf-8")
  ).toBe("Runtime permission text\n");
  expect(
    await readFile(
      join(output, "npm/@fixture/runtime/1.2.3/NOTICE/authors.txt"),
      "utf-8"
    )
  ).toBe("Runtime attribution\n");
  expect(await readFile(join(output, "LICENSE"), "utf-8")).toBe(
    "Project license text\n"
  );
  const index = await readFile(join(output, "index.json"), "utf-8");
  expect(index).toContain('"version": "1.2.3"');
  expect(index).not.toContain("development");
  expect(index).not.toContain(root);
});

test("Swift notices preserve nested and binary attribution while excluding stale checkouts and Git internals", async () => {
  const root = await fixture();
  await Promise.all([
    file(
      root,
      "Package.resolved",
      JSON.stringify({
        pins: [
          {
            identity: "library",
            location: "https://example.invalid/library.git",
            state: { revision: "abc123" },
          },
        ],
      })
    ),
    file(root, ".build/checkouts/Library/LICENSE", "Library license\n"),
    file(
      root,
      ".build/checkouts/Library/Source/vendor/LICENSE.MIT",
      "Vendored permission\n"
    ),
    file(root, ".build/checkouts/Library/.git/NOTICE", "Private Git data\n"),
    file(root, ".build/checkouts/stale/LICENSE", "Stale dependency\n"),
    file(
      root,
      ".build/artifacts/library/Binary/NOTICE",
      "Binary attribution\n"
    ),
  ]);
  const output = join(root, "artifact/notices");
  await writeNotices(root, "swift", output);
  expect(
    await readFile(
      join(output, "swift/library/Source/vendor/LICENSE.MIT"),
      "utf-8"
    )
  ).toBe("Vendored permission\n");
  expect(
    await readFile(
      join(output, "swift/library/artifacts/Binary/NOTICE"),
      "utf-8"
    )
  ).toBe("Binary attribution\n");
  const index = await readFile(join(output, "index.json"), "utf-8");
  expect(index).not.toContain(root);
  expect(index).not.toContain("stale");
  expect(index).not.toContain(".git/NOTICE");
});

test("Swift generation fails for missing checkouts and for attribution without license text", async () => {
  const root = await fixture();
  await Promise.all([
    file(
      root,
      "Package.resolved",
      JSON.stringify({
        pins: [
          {
            identity: "missing",
            location: "https://example.invalid/missing.git",
            state: { revision: "abc123" },
          },
        ],
      })
    ),
    file(root, ".build/checkouts/unrelated/LICENSE", "Unrelated license\n"),
  ]);
  const output = join(root, "artifact/notices");
  expect(writeNotices(root, "swift", output)).rejects.toThrow(
    "Missing checkout for missing"
  );
  await file(
    root,
    ".build/checkouts/missing/NOTICE",
    "Attribution is not the license\n"
  );
  expect(writeNotices(root, "swift", output)).rejects.toThrow(
    "Missing license text for missing"
  );
  expect(await Bun.file(join(output, "index.json")).exists()).toBe(false);
});

test.each([
  { content: "Attribution only\n", identity: "license", path: "NOTICE" },
  { content: "", identity: "library", path: "LICENSE" },
  { content: " \n\t", identity: "library", path: "LICENSE" },
])(
  "Swift notices reject insufficient license text: %j",
  async ({ identity, path, content }) => {
    const root = await fixture();
    await Promise.all([
      file(
        root,
        "Package.resolved",
        JSON.stringify({
          pins: [
            {
              identity,
              location: `https://example.invalid/${identity}.git`,
              state: { revision: "abc123" },
            },
          ],
        })
      ),
      file(root, `.build/checkouts/${identity}/${path}`, content),
    ]);
    const output = join(root, "artifact/notices");
    expect(writeNotices(root, "swift", output)).rejects.toThrow(
      `Missing license text for ${identity}`
    );
    expect(await Bun.file(join(output, "index.json")).exists()).toBe(false);
  }
);
