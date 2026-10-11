import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";
import react from "ultracite/oxlint/react";

export default defineConfig({
  extends: [core, react],
  ignorePatterns: ["**/worker-configuration.d.ts"],
  options: { typeAware: true },
  overrides: [
    {
      files: ["web/**/*.tsx"],
      rules: {
        "unicorn/filename-case": [
          "error",
          { cases: { camelCase: true, pascalCase: true } },
        ],
      },
    },
    {
      files: ["web/main.tsx"],
      rules: {
        // The labeled reading region supports native keyboard scrolling.
        "jsx-a11y/no-noninteractive-tabindex": "off",
        // Preserve ordered snapshot application in the socket event callback.
        "promise/avoid-new": "off",
        "promise/no-nesting": "off",
        "promise/prefer-await-to-then": "off",
        // Reset viewer state when the external session link changes.
        "react/set-state-in-effect": "off",
        // React effects return cleanup only when the session was started.
        "typescript/consistent-return": "off",
      },
    },
    {
      files: ["web/main.tsx", "web/session.ts", "relay/worker.ts"],
      rules: {
        // Keep schema validation and ordered protocol transitions together.
        complexity: "off",
      },
    },
    {
      files: ["relay/worker.ts"],
      rules: {
        // Durable Object storage mutations run in transaction order.
        "no-await-in-loop": "off",
      },
    },
    {
      files: ["checks/protocol.test.ts"],
      rules: {
        // In-memory fixtures implement async platform APIs without I/O.
        "require-await": "off",
      },
    },
    {
      files: [
        "checks/protocol.test.ts",
        "checks/relay.ts",
        "checks/e2e/native.spec.ts",
        "checks/e2e/peer.ts",
      ],
      rules: {
        // Tests assert partial platform fixtures and outputs from owned probes.
        "typescript/no-unsafe-type-assertion": "off",
      },
    },
  ],
  rules: {
    // Shared protocol helpers keep named, hoisted functions.
    "func-style": "off",
    "no-use-before-define": ["error", { functions: false }],
    // React Compiler is not enabled in this Vite build.
    "react/todo": "off",
  },
});
