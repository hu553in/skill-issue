import { readFile } from "node:fs/promises";

import { defineConfig } from "vite";

export default defineConfig({
  build: {
    license: { fileName: "notices/index.json" },
  },
  plugins: [
    {
      async generateBundle() {
        await Promise.all(
          ["LICENSE", "THIRD_PARTY.md"].map(async (file) => {
            this.emitFile({
              fileName: `notices/${file}`,
              source: await readFile(
                new URL(`../${file}`, import.meta.url),
                "utf-8"
              ),
              type: "asset",
            });
          })
        );
      },
      name: "project-notices",
    },
  ],
});
