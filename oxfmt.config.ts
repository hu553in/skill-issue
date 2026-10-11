import { defineConfig } from "oxfmt";
import ultracite from "ultracite/oxfmt";

export default defineConfig({
  ...ultracite,
  ignorePatterns: ["**/worker-configuration.d.ts", ".codex/environments/**"],
  overrides: [
    ...(ultracite.overrides ?? []),
    {
      files: ["**/*.md", "**/*.yml", "**/*.yaml"],
      options: { printWidth: 100, proseWrap: "always", singleQuote: true },
    },
  ],
});
