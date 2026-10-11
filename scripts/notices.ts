import { copyFile, mkdir, readdir } from "node:fs/promises";
import nodePath from "node:path";

const { dirname, join, relative, resolve } = nodePath;

interface Dependency {
  name: string;
  version: string;
  license?: string;
  location?: string;
  files: string[];
}
interface BunLicense {
  name: string;
  paths: string[];
  license: string;
}
interface SwiftPin {
  identity: string;
  location: string;
  state: { revision: string; version?: string };
}
const noticeName = /^(?:licen[cs]es?|notices?|copying)(?:$|[._-])/iu;
const licenseName = /^(?:licen[cs]es?|copying)(?:$|[._-])/iu;
async function hasLicense(directory: string, files: string[]) {
  const contents = await Promise.all(
    files
      .filter((file) => file.split("/").some((part) => licenseName.test(part)))
      .map(async (file) => await Bun.file(join(directory, file)).text())
  );
  return contents.some((text) => text.trim().length > 0);
}

async function noticeFiles(
  directory: string,
  optional = false
): Promise<string[]> {
  try {
    await readdir(directory);
  } catch (error) {
    if (
      optional &&
      error instanceof Error &&
      "code" in error &&
      error.code === "ENOENT"
    ) {
      return [];
    }
    throw error;
  }
  const files = await Array.fromAsync(
    new Bun.Glob("**/*").scan({ cwd: directory, dot: true, onlyFiles: true })
  );
  return files
    .filter((file) => {
      const parts = file.split("/");
      return (
        !parts.includes(".git") &&
        !parts.includes("node_modules") &&
        parts.some((part) => noticeName.test(part))
      );
    })
    .toSorted();
}

export async function writeNotices(
  root: string,
  mode: "web" | "swift",
  destination: string
) {
  const output = resolve(destination);
  const copies: { source: string; target: string }[] = [];
  const collect = async (source: string, target: string, optional = false) => {
    const files = await noticeFiles(source, optional);
    for (const file of files) {
      copies.push({ source: join(source, file), target: join(target, file) });
    }
    return {
      files: files.map((file) => join(target, file)),
      licensed: await hasLicense(source, files),
    };
  };
  let dependencies: Dependency[];
  if (mode === "web") {
    const command = Bun.spawn(["bun", "pm", "licenses", "--prod", "--json"], {
      cwd: root,
      stderr: "pipe",
      stdout: "pipe",
    });
    const [stdout, stderr, status] = await Promise.all([
      new Response(command.stdout).text(),
      new Response(command.stderr).text(),
      command.exited,
    ]);
    if (status !== 0) {
      throw new Error(`Cannot inventory production dependencies: ${stderr}`);
    }
    // Bun's licenses command owns this inventory schema.
    // oxlint-disable-next-line typescript/no-unsafe-assignment
    const groups: Record<string, BunLicense[]> = JSON.parse(stdout);
    dependencies = await Promise.all(
      Object.values(groups).flatMap((group) =>
        group.flatMap((dependency) =>
          dependency.paths.map(async (path) => {
            // These installed package manifests were accepted by Bun.
            // oxlint-disable-next-line typescript/no-unsafe-assignment
            const metadata: { version: string } = await Bun.file(
              join(path, "package.json")
            ).json();
            const { files, licensed } = await collect(
              path,
              join("npm", dependency.name, metadata.version)
            );
            if (!licensed) {
              throw new Error(`Missing license text for ${dependency.name}`);
            }
            return {
              files,
              license: dependency.license,
              name: dependency.name,
              version: metadata.version,
            };
          })
        )
      )
    );
  } else {
    // SwiftPM owns this lockfile and generated the matching checkouts.
    // oxlint-disable-next-line typescript/no-unsafe-assignment
    const lock: { pins: SwiftPin[] } = await Bun.file(
      join(root, "Package.resolved")
    ).json();
    const checkoutRoot = join(root, ".build/checkouts");
    const checkouts = await readdir(checkoutRoot);
    dependencies = await Promise.all(
      lock.pins.map(async (pin) => {
        const checkout = checkouts.find(
          (name) => name.toLowerCase() === pin.identity
        );
        if (checkout === undefined) {
          throw new Error(
            `Missing checkout for ${pin.identity}; build Swift first`
          );
        }
        const { files, licensed } = await collect(
          join(checkoutRoot, checkout),
          join("swift", pin.identity)
        );
        if (!licensed) {
          throw new Error(`Missing license text for ${pin.identity}`);
        }
        const artifacts = await collect(
          join(root, ".build/artifacts", pin.identity),
          join("swift", pin.identity, "artifacts"),
          true
        );
        files.push(...artifacts.files);
        return {
          files,
          location: pin.location,
          name: pin.identity,
          version: pin.state.version ?? pin.state.revision,
        };
      })
    );
  }
  for (const file of ["LICENSE", "THIRD_PARTY.md"]) {
    copies.push({ source: join(root, file), target: file });
  }
  await Promise.all(
    copies.map(async ({ source, target }) => {
      const path = resolve(output, target);
      if (relative(output, path).startsWith("..")) {
        throw new Error(`Invalid notice path: ${target}`);
      }
      await mkdir(dirname(path), { recursive: true });
      await copyFile(source, path);
    })
  );
  await Bun.write(
    join(output, "index.json"),
    `${JSON.stringify(
      dependencies.toSorted(
        (a, b) =>
          a.name.localeCompare(b.name) || a.version.localeCompare(b.version)
      ),
      null,
      2
    )}\n`
  );
}

if (import.meta.main) {
  const [mode, output, ...extra] = process.argv.slice(2);
  if (
    (mode !== "web" && mode !== "swift") ||
    output === undefined ||
    output.length === 0 ||
    extra.length > 0
  ) {
    throw new Error("Usage: bun scripts/notices.ts web|swift OUTPUT");
  }
  await writeNotices(resolve(import.meta.dir, ".."), mode, output);
}
