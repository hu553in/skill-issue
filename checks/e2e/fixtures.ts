import { test as base } from "@playwright/test";

import { RelaySession } from "../relay";

export const test = base.extend<{ relay: RelaySession }>({
  relay: async ({ baseURL }, run) => {
    if (baseURL === undefined || baseURL.length === 0) {
      throw new Error("The integration server URL is missing");
    }
    const relay = await RelaySession.create(baseURL);
    try {
      await run(relay);
    } finally {
      await relay.dispose();
    }
  },
});
export { expect } from "@playwright/test";
