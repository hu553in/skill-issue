import { test as base } from "@playwright/test";

import { RelaySession } from "../relay";

export const test = base.extend<{ clientIP: string; relay: RelaySession }>({
  clientIP: async ({ baseURL }, run) => {
    if (baseURL === undefined || new URL(baseURL).hostname !== "127.0.0.1") {
      throw new Error("Client IP isolation requires the local test server");
    }
    const address = `2001:db8:${Array.from(
      crypto.getRandomValues(new Uint16Array(6)),
      (part) => part.toString(16)
    ).join(":")}`;
    await run(address);
  },
  extraHTTPHeaders: async ({ clientIP, extraHTTPHeaders }, run) => {
    await run({ ...extraHTTPHeaders, "CF-Connecting-IP": clientIP });
  },
  relay: async ({ baseURL, clientIP }, run) => {
    if (baseURL === undefined || baseURL.length === 0) {
      throw new Error("The integration server URL is missing");
    }
    const relay = await RelaySession.create(baseURL, clientIP);
    try {
      await run(relay);
    } finally {
      await relay.dispose();
    }
  },
});
export { expect } from "@playwright/test";
