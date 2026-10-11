import { expect, mock, test } from "bun:test";

await mock.module("cloudflare:workers", () => ({
  DurableObject: class {
    readonly ctx: unknown;
    constructor(ctx: unknown) {
      this.ctx = ctx;
    }
  },
}));
const { default: worker } = await import("../relay/worker");
const id = "00000000-0000-0000-0000-000000000001";
const base = "https://relay.test";
const failure = "Couldn't complete that. Try again.";

function environment() {
  const requests: Request[] = [];
  const names: string[] = [];
  const buckets: string[] = [];
  const assets: Request[] = [];
  let allowed = true;
  const bindings = {
    ASSETS: {
      fetch: async (request: Request) => {
        assets.push(request);
        return new Response("viewer", {
          headers: {
            "Cache-Control": "max-age=60",
            "X-Powered-By": "fixture",
          },
        });
      },
    },
    ROOMS: {
      getByName: (name: string) => {
        names.push(name);
        return {
          fetch: async (request: Request) => {
            requests.push(request);
            return new Response("room");
          },
        };
      },
    },
    ROOM_LIMIT: {
      limit: async ({ key }: { key: string }) => {
        buckets.push(key);
        return { success: allowed };
      },
    },
  };
  // The fixture implements the binding methods used by this Worker.
  const env = bindings as unknown as Env;
  return {
    assets,
    buckets,
    deny: () => {
      allowed = false;
    },
    env,
    names,
    requests,
  };
}

test("room routes retain raw IDs, methods, query strings and invalid-path rejection", async () => {
  await Promise.all(
    ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"].flatMap(
      (method) =>
        ["socket", "end"].map(async (action) => {
          const fixture = environment();
          const request = new Request(
            `${base}/rooms/${id}/${action}?probe=value`,
            { method }
          );
          const response = await worker.fetch(request, fixture.env);
          expect(response.status).toBe(200);
          expect(fixture.requests).toEqual([request]);
          expect(fixture.names).toEqual([id]);
        })
    )
  );
  const fixture = environment();
  await Promise.all(
    [
      "/rooms/",
      "/rooms-extra",
      "/rooms/id/socket",
      `/rooms/${id}/socket/`,
      `/rooms/${id}/socket/extra`,
      `/rooms/${id}/unknown`,
      `/rooms/${"A".repeat(36)}/socket`,
      `/rooms/${"a".repeat(35)}/socket`,
      `/rooms/%30${id.slice(1)}/socket`,
      "/rooms%2f",
      "/rooms?ignored=value",
    ].map(async (path) => {
      const response = await worker.fetch(
        new Request(`${base}${path}`),
        fixture.env
      );
      expect(response.status, path).toBe(400);
      expect(await response.text()).toBe(failure);
      expect(response.headers.has("Content-Security-Policy")).toBe(false);
    })
  );
  expect(fixture.assets).toHaveLength(0);
});

test("only creation and socket attempts consume their existing IP buckets", async () => {
  const fixture = environment();
  const headers = { "CF-Connecting-IP": "192.0.2.10" };
  await worker.fetch(new Request(`${base}/rooms`, { headers }), fixture.env);
  await worker.fetch(
    new Request(`${base}/rooms/${id}/socket`, { headers }),
    fixture.env
  );
  await worker.fetch(
    new Request(`${base}/rooms/${id}/end`, { headers, method: "POST" }),
    fixture.env
  );
  await worker.fetch(
    new Request(`${base}/rooms/${id}/unknown`, { headers }),
    fixture.env
  );
  expect(fixture.buckets).toEqual(["create:192.0.2.10", "connect:192.0.2.10"]);
  fixture.deny();
  const denied = await worker.fetch(
    new Request(`${base}/rooms/${id}/socket`, { headers }),
    fixture.env
  );
  expect(denied.status).toBe(400);
  const ended = await worker.fetch(
    new Request(`${base}/rooms/${id}/end`, { headers, method: "POST" }),
    fixture.env
  );
  expect(ended.status).toBe(200);
  expect(fixture.buckets).toHaveLength(3);
});

test("room creation keeps random credentials private in storage and disables response caching", async () => {
  const fixture = environment();
  const response = await worker.fetch(
    new Request(`${base}/rooms`, { method: "POST" }),
    fixture.env
  );
  expect(response.status).toBe(200);
  expect(response.headers.get("Cache-Control")).toBe("no-store");
  const body: unknown = await response.json();
  expect(body).toMatchObject({
    id: expect.any(String) as unknown,
    reader: expect.stringMatching(/^[\w-]{43}$/u) as unknown,
    writer: expect.stringMatching(/^[\w-]{43}$/u) as unknown,
  });
  const persisted: unknown = await fixture.requests[0]?.json();
  expect(persisted).toMatchObject({
    expires: expect.any(Number) as unknown,
    readerHash: expect.stringMatching(/^[0-9a-f]{64}$/u) as unknown,
    writerHash: expect.stringMatching(/^[0-9a-f]{64}$/u) as unknown,
  });
  expect(JSON.stringify(persisted)).not.toContain('"reader":');
  expect(JSON.stringify(persisted)).not.toContain('"writer":');
  expect(fixture.requests[0]?.method).toBe("POST");
  expect(fixture.requests[0]?.url).toBe("https://room/init");
});

test("asset responses retain exactly the existing security policy and asset headers", async () => {
  const fixture = environment();
  const response = await worker.fetch(
    new Request(`${base}/viewer.js`),
    fixture.env
  );
  expect(await response.text()).toBe("viewer");
  expect(response.headers.get("Cache-Control")).toBe("max-age=60");
  expect(response.headers.get("X-Powered-By")).toBe("fixture");
  expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
  expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
  const directives = response.headers
    .get("Content-Security-Policy")
    ?.split("; ")
    .toSorted();
  expect(directives).toEqual(
    [
      "base-uri 'none'",
      "connect-src 'self' ws: wss:",
      "default-src 'self'",
      "frame-ancestors 'none'",
      "img-src 'self' data:",
      "script-src 'self'",
      "style-src 'self'",
    ].toSorted()
  );
  for (const header of [
    "Cross-Origin-Opener-Policy",
    "Cross-Origin-Resource-Policy",
    "Origin-Agent-Cluster",
    "Strict-Transport-Security",
    "X-DNS-Prefetch-Control",
    "X-Download-Options",
    "X-Frame-Options",
    "X-Permitted-Cross-Domain-Policies",
    "X-XSS-Protection",
  ]) {
    expect(response.headers.has(header)).toBe(false);
  }
});
