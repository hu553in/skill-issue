import { defineConfig, devices } from "@playwright/test";

const port = process.env["E2E_PORT"] ?? "8788";
if (!/^\d+$/u.test(port) || Number(port) < 1 || Number(port) > 65_535) {
  throw new Error("E2E_PORT must be an integer between 1 and 65535");
}
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  forbidOnly: Boolean(process.env["CI"]),
  fullyParallel: false,
  projects: [
    {
      name: "web",
      testMatch: "viewer.spec.ts",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { height: 844, width: 390 },
      },
    },
    { name: "relay", testMatch: "relay.spec.ts" },
    { name: "native", testMatch: "native.spec.ts" },
  ],
  reporter: "list",
  testDir: "./checks/e2e",
  use: {
    baseURL,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "bun checks/e2e/server.ts",
    env: { E2E_PORT: port },
    gracefulShutdown: { signal: "SIGTERM", timeout: 5000 },
    reuseExistingServer: false,
    url: baseURL,
  },
  workers: 1,
});
