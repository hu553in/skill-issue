import type { Locator, WebSocketRoute } from "@playwright/test";
import { base64 } from "@scure/base";
import { object, parse, string } from "valibot";

import { parseViewerMessage } from "../../protocol";
import type { ViewState } from "../../protocol";
import { empty, failure } from "../../web/session";
import { RelaySession } from "../relay";
import { expect, test } from "./fixtures";

type AnswerCard = ViewState["answers"][number];

async function decryptAcknowledgment(
  relay: RelaySession,
  ack: { box: string; client: string; seq: number }
): Promise<unknown> {
  const bytes = base64.decode(ack.box);
  const plaintext = await crypto.subtle.decrypt(
    {
      additionalData: new TextEncoder().encode(
        `${relay.room.id}:ack:${ack.client}:${ack.seq}`
      ),
      iv: bytes.slice(0, 12),
      name: "AES-GCM",
    },
    relay.key,
    bytes.slice(12)
  );
  return JSON.parse(new TextDecoder().decode(plaintext));
}

async function readSelection(relay: RelaySession) {
  const request = await relay.writer.next("select");
  const bytes = base64.decode(request.box);
  const plain = await crypto.subtle.decrypt(
    {
      additionalData: new TextEncoder().encode(
        `${relay.room.id}:select:${request.client}:${request.publisher}:${request.id}`
      ),
      iv: bytes.slice(0, 12),
      name: "AES-GCM",
    },
    relay.key,
    bytes.slice(12)
  );
  const payload = parse(
    object({ answerID: string() }),
    JSON.parse(new TextDecoder().decode(plain))
  );
  return { ...request, ...payload };
}

const navigationState: ViewState = {
  ...empty,
  answers: ["a", "b", "c"].map((id) => ({
    id,
    language: "English",
    status: "complete",
    text: `# Answer ${id}\n\n${"A paragraph to read.\n\n".repeat(70)}`,
  })),
  live: true,
  selectedID: "c",
  selection: 3,
};

test("phone navigation survives delayed confirmations and shares the final choice with other viewers", async ({
  page,
  context,
  relay,
}) => {
  await relay.publish(navigationState);
  const other = await context.newPage();
  await page.goto(await relay.viewerURL());
  await other.goto(await relay.viewerURL());
  await expect(page.locator(".position")).toHaveText("3 / 3");
  await expect(other.locator(".position")).toHaveText("3 / 3");
  await expect(
    page.getByRole("button", { name: "Next answer" })
  ).toBeDisabled();
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await pane.evaluate((element) => {
    element.scrollTop = 460;
  });
  const saved = await position(pane);
  await page.getByRole("button", { name: "Previous answer" }).click();
  await page.getByRole("button", { name: "Previous answer" }).click();
  await expect(page.locator(".position")).toHaveText("1 / 3");
  await expect(
    page.getByRole("button", { name: "Previous answer" })
  ).toBeDisabled();
  const first = await readSelection(relay);
  const second = await readSelection(relay);
  expect(first.answerID).toBe("b");
  expect(second.answerID).toBe("a");
  expect(second.id).toBeGreaterThan(first.id);
  await relay.publish({
    ...navigationState,
    selectedID: "b",
    selection: 4,
    selectionRequest: { client: first.client, id: first.id },
  });
  await expect(other.locator(".position")).toHaveText("2 / 3");
  await expect(page.locator(".position")).toHaveText("1 / 3");
  // A Mac action is processed between the two phone requests.
  await relay.publish({ ...navigationState, selection: 5 });
  await expect(other.locator(".position")).toHaveText("3 / 3");
  await expect(page.locator(".position")).toHaveText("1 / 3");
  await relay.publish({
    ...navigationState,
    selectedID: "a",
    selection: 6,
    selectionRequest: { client: second.client, id: second.id },
  });
  await expect(other.locator(".position")).toHaveText("1 / 3");
  await relay.publish({ ...navigationState, selection: 7 });
  await expect(page.locator(".position")).toHaveText("3 / 3");
  await expect(other.locator(".position")).toHaveText("3 / 3");
  await expect.poll(async () => await position(pane)).toBeCloseTo(saved, 0);
  await page.getByRole("button", { name: "Previous answer" }).click();
  const final = await readSelection(relay);
  const confirmed: ViewState = {
    ...navigationState,
    selectedID: "b",
    selection: 8,
    selectionRequest: { client: final.client, id: final.id },
  };
  await relay.publish(confirmed);
  await expect(other.locator(".position")).toHaveText("2 / 3");
  await relay.publish({
    ...confirmed,
    command: { answerID: "b", direction: 1, id: 1 },
  });
  const height = await pane.evaluate((element) => element.clientHeight);
  await expect
    .poll(async () => Math.abs((await position(pane)) - height / 2))
    .toBeLessThanOrEqual(1);
  await other.close();
});

test("browser disconnection keeps local navigation and reconnect adopts Mac selection without replaying taps", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let reconnect = false;
  const requests: string[] = [];
  const resume = (socket: WebSocketRoute) => {
    const server = socket.connectToServer();
    socket.onMessage((message) => {
      if (String(message).includes('"type":"select"')) {
        requests.push(String(message));
      }
      server.send(message);
    });
  };
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length === 1 || reconnect) {
      resume(socket);
    }
  });
  await relay.publish({ ...navigationState, selectedID: "b" });
  await page.goto(await relay.viewerURL());
  await expect(page.locator(".position")).toHaveText("2 / 3");
  const [initial] = sockets;
  if (!initial) {
    throw new Error("No viewer socket");
  }
  await initial.close({ code: 1001 });
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  await page.getByRole("button", { name: "Previous answer" }).click();
  await expect(page.locator(".position")).toHaveText("1 / 3");
  await relay.publish({ ...navigationState, selectedID: "b", selection: 4 });
  await expect.poll(() => sockets.length).toBe(2);
  reconnect = true;
  for (const socket of sockets.slice(1)) {
    resume(socket);
  }
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.locator(".position")).toHaveText("2 / 3");
  expect(requests).toEqual([]);
  await page.getByRole("button", { name: "Next answer" }).click();
  const request = await readSelection(relay);
  expect(request.answerID).toBe("c");
  expect(requests).toHaveLength(1);
});

test("Mac replacement restores shared navigation and skips old scroll commands", async ({
  page,
  relay,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await relay.publish(navigationState);
  await page.goto(await relay.viewerURL());
  await expect(page.locator(".position")).toHaveText("3 / 3");
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await pane.evaluate((element) => {
    element.scrollTop = 320;
  });
  const saved = await position(pane);
  await page.getByRole("button", { name: "Previous answer" }).click();
  // Deliberately never confirmed by the old Mac.
  await readSelection(relay);
  const replacement = await relay.connect("writer");
  await relay.publish(
    { ...navigationState, command: { answerID: "c", direction: 1, id: 10 } },
    replacement.peer
  );
  await expect(page.locator(".position")).toHaveText("3 / 3");
  await expect.poll(async () => await position(pane)).toBeCloseTo(saved, 0);
  await replacement.peer.close();
  await expect(page.getByRole("status")).toHaveText("Mac disconnected");
  await page.getByRole("button", { name: "Previous answer" }).click();
  await expect(page.locator(".position")).toHaveText("2 / 3");
  await relay.end();
  await expect(page.getByRole("status")).toHaveText("Session ended");
  await page.getByRole("button", { name: "Previous answer" }).click();
  await expect(page.locator(".position")).toHaveText("1 / 3");
  await pane.evaluate((element) => {
    element.scrollTop = 500;
  });
  await expect.poll(async () => await position(pane)).toBe(500);
});

test("navigation buttons handle empty and single-answer histories", async ({
  page,
  relay,
}) => {
  await relay.publish({ ...empty, live: true });
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(
    page.getByRole("button", { name: "Previous answer" })
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Next answer" })
  ).toBeDisabled();
  await relay.publish({
    ...navigationState,
    answers: navigationState.answers.slice(0, 1),
    selectedID: "a",
  });
  await expect(page.locator(".position")).toHaveText("1 / 1");
  await expect(
    page.getByRole("button", { name: "Previous answer" })
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Next answer" })
  ).toBeDisabled();
});

for (const replaced of ["reader", "publisher"] as const) {
  test(`a delayed phone request cannot cross a ${replaced} replacement`, async ({
    page,
    relay,
  }) => {
    await page.addInitScript(() => {
      const original = crypto.subtle.encrypt.bind(crypto.subtle);
      let hold = false;
      const gate = Promise.withResolvers<boolean>();
      window.addEventListener("hold-selection", () => {
        hold = true;
      });
      window.addEventListener("release-selection", () => {
        gate.resolve(true);
      });
      crypto.subtle.encrypt = async (...args) => {
        const encrypted = await original(...args);
        if (hold) {
          hold = false;
          document.documentElement.dataset["heldSelection"] = "true";
          await gate.promise;
          document.documentElement.dataset["releasedSelection"] = "true";
        }
        return encrypted;
      };
    });
    const sockets: WebSocketRoute[] = [];
    const sent: string[] = [];
    await page.routeWebSocket("**/rooms/*/socket", (socket) => {
      sockets.push(socket);
      const server = socket.connectToServer();
      socket.onMessage((message) => {
        if (String(message).includes('"type":"select"')) {
          sent.push(String(message));
        }
        server.send(message);
      });
    });
    await relay.publish(navigationState);
    await page.goto(await relay.viewerURL());
    await relay.writer.next("ack");
    await page.evaluate(() =>
      window.dispatchEvent(new Event("hold-selection"))
    );
    await page.getByRole("button", { name: "Previous answer" }).click();
    await expect
      .poll(
        async () =>
          await page.evaluate(
            () => document.documentElement.dataset["heldSelection"]
          )
      )
      .toBe("true");
    if (replaced === "reader") {
      const [socket] = sockets;
      if (!socket) {
        throw new Error("No viewer socket");
      }
      await socket.close({ code: 1001 });
      await expect.poll(() => sockets.length).toBe(2);
    } else {
      const replacement = await relay.connect("writer");
      await relay.publish(navigationState, replacement.peer);
    }
    await expect(page.locator(".position")).toHaveText("3 / 3");
    await page.evaluate(() =>
      window.dispatchEvent(new Event("release-selection"))
    );
    await expect
      .poll(
        async () =>
          await page.evaluate(
            () => document.documentElement.dataset["releasedSelection"]
          )
      )
      .toBe("true");
    await page.evaluate(async () => {
      const frame = Promise.withResolvers<boolean>();
      requestAnimationFrame(() => {
        frame.resolve(true);
      });
      await frame.promise;
    });
    expect(sent).toEqual([]);
    await page.getByRole("button", { name: "Previous answer" }).click();
    await expect.poll(() => sent.length).toBe(1);
  });
}

test("a final delayed snapshot updates content without undoing navigation after session end", async ({
  page,
  relay,
}) => {
  await page.addInitScript(() => {
    const original = crypto.subtle.decrypt.bind(crypto.subtle);
    let hold = false;
    const gate = Promise.withResolvers<boolean>();
    window.addEventListener("hold-final", () => {
      hold = true;
    });
    window.addEventListener("release-final", () => {
      gate.resolve(true);
    });
    crypto.subtle.decrypt = async (...args) => {
      const decrypted = await original(...args);
      if (hold) {
        hold = false;
        document.documentElement.dataset["heldFinal"] = "true";
        await gate.promise;
      }
      return decrypted;
    };
  });
  await relay.publish(navigationState);
  await page.goto(await relay.viewerURL());
  await expect(page.locator(".position")).toHaveText("3 / 3");
  await page.evaluate(() => window.dispatchEvent(new Event("hold-final")));
  await relay.publish({
    ...navigationState,
    answers: navigationState.answers.map((answer) =>
      answer.id === "a"
        ? { ...answer, text: `${answer.text}\n\nFinal detail.` }
        : answer
    ),
    selectedID: "b",
    selection: 4,
  });
  await expect
    .poll(
      async () =>
        await page.evaluate(() => document.documentElement.dataset["heldFinal"])
    )
    .toBe("true");
  await relay.end();
  await expect(page.getByRole("status")).toHaveText("Session ended");
  await page.getByRole("button", { name: "Previous answer" }).click();
  await page.getByRole("button", { name: "Previous answer" }).click();
  await page.evaluate(() => window.dispatchEvent(new Event("release-final")));
  await expect(page.locator("article")).toContainText("Final detail.");
  await expect(page.locator(".position")).toHaveText("1 / 3");
});

async function position(pane: Locator) {
  return await pane.evaluate((element) => element.scrollTop);
}
async function visibleAnchor(pane: Locator) {
  return await pane.evaluate((element) => {
    const { top } = element.getBoundingClientRect();
    const nodes = [...element.querySelectorAll<HTMLElement>("[data-anchor]")];
    const visible = nodes.filter(
      (node) =>
        node.getBoundingClientRect().bottom > top + 1 &&
        node.getBoundingClientRect().top < top + element.clientHeight
    );
    const anchor = visible.find(
      (parent) =>
        !visible.some((child) => child !== parent && parent.contains(child))
    );
    return anchor
      ? {
          id: anchor.dataset["anchor"],
          offset: anchor.getBoundingClientRect().top - top,
        }
      : undefined;
  });
}

test("the welcome screen and malformed links have clear outcomes", async ({
  page,
}) => {
  const response = await page.goto("/");
  expect(response?.status()).toBe(200);
  const headers = response?.headers();
  expect(headers?.["referrer-policy"]).toBe("no-referrer");
  expect(headers?.["x-content-type-options"]).toBe("nosniff");
  expect(headers?.["content-security-policy"]).toBe(
    "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
  );
  await expect(
    page.getByRole("heading", { name: "Skill Issue" })
  ).toBeVisible();
  await expect(
    page.getByText(
      "Open the private viewer link from your Mac, or scan its QR code."
    )
  ).toBeVisible();
  await page.goto("/#broken");
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(
    page.getByRole("heading", { name: "Couldn't open this viewer." })
  ).toBeVisible();
  await expect(page.getByText("Settings", { exact: false })).toHaveCount(0);
  await expect(page.locator(".position")).toHaveText("No answers yet");
});

test("empty viewers distinguish connection, Mac readiness and a known Mac error", async ({
  page,
  relay,
}) => {
  const pending: string[] = [];
  let release: (() => void) | undefined;
  let holding = true;
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    const server = socket.connectToServer();
    server.onMessage((message) => {
      if (holding) {
        pending.push(String(message));
      } else {
        socket.send(message);
      }
    });
    release = () => {
      holding = false;
      for (const message of pending) {
        socket.send(message);
      }
    };
  });
  await relay.publish(empty);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(page.getByRole("status")).toHaveText("Connecting…");
  await expect(
    pane.getByRole("heading", { name: "Connecting…" })
  ).toBeVisible();
  await expect(pane).toContainText("Waiting for the viewer connection.");
  await expect(pane).not.toContainText("Settings");
  await expect(pane).not.toContainText("Space");
  await expect(page.locator(".position")).toHaveText("No answers yet");
  await page.setViewportSize({ height: 568, width: 320 });
  await page.evaluate(() => {
    document.documentElement.style.fontSize = "32px";
  });
  await expect
    .poll(
      async () =>
        await page.evaluate(() => document.documentElement.scrollWidth)
    )
    .toBe(320);
  await expect
    .poll(
      async () =>
        await page
          .getByRole("status")
          .evaluate(
            (element) => element.getBoundingClientRect().right <= innerWidth
          )
    )
    .toBe(true);
  await expect.poll(() => pending.length).toBe(2);
  if (!release) {
    throw new Error("The viewer did not open its WebSocket");
  }
  release();
  await expect(page.getByRole("status")).toHaveText("Connected");
  await expect(
    pane.getByRole("heading", { name: "Waiting for your Mac." })
  ).toBeVisible();
  await expect(pane).toContainText(
    "Your viewer will update when your Mac is ready."
  );
  await expect(pane).not.toContainText("Settings");

  await relay.publish({ ...empty, live: true });
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(pane).not.toContainText("Settings");
  await expect(pane).not.toContainText("Space");
  await relay.publish({
    ...empty,
    error: "Private authentication diagnostic",
    live: true,
  });
  await expect(
    pane.getByRole("heading", { name: "Check your Mac to continue." })
  ).toBeVisible();
  await expect(pane).toContainText(
    "Open Settings in Skill Issue for the error and next steps."
  );
  await expect(pane).not.toContainText("Private authentication diagnostic");

  await relay.publish({ ...empty, canAnswer: true, live: true });
  await expect(
    pane.getByRole("heading", { name: "Press Space to request an answer." })
  ).toBeVisible();
  await expect(pane.getByRole("alert")).toHaveCount(0);
  await relay.writer.close();
  await expect(page.getByRole("status")).toHaveText("Mac disconnected");
  await expect(
    pane.getByRole("heading", { name: "Mac disconnected." })
  ).toBeVisible();
  await expect(pane).toContainText("The viewer will reconnect automatically.");
  await expect(pane).not.toContainText("Settings");
  await expect(pane).not.toContainText("Space");
  await relay.end();
  await expect(page.getByRole("status")).toHaveText("Session ended");
  await expect(
    pane.getByRole("heading", { name: "Session ended." })
  ).toBeVisible();
  await expect(pane).toContainText(
    "Start a new session on your Mac and open its viewer link."
  );
});

test("rejected initial reader credentials stop retrying and a valid link can recover", async ({
  page,
  relay,
}) => {
  let attempts = 0;
  let rejections = 0;
  page.on("websocket", (socket) => {
    attempts += 1;
    socket.on("socketerror", () => {
      rejections += 1;
    });
  });
  await relay.publish({ ...empty, canAnswer: true, live: true });
  const valid = await relay.viewerURL();
  const rejected = new URL(valid);
  const fragment = rejected.hash.split(".");
  fragment[1] = `${relay.room.reader.startsWith("A") ? "B" : "A"}${relay.room.reader.slice(1)}`;
  rejected.hash = fragment.join(".");
  await page.clock.install();
  // Use the actual Worker's HTTP rejection, not a simulated policy close.
  await page.goto(rejected.href);
  await expect.poll(() => rejections).toBeGreaterThan(0);
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  await page.clock.fastForward(40_000);
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(
    page.getByRole("heading", { name: "Couldn't open this viewer." })
  ).toBeVisible();
  await expect(
    page.getByText(
      "Reload this viewer, or reopen it from Skill Issue on your Mac."
    )
  ).toBeVisible();
  const stopped = attempts;
  await page.clock.fastForward(60_000);
  expect(attempts).toBe(stopped);
  await page.clock.resume();
  await page.goto(valid);
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.locator("footer")).toContainText("request answer");
});

test("a lost established connection stops retrying a retired room without losing the answer", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let attempts = 0;
  let rejections = 0;
  page.on("websocket", (socket) => {
    attempts += 1;
    socket.on("socketerror", () => {
      rejections += 1;
    });
  });
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    socket.connectToServer();
  });
  const text = Array.from(
    { length: 60 },
    (_, index) => `Paragraph ${index}. Keep reading the retained answer.`
  ).join("\n\n");
  const state: ViewState = {
    ...empty,
    answers: [{ id: "a", language: "English", status: "complete", text }],
    canAnswer: true,
    live: true,
    selectedID: "a",
  };
  await relay.publish(state);
  await page.clock.install();
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  await page.clock.fastForward(20_000);
  const heartbeat = await relay.publish(state);
  await expect
    .poll(async () => {
      const ack = await relay.writer.next("ack");
      return ack.seq;
    })
    .toBe(heartbeat.seq);
  await page.clock.fastForward(20_000);
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await pane.evaluate((element) => {
    element.scrollTop = 400;
  });
  const before = await position(pane);
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not establish its initial connection");
  }
  // Disconnect before deletion so the viewer cannot receive the ended message.
  await first.close({ code: 1001, reason: "Missed room retirement" });
  await relay.end();
  await page.clock.runFor(2000);
  await expect.poll(() => rejections).toBeGreaterThan(0);
  await page.clock.fastForward(20_000);
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  await page.clock.fastForward(20_000);
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(page.getByRole("alert")).toContainText(
    "Reload this viewer, or reopen it from Skill Issue on your Mac."
  );
  await expect(pane.locator("article")).toContainText("Paragraph 40");
  await expect.poll(async () => await position(pane)).toBeCloseTo(before, 0);
  await expect(page.locator("footer")).toHaveCount(0);
  const stopped = attempts;
  await page.clock.fastForward(60_000);
  expect(attempts).toBe(stopped);
});

test("a transient initial connection can establish before its deadline and remain connected beyond it", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let allowReconnect = false;
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length === 1) {
      socket.connectToServer().onMessage(() => {});
    } else if (allowReconnect) {
      socket.connectToServer();
    }
  });
  await relay.publish({ ...empty, live: true });
  await page.clock.install();
  await page.goto(await relay.viewerURL());
  await expect.poll(() => sockets.length).toBe(1);
  await expect(page.getByRole("status")).toHaveText("Connecting…");
  await page.clock.fastForward(20_000);
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not open its initial connection");
  }
  await first.close({ code: 1001, reason: "Transient initial interruption" });
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  allowReconnect = true;
  for (const socket of sockets.slice(1)) {
    socket.connectToServer();
  }
  await page.clock.runFor(2000);
  await expect.poll(() => sockets.length).toBe(2);
  await expect(page.getByRole("status")).toHaveText("Listening");
  await page.clock.fastForward(20_000);
  await expect(page.getByRole("status")).toHaveText("Listening");
  expect(sockets.length).toBe(2);
});

for (const deniedStatus of [302, 401, 403]) {
  test(`Cloudflare Access HTTP ${deniedStatus} preserves the answer and offers sign-in without leaking the viewer link`, async ({
    page,
    relay,
  }) => {
    let denied = false;
    const sockets: WebSocketRoute[] = [];
    const probes: string[] = [];
    await page.route("**/", async (route) => {
      const request = route.request();
      if (request.resourceType() === "fetch") {
        probes.push(request.url());
        expect(request.headers()["referer"]).toBeUndefined();
        expect(request.headers()["cookie"]).toContain(
          "CF_Authorization=fixture-access-cookie"
        );
        await route.fulfill({
          headers:
            deniedStatus === 302
              ? { Location: "https://access.example.invalid/login" }
              : {},
          status: deniedStatus,
        });
      } else {
        await route.continue();
      }
    });
    await page.routeWebSocket("**/rooms/*/socket", (socket) => {
      sockets.push(socket);
      if (denied) {
        void socket.close({ code: 1001, reason: "Access requires sign-in" });
      } else {
        socket.connectToServer();
      }
    });
    const text = Array.from(
      { length: 60 },
      (_, index) => `Paragraph ${index}. Keep reading during sign-in.`
    ).join("\n\n");
    await relay.publish({
      ...empty,
      answers: [{ id: "a", language: "English", status: "complete", text }],
      canAnswer: true,
      live: true,
      selectedID: "a",
    });
    const url = await relay.viewerURL();
    await page.context().addCookies([
      {
        name: "CF_Authorization",
        url: new URL(url).origin,
        value: "fixture-access-cookie",
      },
    ]);
    await page.goto(url);
    await expect(page.getByRole("status")).toHaveText("Listening");
    const pane = page.getByRole("region", { exact: true, name: "Answer" });
    await pane.evaluate((element) => {
      element.scrollTop = 700;
      element.dispatchEvent(new Event("scroll"));
    });
    const before = await position(pane);
    const [first] = sockets;
    if (!first) {
      throw new Error("The viewer did not establish its initial connection");
    }
    denied = true;
    await first.close({ code: 1001, reason: "Access cookie expired" });
    await expect(page.getByRole("status")).toHaveText("Sign in required");
    await expect(page.getByRole("alert")).toContainText(
      "Sign in with an account allowed to open this viewer."
    );
    const action = page.getByRole("link", { exact: true, name: "Sign in" });
    await expect(action).toHaveAttribute("href", url);
    await expect(pane.locator("article")).toContainText("Paragraph 40");
    await expect.poll(async () => await position(pane)).toBeCloseTo(before, 0);
    await expect(page.locator("footer")).toHaveCount(0);
    expect(probes).toEqual([`${new URL(url).origin}/`]);
    expect(probes.join(" ")).not.toContain(relay.room.reader);
    expect(probes.join(" ")).not.toContain(new URL(url).hash);
    const count = sockets.length;
    await page.clock.install();
    await page.clock.fastForward(60_000);
    expect(sockets.length).toBe(count);
    await page.clock.resume();

    // A plain click must request the document, not just navigate to its fragment.
    let navigations = 0;
    page.on("request", (request) => {
      if (request.isNavigationRequest()) {
        navigations += 1;
      }
    });
    denied = false;
    await action.focus();
    await expect(action).toBeFocused();
    await expect(action).toHaveCSS("outline-style", "solid");
    await page.keyboard.press("Enter");
    await expect(page.getByRole("status")).toHaveText("Listening");
    expect(navigations).toBe(1);
    expect(page.url()).toBe(url);
    await expect.poll(async () => await position(pane)).toBeCloseTo(before, 0);
  });
}

for (const viewport of [
  { height: 844, textSize: 16, width: 390 },
  { height: 390, textSize: 16, width: 844 },
  { height: 800, textSize: 16, width: 1280 },
  { height: 568, textSize: 32, width: 320 },
]) {
  for (const access of [false, true]) {
    test(`${access ? "Access" : "Transport"} error keeps clearance and the visible reading anchor at ${viewport.width}px with ${viewport.textSize / 16}x text`, async ({
      page,
      relay,
    }) => {
      await page.setViewportSize(viewport);
      await page.route("**/", async (route) => {
        await (route.request().resourceType() === "fetch"
          ? route.fulfill({ status: 403 })
          : route.continue());
      });
      const sockets: WebSocketRoute[] = [];
      await page.routeWebSocket("**/rooms/*/socket", (socket) => {
        sockets.push(socket);
        socket.connectToServer();
      });
      await relay.publish({
        ...empty,
        answers: [
          {
            id: "a",
            language: "English",
            status: "incomplete",
            text: Array.from(
              { length: 100 },
              (_, index) =>
                `Paragraph ${index}. This answer stays readable after the viewer connection stops.`
            ).join("\n\n"),
          },
        ],
        canAnswer: true,
        live: true,
        selectedID: "a",
      });
      await page.goto(await relay.viewerURL());
      await expect(page.getByRole("status")).toHaveText("Listening");
      await page.evaluate((size) => {
        document.documentElement.style.fontSize = `${size}px`;
      }, viewport.textSize);
      const pane = page.getByRole("region", { exact: true, name: "Answer" });
      await pane.evaluate((element) => {
        element.scrollTop = 700;
        element.dispatchEvent(new Event("scroll"));
      });
      const before = await visibleAnchor(pane);
      if (!before) {
        throw new Error("The answer has no visible reading anchor");
      }
      const [socket] = sockets;
      if (!socket) {
        throw new Error("The viewer did not establish its initial connection");
      }
      await socket.close({
        code: access ? 1001 : 1008,
        reason: "Viewer connection stopped",
      });
      await expect(page.getByRole("status")).toHaveText(
        access ? "Sign in required" : failure
      );
      const notice = page.getByRole("alert");
      await expect(notice).toBeVisible();
      const clearance = async () => {
        const noticeBox = await notice.boundingBox();
        const paneBox = await pane.boundingBox();
        if (!noticeBox || !paneBox) {
          throw new Error("The error or reading viewport is not visible");
        }
        return paneBox.y - (noticeBox.y + noticeBox.height);
      };
      expect(await clearance()).toBeGreaterThanOrEqual(12);
      expect(
        await pane.evaluate((element) => element.clientHeight)
      ).toBeGreaterThan(100);
      await expect
        .poll(async () => {
          const anchor = await visibleAnchor(pane);
          return anchor?.id;
        })
        .toBe(before.id);
      const after = await visibleAnchor(pane);
      expect(after?.offset).toBeCloseTo(before.offset, 1);
      await pane.evaluate((element) => {
        element.scrollTop += 200;
        element.dispatchEvent(new Event("scroll"));
      });
      expect(await clearance()).toBeGreaterThanOrEqual(12);
      expect(
        await page.evaluate(() => document.documentElement.scrollWidth)
      ).toBe(viewport.width);
      await expect(
        pane.getByText("Incomplete answer", { exact: true })
      ).toHaveCount(1);
      await expect(notice).not.toContainText("Incomplete answer");
      await expect(page.getByRole("link", { name: "Sign in" })).toHaveCount(
        access ? 1 : 0
      );
    });
  }
}

test("explicit Access sign-in restores the private fragment when login returns without it", async ({
  page,
  relay,
}) => {
  let denied = false;
  let login = false;
  const sockets: WebSocketRoute[] = [];
  const navigations: string[] = [];
  page.on("request", (request) => {
    if (request.isNavigationRequest()) {
      navigations.push(request.url());
    }
  });
  await page.route("**/", async (route) => {
    const request = route.request();
    if (request.resourceType() === "fetch" && denied) {
      await route.fulfill({ status: 403 });
    } else if (request.isNavigationRequest() && login) {
      login = false;
      await route.fulfill({
        body: '<!doctype html><script>location.replace("/")</script>',
        contentType: "text/html",
      });
    } else {
      await route.continue();
    }
  });
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    socket.connectToServer();
  });
  const text = Array.from(
    { length: 60 },
    (_, index) => `Paragraph ${index}. Retain this encrypted answer.`
  ).join("\n\n");
  await relay.publish({
    ...empty,
    answers: [{ id: "saved", language: "English", status: "complete", text }],
    live: true,
    selectedID: "saved",
  });
  const url = await relay.viewerURL();
  await page.goto(url);
  await expect(page.getByRole("status")).toHaveText("Listening");
  expect(
    await page.evaluate(() => sessionStorage.getItem("skill-issue:access-link"))
  ).toBeNull();
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await pane.evaluate((element) => {
    element.scrollTop = 700;
    element.dispatchEvent(new Event("scroll"));
  });
  const before = await position(pane);
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not establish its initial connection");
  }
  denied = true;
  await first.close({ code: 1001, reason: "Access cookie expired" });
  await expect(page.getByRole("status")).toHaveText("Sign in required");
  denied = false;
  login = true;
  await page.getByRole("link", { exact: true, name: "Sign in" }).click();
  await expect(page.getByRole("status")).toHaveText("Listening");
  expect(page.url()).toBe(url);
  await expect(pane.locator("article")).toContainText("Paragraph 40");
  await expect.poll(async () => await position(pane)).toBeCloseTo(before, 0);
  expect(
    await page.evaluate(() => sessionStorage.getItem("skill-issue:access-link"))
  ).toBeNull();
  expect(navigations).toEqual(
    Array.from({ length: 3 }, () => `${new URL(url).origin}/`)
  );
});

test("pending Access sign-in never overrides a fresh viewer link and malformed fragments are consumed", async ({
  page,
  relay,
}) => {
  const url = await relay.viewerURL();
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "fresh",
        language: "English",
        status: "complete",
        text: "The fresh session.",
      },
    ],
    live: true,
    selectedID: "fresh",
  });
  await page.goto("/");
  const old = `#${crypto.randomUUID()}.${"A".repeat(43)}.${"B".repeat(43)}`;
  await page.evaluate((fragment) => {
    sessionStorage.setItem("skill-issue:access-link", fragment);
  }, old);
  await page.goto(url);
  // Same-origin fragment navigation does not remount the app. Exercise the
  // document load that follows an Access login as well.
  await page.reload();
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.locator("article")).toContainText("The fresh session.");
  expect(page.url()).toBe(url);
  expect(
    await page.evaluate(() => sessionStorage.getItem("skill-issue:access-link"))
  ).toBeNull();
  let sockets = 0;
  page.on("websocket", () => {
    sockets += 1;
  });
  await page.evaluate(() => {
    sessionStorage.setItem("skill-issue:access-link", "#broken");
  });
  await page.goto("/");
  await page.reload();
  await expect(
    page.getByRole("heading", { exact: true, name: "Skill Issue" })
  ).toBeVisible();
  expect(new URL(page.url()).hash).toBe("");
  expect(sockets).toBe(0);
  expect(
    await page.evaluate(() => sessionStorage.getItem("skill-issue:access-link"))
  ).toBeNull();
});

test("Access sign-in without browser storage falls back to reopening the original viewer link", async ({
  page,
  relay,
}) => {
  let denied = false;
  let login = false;
  const sockets: WebSocketRoute[] = [];
  const errors: Error[] = [];
  page.on("pageerror", (error) => errors.push(error));
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => {
      throw new DOMException("Browser storage is blocked", "SecurityError");
    };
  });
  await page.route("**/", async (route) => {
    if (route.request().resourceType() === "fetch" && denied) {
      await route.fulfill({ status: 403 });
    } else if (route.request().isNavigationRequest() && login) {
      login = false;
      await route.fulfill({
        body: '<!doctype html><script>location.replace("/")</script>',
        contentType: "text/html",
      });
    } else {
      await route.continue();
    }
  });
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    socket.connectToServer();
  });
  await relay.publish({ ...empty, live: true });
  const url = await relay.viewerURL();
  await page.goto(url);
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not establish its initial connection");
  }
  denied = true;
  await first.close({ code: 1001, reason: "Access cookie expired" });
  await expect(page.getByRole("status")).toHaveText("Sign in required");
  denied = false;
  login = true;
  await page.getByRole("link", { exact: true, name: "Sign in" }).click();
  await expect(
    page.getByRole("heading", { exact: true, name: "Skill Issue" })
  ).toBeVisible();
  await expect(
    page.getByText("Open the private viewer link", { exact: false })
  ).toBeVisible();
  expect(errors).toEqual([]);
  await page.goto(url);
  await expect(page.getByRole("status")).toHaveText("Listening");
  expect(errors).toEqual([]);
});

test("Access sign-in before the first snapshot has a usable empty state at 320px and 200% text", async ({
  page,
  relay,
}) => {
  await page.route("**/", async (route) => {
    await (route.request().resourceType() === "fetch"
      ? route.fulfill({ status: 403 })
      : route.continue());
  });
  await page.routeWebSocket("**/rooms/*/socket", async (socket) => {
    await socket.close({ code: 1001, reason: "Access requires sign-in" });
  });
  const url = await relay.viewerURL();
  await page.goto(url);
  await expect(page.getByRole("status")).toHaveText("Sign in required");
  await expect(page.getByRole("alert")).toContainText(
    "Sign in with an account allowed to open this viewer."
  );
  await expect(
    page.getByText("Sign in with an account allowed to open this viewer.", {
      exact: false,
    })
  ).toHaveCount(1);
  await expect(page.getByRole("heading")).toHaveCount(0);
  await expect(
    page.getByRole("region", { exact: true, name: "Answer" })
  ).toHaveText("");
  const action = page.getByRole("link", { exact: true, name: "Sign in" });
  await expect(action).toHaveCount(1);
  await expect(action).toHaveAttribute("href", url);
  await page.setViewportSize({ height: 568, width: 320 });
  await page.evaluate(() => {
    document.documentElement.style.fontSize = "32px";
  });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    320
  );
  const actionBox = await action.boundingBox();
  if (!actionBox) {
    throw new Error("The sign-in action is not visible");
  }
  expect(actionBox.height).toBeGreaterThanOrEqual(24);
  expect(actionBox.width).toBeGreaterThanOrEqual(24);
  expect(actionBox.y + actionBox.height).toBeLessThan(568);
  await page.keyboard.press("Tab");
  await expect(action).toBeFocused();
  await expect(action).toHaveCSS("outline-style", "solid");
  expect(relay.writer.socket.readyState).toBe(WebSocket.OPEN);
});

test("temporary probe failures do not turn a transport interruption into an Access error", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let probeCount = 0;
  let resume = false;
  await page.route("**/", async (route) => {
    if (route.request().resourceType() !== "fetch") {
      await route.continue();
      return;
    }
    probeCount += 1;
    await (probeCount === 1
      ? route.abort("internetdisconnected")
      : route.fulfill({ status: 503 }));
  });
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length === 1 || resume) {
      socket.connectToServer();
    } else {
      void socket.close({ code: 1001, reason: "Temporary interruption" });
    }
  });
  await relay.publish({ ...empty, live: true });
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not establish its initial connection");
  }
  await first.close({ code: 1001, reason: "Temporary interruption" });
  await expect.poll(() => probeCount).toBeGreaterThanOrEqual(2);
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  await expect(page.getByRole("link", { name: "Sign in" })).toHaveCount(0);
  resume = true;
  await expect(page.getByRole("status")).toHaveText("Listening");
});

test("a slow Access denial survives repeated rejected WebSocket upgrades", async ({
  page,
  relay,
}) => {
  let rejections = 0;
  const probes: (() => Promise<void>)[] = [];
  page.on("websocket", (socket) => {
    socket.on("socketerror", () => {
      rejections += 1;
    });
  });
  await page.route("**/", async (route) => {
    if (route.request().resourceType() !== "fetch") {
      await route.continue();
      return;
    }
    probes.push(async () => {
      await route.fulfill({ status: 403 }).catch(() => {
        /* The test observes whether a reconnect cancelled this response. */
      });
    });
  });
  const url = new URL(await relay.viewerURL());
  const fragment = url.hash.split(".");
  fragment[1] = `${relay.room.reader.startsWith("A") ? "B" : "A"}${relay.room.reader.slice(1)}`;
  url.hash = fragment.join(".");
  await page.goto(url.href);
  await expect.poll(() => probes.length).toBeGreaterThan(0);
  // Actual HTTP upgrade rejections never emit open, unlike a mocked socket close.
  await expect.poll(() => rejections).toBeGreaterThanOrEqual(2);
  const [denied] = probes;
  if (!denied) {
    throw new Error("The viewer did not check deployment access");
  }
  await denied();
  await expect(page.getByRole("status")).toHaveText("Sign in required");
  await expect(page.getByRole("link", { name: "Sign in" })).toBeVisible();
  expect(probes).toHaveLength(1);
});

test("a stale Access probe cannot replace a restored connection or a new viewer link", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  const probes: (() => Promise<void>)[] = [];
  await page.route("**/", async (route) => {
    if (route.request().resourceType() !== "fetch") {
      await route.continue();
      return;
    }
    probes.push(async () => {
      await route.fulfill({ status: 403 }).catch(() => {
        /* The restored connection may already have aborted this request. */
      });
    });
  });
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    socket.connectToServer();
  });
  await relay.publish({ ...empty, canAnswer: true, live: true });
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not establish its initial connection");
  }
  await first.close({ code: 1001, reason: "Temporary interruption" });
  await expect.poll(() => probes.length).toBe(1);
  await expect.poll(() => sockets.length).toBe(2);
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [firstProbe] = probes;
  if (!firstProbe) {
    throw new Error("The connection did not check deployment access");
  }
  await firstProbe();
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [, second] = sockets;
  if (!second) {
    throw new Error("The viewer did not restore its connection");
  }
  await second.close({ code: 1001, reason: "Another temporary interruption" });
  await expect.poll(() => probes.length).toBe(2);
  await page.evaluate(() => {
    location.hash = "broken";
  });
  await expect(page.getByRole("status")).toHaveText(failure);
  const [, secondProbe] = probes;
  if (!secondProbe) {
    throw new Error("The second interruption did not check deployment access");
  }
  await secondProbe();
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(page.getByRole("link", { name: "Sign in" })).toHaveCount(0);
});

test("generation and language follow each request while older answers remain readable", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let allowReconnect = false;
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length === 1 || allowReconnect) {
      socket.connectToServer();
    }
  });
  const older: AnswerCard = {
    id: "older",
    language: "English",
    status: "complete",
    text: `# Previous answer\n\n${Array.from(
      { length: 60 },
      (_, index) =>
        `Paragraph ${index}. Read this while the next answer arrives.`
    ).join("\n\n")}`,
  };
  const state: ViewState = {
    ...empty,
    answers: [older],
    canAnswer: true,
    live: true,
    selectedID: "older",
    selection: 1,
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(pane.locator("article")).toHaveAttribute("lang", "en");
  await pane.evaluate((element) => {
    element.scrollTop = 1400;
    element.dispatchEvent(new Event("scroll"));
  });
  const anchor = await visibleAnchor(pane);
  if (!anchor) {
    throw new Error("The previous answer has no visible reading anchor");
  }
  const next: AnswerCard = {
    id: "next",
    language: "Russian",
    status: "generating",
    text: "",
  };
  const generating: ViewState = { ...state, answers: [older, next] };
  await relay.publish(generating);
  await expect(page.getByRole("status")).toHaveText("Thinking…");
  await expect(page.locator(".position")).toHaveText("1 / 2");
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await expect(pane.locator("article")).toContainText("Previous answer");
  await expect(pane.locator("article")).toHaveAttribute("lang", "en");
  expect(await visibleAnchor(pane)).toEqual(anchor);

  await relay.publish({
    ...generating,
    answers: [older, { ...next, status: "complete", text: "A new answer" }],
  });
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(pane.locator("article")).toContainText("Previous answer");
  await expect(pane.locator("article")).toHaveAttribute("lang", "en");
  expect(await visibleAnchor(pane)).toEqual(anchor);

  await relay.publish({ ...generating, selectedID: "next", selection: 2 });
  await expect(page.getByRole("status")).toHaveText("Thinking…");
  await expect(
    pane.getByRole("heading", { name: "Preparing your answer…" })
  ).toBeVisible();
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "true");
  await expect(pane.locator("article")).toHaveAttribute("lang", "ru");
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not open its WebSocket");
  }
  await first.close({ code: 1001, reason: "Reconnect during generation" });
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  await expect(
    pane.getByRole("heading", { name: "Reconnecting…" })
  ).toBeVisible();
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await expect(pane).not.toContainText("Preparing");
  allowReconnect = true;
  for (const socket of sockets.slice(1)) {
    socket.connectToServer();
  }
  await expect(page.getByRole("status")).toHaveText("Thinking…");
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "true");
  await expect(pane.locator("article")).toHaveAttribute("lang", "ru");
  await relay.writer.close();
  await expect(page.getByRole("status")).toHaveText("Mac disconnected");
  await expect(
    pane.getByRole("heading", { name: "Mac disconnected." })
  ).toBeVisible();
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await expect(pane).not.toContainText("Preparing");
  await expect(page.locator("footer")).not.toContainText("request answer");
  await relay.end();
  await expect(page.getByRole("status")).toHaveText("Session ended");
  await expect(
    pane.getByRole("heading", { name: "Session ended." })
  ).toBeVisible();
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await expect(pane.locator("article")).toHaveAttribute("lang", "ru");
  await page.getByRole("button", { name: "Previous answer" }).click();
  await expect(pane.locator("article")).toContainText("Previous answer");
  await expect(pane.locator("article")).toHaveAttribute("lang", "en");
});

test("encrypted answers render Markdown safely and expose session status", async ({
  page,
  relay,
}) => {
  const errors: Error[] = [];
  page.on("pageerror", (error) => errors.push(error));
  const answer: AnswerCard = {
    id: "answer",
    language: "English",
    status: "generating",
    text: "# A useful answer\n\n- Outer point\n  - Nested point\n\n```python\ndef lookup(values):\n    return values['key']\n```\n\n[Documentation](https://example.com)\n\n<script>window.injected = true</script>",
  };
  const state: ViewState = {
    ...empty,
    answers: [answer],
    live: true,
    selectedID: "answer",
    selection: 1,
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(
    pane.getByRole("heading", { name: "A useful answer" })
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Thinking…");
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "true");
  await expect(pane.locator("li li")).toHaveText("Nested point");
  await expect(pane.locator("pre code")).toHaveText(
    "def lookup(values):\n    return values['key']\n"
  );
  await expect(
    pane.getByRole("link", { name: "Documentation" })
  ).toHaveAttribute("rel", "noreferrer noopener");
  expect(await page.evaluate(() => "injected" in window)).toBe(false);
  const heading = await pane
    .getByRole("heading", { name: "A useful answer" })
    .elementHandle();
  const code = await pane.locator("pre code").elementHandle();
  await expect(pane.locator("h1")).toHaveAttribute("data-anchor", "h1.0");
  const codeAnchor = `code.${answer.text.indexOf("```python")}.0`;
  await expect(pane.locator("pre code span").first()).toHaveAttribute(
    "data-anchor",
    codeAnchor
  );
  await relay.publish({
    ...state,
    answers: [
      {
        ...answer,
        status: "complete",
        text: `${answer.text}\n\nA streamed conclusion.`,
      },
    ],
  });
  await expect(pane.getByText("A streamed conclusion.")).toBeVisible();
  expect(await heading.evaluate((node) => node.isConnected)).toBe(true);
  expect(await code.evaluate((node) => node.isConnected)).toBe(true);
  await expect(pane.locator("h1")).toHaveAttribute("data-anchor", "h1.0");
  await expect(pane.locator("pre code span").first()).toHaveAttribute(
    "data-anchor",
    codeAnchor
  );
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await relay.writer.close();
  await expect(page.getByRole("status")).toHaveText("Mac disconnected");
  await relay.end();
  await expect(page.getByRole("status")).toHaveText("Session ended");
  await expect(page.locator("footer")).toHaveCount(0);
  await expect(pane.getByText("A streamed conclusion.")).toBeVisible();
  expect(errors).toEqual([]);
});

for (const appearance of [
  { colorScheme: "light", width: 320 },
  { colorScheme: "dark", width: 1280 },
] as const) {
  test(`highlighted code wraps and preserves reading positions while streaming in ${appearance.colorScheme} mode at ${appearance.width}px`, async ({
    page,
    relay,
  }) => {
    const errors: Error[] = [];
    page.on("pageerror", (error) => errors.push(error));
    await page.setViewportSize({ height: 844, width: appearance.width });
    await page.emulateMedia({
      colorScheme: appearance.colorScheme,
      reducedMotion: "reduce",
    });
    const source = [
      "def describe():",
      `\tvalue = "<tag>&${"long_token".repeat(30)}"`,
      "\t# Keep the original whitespace and comments.",
      "",
      ...Array.from(
        { length: 60 },
        (_, index) => `\tvalue_${index} = ${index}`
      ),
    ].join("\n");
    const answer: AnswerCard = {
      id: "code",
      language: "English",
      status: "generating",
      text: `# Code answer\n\n\`\`\`python\n${source}`,
    };
    let state: ViewState = {
      ...empty,
      answers: [answer],
      live: true,
      selectedID: answer.id,
      selection: 1,
    };
    await relay.publish(state);
    await page.goto(await relay.viewerURL());
    const pane = page.getByRole("region", { exact: true, name: "Answer" });
    const code = pane.locator("pre code").first();
    await expect(code).toHaveText(source);
    expect(await code.textContent()).toBe(source);
    const keyword = code.locator(".token").filter({ hasText: /^def$/u });
    await expect(keyword).toBeVisible();
    expect(
      await keyword.evaluate((node) => getComputedStyle(node).color)
    ).not.toBe(await code.evaluate((node) => getComputedStyle(node).color));
    expect(await code.evaluate((node) => getComputedStyle(node).tabSize)).toBe(
      "4"
    );
    const initialCodeSize = await code.evaluate(
      (node) => getComputedStyle(node).fontSize
    );
    expect(
      await code.locator("[data-anchor]").evaluateAll((nodes) => {
        const ids = nodes.map((node) => node.dataset["anchor"]);
        return new Set(ids).size === ids.length;
      })
    ).toBe(true);
    expect(
      await code
        .locator("..")
        .evaluate((node) => node.scrollWidth <= node.clientWidth + 1)
    ).toBe(true);
    const lineID = `code.${answer.text.indexOf("```python")}.45`;
    const line = code.locator(`[data-anchor="${lineID}"]`);
    await line.scrollIntoViewIfNeeded();
    const before = await visibleAnchor(pane);
    if (!before) {
      throw new Error("The code has no visible reading anchor");
    }
    expect(before.id).toMatch(/^code\./u);
    const codeElement = await code.elementHandle();
    const completed = `${source}\n\treturn value`;
    const unsupported = "<script>window.codeInjected = true</script>\n  <&>";
    state = {
      ...state,
      answers: [
        {
          ...answer,
          status: "complete",
          text: `${answer.text}\n\treturn value\n\`\`\`\n\nInline \`a < b\`.\n\n\`\`\`not-a-language\n${unsupported}\n\`\`\`\n\n\`\`\`\nplain code\n\`\`\``,
        },
      ],
    };
    await relay.publish(state);
    await expect(code).toHaveText(completed);
    expect(await code.textContent()).toBe(completed);
    expect(await codeElement.evaluate((node) => node.isConnected)).toBe(true);
    expect(await visibleAnchor(pane)).toEqual(before);
    await expect(pane.locator("pre code").nth(1)).toHaveText(unsupported);
    await expect(pane.locator("pre code").nth(2)).toHaveText("plain code");
    await expect(pane.locator("p code")).toHaveText("a < b");
    await expect(pane.locator("p code [data-anchor]")).toHaveCount(0);
    await expect(pane.locator("script")).toHaveCount(0);
    expect(await page.evaluate(() => "codeInjected" in window)).toBe(false);
    state = { ...state, fontSize: 28 };
    await relay.publish(state);
    await expect(pane.locator("article")).toHaveCSS("font-size", "28px");
    expect(
      await code.evaluate((node) => getComputedStyle(node).fontSize)
    ).not.toBe(initialCodeSize);
    await expect
      .poll(async () => {
        const anchor = await visibleAnchor(pane);
        return anchor?.id;
      })
      .toBe(before.id);
    const resized = await visibleAnchor(pane);
    expect(Math.abs((resized?.offset ?? 0) - before.offset)).toBeLessThan(2);
    await relay.publish({
      ...state,
      answers: [
        ...state.answers,
        {
          id: "other",
          language: "English",
          status: "complete",
          text: "Another answer.",
        },
      ],
      selectedID: "other",
      selection: 2,
    });
    await expect(pane.getByText("Another answer.")).toBeVisible();
    await relay.publish({ ...state, selection: 3 });
    await expect(code).toHaveText(completed);
    await expect
      .poll(async () => {
        const anchor = await visibleAnchor(pane);
        return anchor?.id;
      })
      .toBe(before.id);
    expect(errors).toEqual([]);
  });
}

test("scrolling, history, reconnect and session switching preserve separate reading positions", async ({
  page,
  relay,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const sockets: WebSocketRoute[] = [];
  let allowReconnect = false;
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length === 1 || allowReconnect) {
      socket.connectToServer();
    }
  });
  const paragraphs = Array.from(
    { length: 60 },
    (_, index) =>
      `Paragraph ${index}. Use a hash map to look up the value efficiently.\n\n`
  ).join("");
  const firstAnswer: AnswerCard = {
    id: "first",
    language: "English",
    status: "generating",
    text: `# First answer\n\n${paragraphs}`,
  };
  const secondAnswer: AnswerCard = {
    id: "second",
    language: "English",
    status: "complete",
    text: "# Second answer\n\nUse a balanced tree.",
  };
  let state: ViewState = {
    ...empty,
    answers: [firstAnswer, secondAnswer],
    live: true,
    selectedID: "first",
    selection: 1,
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(
    pane.getByRole("heading", { name: "First answer" })
  ).toBeVisible();
  const height = await pane.evaluate((element) => element.clientHeight);
  state = { ...state, command: { answerID: "first", direction: 1, id: 1 } };
  await relay.publish(state);
  await expect
    .poll(async () => Math.abs((await position(pane)) - height / 2))
    .toBeLessThanOrEqual(1);
  const saved = await visibleAnchor(pane);
  if (!saved) {
    throw new Error("The scrolled answer has no visible reading anchor");
  }
  state = {
    ...state,
    answers: [
      {
        ...firstAnswer,
        status: "complete",
        text: `${firstAnswer.text}A newly streamed conclusion.`,
      },
      secondAnswer,
    ],
  };
  await relay.publish(state);
  await expect(page.getByRole("status")).toHaveText("Listening");
  expect(await visibleAnchor(pane)).toEqual(saved);
  state = { ...state, fontSize: 28 };
  await relay.publish(state);
  await expect(pane.locator("article")).toHaveCSS("font-size", "28px");
  await expect
    .poll(async () => {
      const anchor = await visibleAnchor(pane);
      return anchor?.id;
    })
    .toBe(saved.id);
  const resizedAnchor = await visibleAnchor(pane);
  if (!resizedAnchor) {
    throw new Error("The resized answer lost its reading anchor");
  }
  expect(Math.abs(resizedAnchor.offset - saved.offset)).toBeLessThan(2);
  const afterResize = await position(pane);
  state = { ...state, selectedID: "second", selection: 2 };
  await relay.publish(state);
  await expect(
    pane.getByRole("heading", { name: "Second answer" })
  ).toBeVisible();
  await expect.poll(async () => await position(pane)).toBe(0);
  await expect(page.locator(".position")).toHaveText("2 / 2");
  state = { ...state, selectedID: "first", selection: 3 };
  await relay.publish(state);
  await expect(page.locator(".position")).toHaveText("1 / 2");
  await expect
    .poll(async () => await position(pane))
    .toBeCloseTo(afterResize, 0);
  const [socket] = sockets;
  if (!socket) {
    throw new Error("The viewer did not open its WebSocket");
  }
  await socket.close({ code: 1001, reason: "Reconnect check" });
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  allowReconnect = true;
  for (const reconnected of sockets.slice(1)) {
    reconnected.connectToServer();
  }
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect
    .poll(async () => await position(pane))
    .toBeCloseTo(afterResize, 0);
  await page.reload();
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect
    .poll(async () => await position(pane))
    .toBeCloseTo(afterResize, 0);
  state = { ...state, command: { answerID: "first", direction: 1, id: 2 } };
  await relay.publish(state);
  await expect
    .poll(async () =>
      Math.abs((await position(pane)) - afterResize - height / 2)
    )
    .toBeLessThanOrEqual(1);
  const originalPosition = await position(pane);
  const originalURL = await relay.viewerURL();
  const originalMemory = `reading:${new URL(originalURL).hash.split(".")[0]}`;
  const originalCache = await page.evaluate(
    (key) => sessionStorage.getItem(key),
    originalMemory
  );
  expect(originalCache).not.toBeNull();
  const other = await RelaySession.create(relay.base, relay.clientIP);
  try {
    const otherURL = await other.viewerURL();
    const otherMemory = `reading:${new URL(otherURL).hash.split(".")[0]}`;
    let otherState: ViewState = {
      ...empty,
      answers: [
        {
          ...firstAnswer,
          status: "complete",
          text: firstAnswer.text.replace("First answer", "Other answer"),
        },
        {
          ...secondAnswer,
          text: "# New session choice\n\nThis belongs to the other room.",
        },
      ],
      command: { answerID: "first", direction: 1, id: 1 },
      fontSize: 28,
      live: true,
      selectedID: "second",
    };
    await other.publish(otherState);
    await page.evaluate((url) => {
      location.hash = new URL(url).hash;
    }, otherURL);
    await expect(
      pane.getByRole("heading", { name: "New session choice" })
    ).toBeVisible();
    await expect(page.getByRole("status")).toHaveText("Listening");
    await expect.poll(async () => await position(pane)).toBe(0);
    expect(
      await page.evaluate((key) => sessionStorage.getItem(key), originalMemory)
    ).toBe(originalCache);
    otherState = { ...otherState, selectedID: "first", selection: 1 };
    await other.publish(otherState);
    await expect(
      pane.getByRole("heading", { name: "Other answer" })
    ).toBeVisible();
    await expect.poll(async () => await position(pane)).toBe(0);
    otherState = {
      ...otherState,
      command: { answerID: "first", direction: 1, id: 2 },
    };
    await other.publish(otherState);
    await expect
      .poll(async () => Math.abs((await position(pane)) - height / 2))
      .toBeLessThanOrEqual(1);
    const otherPosition = await position(pane);
    const otherCache = await page.evaluate(
      (key) => sessionStorage.getItem(key),
      otherMemory
    );
    expect(otherCache).not.toBeNull();
    await page.evaluate((url) => {
      location.hash = new URL(url).hash;
    }, originalURL);
    await expect(page.getByRole("status")).toHaveText("Listening");
    await expect(pane.locator("article")).toContainText(
      "A newly streamed conclusion."
    );
    await expect
      .poll(async () => await position(pane))
      .toBeCloseTo(originalPosition, 0);
    expect(
      await page.evaluate((key) => sessionStorage.getItem(key), otherMemory)
    ).toBe(otherCache);
    await page.evaluate((url) => {
      location.hash = new URL(url).hash;
    }, otherURL);
    await expect(page.getByRole("status")).toHaveText("Listening");
    await expect
      .poll(async () => await position(pane))
      .toBeCloseTo(otherPosition, 0);
    expect(
      await page.evaluate((key) => sessionStorage.getItem(key), originalMemory)
    ).toBe(originalCache);
    expect(
      await page.evaluate((key) => sessionStorage.getItem(key), otherMemory)
    ).toBe(otherCache);
  } finally {
    await other.dispose();
  }
});

test("reconnect uses authenticated upgrades and cannot deliver an old connection's delayed acknowledgment", async ({
  page,
  relay,
}) => {
  await page.addInitScript(() => {
    const original = crypto.subtle.encrypt.bind(crypto.subtle);
    const pending = Promise.withResolvers<boolean>();
    let first = true;
    window.addEventListener(
      "release-first-ack",
      () => {
        pending.resolve(true);
      },
      { once: true }
    );
    crypto.subtle.encrypt = async (...args) => {
      const encrypted = await original(...args);
      if (first) {
        first = false;
        document.documentElement.dataset["heldAck"] = "true";
        await pending.promise;
        document.documentElement.dataset["releasedAck"] = "true";
      }
      return encrypted;
    };
  });
  const connections: {
    socket: WebSocketRoute;
    messages: string[];
    client?: string;
  }[] = [];
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    const connection = { client: "", messages: [] as string[], socket };
    connections.push(connection);
    const server = socket.connectToServer();
    socket.onMessage((message) => {
      connection.messages.push(String(message));
      server.send(message);
    });
    server.onMessage((message) => {
      const packet = parseViewerMessage(JSON.parse(String(message)));
      if (packet?.type === "ready") {
        connection.client = packet.client;
      }
      socket.send(message);
    });
  });
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "a",
        language: "English",
        status: "complete",
        text: "A retained answer",
      },
    ],
    live: true,
    selectedID: "a",
  });
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect
    .poll(
      async () =>
        await page.evaluate(() => document.documentElement.dataset["heldAck"])
    )
    .toBe("true");
  const [first] = connections;
  if (!first) {
    throw new Error("The viewer did not connect");
  }
  await first.socket.close({
    code: 1001,
    reason: "Reconnect before old ack completes",
  });
  await expect.poll(() => connections.length).toBe(2);
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [, second] = connections;
  if (!second || second.client === undefined || second.client.length === 0) {
    throw new Error(
      "The viewer did not authenticate its replacement connection"
    );
  }
  const ack = await relay.writer.next("ack");
  expect(ack.client).toBe(second.client);
  expect(ack.client).not.toBe(first.client);
  expect(await decryptAcknowledgment(relay, ack)).toEqual({
    command: 0,
    seq: 1,
  });
  await page.evaluate(() =>
    window.dispatchEvent(new Event("release-first-ack"))
  );
  await expect
    .poll(
      async () =>
        await page.evaluate(
          () => document.documentElement.dataset["releasedAck"]
        )
    )
    .toBe("true");
  // A render turn also lets the held encryption continuation finish.
  await page.evaluate(async () => {
    const frame = Promise.withResolvers<boolean>();
    requestAnimationFrame(() => {
      frame.resolve(true);
    });
    await frame.promise;
  });
  expect(first.messages).toEqual([]);
  expect(
    second.messages.map((message): unknown => JSON.parse(message))
  ).toEqual([{ box: ack.box, seq: 1, type: "ack" }]);
});

test("encrypted replay works without the new native browser base64 APIs", async ({
  page,
  relay,
}) => {
  await page.addInitScript(() => {
    Object.defineProperty(Uint8Array, "fromBase64", {
      configurable: true,
      value: undefined,
    });
    // Exercise the fallback on browsers whose typed arrays predate native base64.
    // oxlint-disable-next-line no-extend-native
    Object.defineProperty(Uint8Array.prototype, "toBase64", {
      configurable: true,
      value: undefined,
    });
  });
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "a",
        language: "English",
        status: "complete",
        text: "Portable encrypted answer",
      },
    ],
    live: true,
    selectedID: "a",
  });
  await page.goto(await relay.viewerURL());
  await expect(
    page.getByRole("region", { exact: true, name: "Answer" })
  ).toHaveText("Portable encrypted answer");
  const ack = await relay.writer.next("ack");
  expect(await decryptAcknowledgment(relay, ack)).toEqual({
    command: 0,
    seq: 1,
  });
});

test("a foreground viewer replaces a silent connection and receives the latest encrypted replay", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  let silent = false;
  let allowReconnect = false;
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    sockets.push(socket);
    if (sockets.length > 1) {
      if (allowReconnect) {
        socket.connectToServer();
      }
      return;
    }
    const server = socket.connectToServer();
    server.onMessage((message) => {
      if (!silent) {
        socket.send(message);
      }
    });
  });
  await relay.publish({ ...empty, live: true });
  await page.clock.install();
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  silent = true;
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "a",
        language: "English",
        status: "complete",
        text: "Latest replay after silence",
      },
    ],
    live: true,
    selectedID: "a",
  });
  await page.clock.fastForward(40_000);
  await expect(page.getByRole("status")).toHaveText("Reconnecting…");
  allowReconnect = true;
  for (const socket of sockets.slice(1)) {
    socket.connectToServer();
  }
  await page.clock.runFor(2000);
  await expect.poll(() => sockets.length).toBe(2);
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.getByText("Latest replay after silence")).toBeVisible();
});

for (const answerStatus of ["complete", "generating"] as const) {
  test(`session end retains the final ${answerStatus} snapshot and stops automatic reconnect`, async ({
    page,
    relay,
  }) => {
    await page.addInitScript(() => {
      const original = crypto.subtle.decrypt.bind(crypto.subtle);
      const pending = Promise.withResolvers<boolean>();
      window.addEventListener(
        "release-decrypt",
        () => {
          pending.resolve(true);
        },
        { once: true }
      );
      crypto.subtle.decrypt = async (...args) => {
        const result = await original(...args);
        document.documentElement.dataset["heldDecrypt"] = "true";
        await pending.promise;
        document.documentElement.dataset["releasedDecrypt"] = "true";
        return result;
      };
    });
    const sockets: WebSocketRoute[] = [];
    await page.routeWebSocket("**/rooms/*/socket", (socket) => {
      socket.connectToServer();
      sockets.push(socket);
    });
    await relay.publish({
      ...empty,
      answers: [
        {
          id: "a",
          language: "English",
          status: answerStatus,
          text: "Late snapshot",
        },
      ],
      selectedID: "a",
    });
    await page.clock.install();
    await page.goto(await relay.viewerURL());
    await expect
      .poll(
        async () =>
          await page.evaluate(
            () => document.documentElement.dataset["heldDecrypt"]
          )
      )
      .toBe("true");
    await relay.end();
    await expect(page.getByRole("status")).toHaveText("Session ended");
    await page.evaluate(() =>
      window.dispatchEvent(new Event("release-decrypt"))
    );
    await expect
      .poll(
        async () =>
          await page.evaluate(
            () => document.documentElement.dataset["releasedDecrypt"]
          )
      )
      .toBe("true");
    await page.clock.fastForward(60_000);
    await expect(page.getByRole("status")).toHaveText("Session ended");
    await expect(page.getByText("Late snapshot")).toBeVisible();
    await expect(page.locator("article.answer")).toHaveAttribute(
      "aria-busy",
      "false"
    );
    const incomplete = page.getByText("Incomplete answer", { exact: true });
    await expect(incomplete).toBeVisible({
      visible: answerStatus === "generating",
    });
    expect(sockets.length).toBe(1);
  });
}

test("unrecognized messages are ignored but recognized malformed packets and policy closes are terminal", async ({
  page,
  relay,
}) => {
  const sockets: WebSocketRoute[] = [];
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    socket.connectToServer();
    sockets.push(socket);
  });
  await relay.publish({ ...empty, live: true });
  await page.clock.install();
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  const [first] = sockets;
  if (!first) {
    throw new Error("The viewer did not connect");
  }
  first.send(JSON.stringify({ type: "future", value: true }));
  first.send(JSON.stringify({ type: null }));
  first.send(JSON.stringify({ type: 1 }));
  await relay.publish({
    ...empty,
    answers: [
      {
        id: "a",
        language: "English",
        status: "complete",
        text: `## Still connected\n\n${Array.from(
          { length: 30 },
          (_, index) => `Retained paragraph ${index}. Keep reading this answer.`
        ).join("\n\n")}`,
      },
    ],
    live: true,
    selectedID: "a",
  });
  await expect(page.getByText("Still connected")).toBeVisible();
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await pane.evaluate((element) => {
    element.scrollTop = 1000;
    element.dispatchEvent(new Event("scroll"));
  });
  const beforeFailure = await visibleAnchor(pane);
  if (!beforeFailure) {
    throw new Error("The retained answer has no visible reading anchor");
  }
  first.send(JSON.stringify({ box: "AAAA", seq: "3", type: "state" }));
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(page.getByRole("alert")).toHaveText(
    "The viewer connection stopped. Reload this viewer, or reopen it from Skill Issue on your Mac."
  );
  await expect(page.getByText("Still connected")).toHaveCount(1);
  const afterFailure = await visibleAnchor(pane);
  expect(afterFailure?.id).toBe(beforeFailure.id);
  expect(
    Math.abs((afterFailure?.offset ?? 0) - beforeFailure.offset)
  ).toBeLessThan(2);
  await expect(page.locator("footer")).toHaveCount(0);
  await page.clock.fastForward(60_000);
  expect(sockets.length).toBe(1);
  await page.clock.resume();
  await page.reload();
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(page.locator("footer")).toBeVisible();
  const [, second] = sockets;
  if (!second) {
    throw new Error("The viewer did not reconnect after reload");
  }
  await relay.publish({
    ...empty,
    answers: [
      { id: "pending", language: "English", status: "generating", text: "" },
    ],
    live: true,
    selectedID: "pending",
    selection: 1,
  });
  await expect(page.getByRole("status")).toHaveText("Thinking…");
  await second.close({ code: 1008, reason: "Policy rejection" });
  await expect(page.getByRole("status")).toHaveText(failure);
  await expect(
    pane.getByRole("heading", { name: "Couldn't open this viewer." })
  ).toBeVisible();
  await expect(pane.locator("article")).toHaveAttribute("aria-busy", "false");
  await expect(pane).not.toContainText("Preparing");
  await expect(pane).toContainText(
    "Reload this viewer, or reopen it from Skill Issue on your Mac."
  );
  await expect(page.locator("footer")).toHaveCount(0);
  await page.clock.fastForward(60_000);
  expect(sockets.length).toBe(2);
});

test("request hints follow encrypted Mac availability without exposing service errors", async ({
  page,
  relay,
}) => {
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  const requestHint = page.locator("footer").getByText("request answer");
  const state: ViewState = {
    ...empty,
    canAnswer: true,
    live: true,
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  await expect(page.getByRole("status")).toHaveText("Listening");
  await expect(requestHint).toBeVisible();
  await expect(
    pane.getByRole("heading", { name: "Press Space to request an answer." })
  ).toBeVisible();

  await relay.publish({
    ...state,
    canAnswer: false,
    error: "Service error containing private diagnostic information",
  });
  await expect(requestHint).toHaveCount(0);
  await expect(pane.getByRole("alert")).toHaveText(
    "Could not complete the request. Check Settings on your Mac to continue."
  );
  await expect(pane.getByText("Check your Mac to continue.")).toBeVisible();
  await expect(pane).not.toContainText("Space");
  await expect(pane).not.toContainText("private diagnostic information");
  await expect(page.locator("footer")).toContainText("read");
  await expect(page.locator("footer")).toContainText("history");

  await relay.publish({ ...state, error: "Quota exceeded" });
  await expect(requestHint).toBeVisible();
  await expect(pane.getByRole("alert")).toHaveText(
    "Could not complete the request. Check the error in Settings on your Mac, then request another answer."
  );
  await expect(
    pane.getByRole("heading", { name: "Press Space to request an answer." })
  ).toBeVisible();

  await relay.publish(state);
  await expect(pane.getByRole("alert")).toHaveCount(0);
  await expect(requestHint).toBeVisible();
  await relay.writer.close();
  await expect(page.getByRole("status")).toHaveText("Mac disconnected");
  await expect(requestHint).toHaveCount(0);
  await expect(pane).not.toContainText("Space");
});

test("failed answers retain scoped recovery guidance after a later request clears the error", async ({
  page,
  relay,
}) => {
  const failed = {
    id: "failed",
    language: "English",
    status: "failed" as const,
    text: "Partial earlier answer.",
  };
  const state: ViewState = {
    ...empty,
    answers: [failed],
    canAnswer: true,
    error: "Private request diagnostic",
    live: true,
    selectedID: failed.id,
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(pane.getByRole("alert")).toContainText(
    "Check the error in Settings"
  );
  const recovered: ViewState = {
    ...state,
    answers: [
      failed,
      {
        id: "next",
        language: "English",
        status: "complete",
        text: "New successful answer.",
      },
    ],
    error: "",
    selectedID: "next",
    selection: 1,
  };
  await relay.publish(recovered);
  await expect(pane).toContainText("New successful answer.");
  await relay.publish({ ...recovered, selectedID: failed.id, selection: 2 });
  await expect(pane).toContainText("Partial earlier answer.");
  await expect(pane.getByRole("alert")).toHaveCount(0);
  await expect(pane.locator(".error")).toHaveText(
    "Could not complete this answer. Request another answer on your Mac."
  );
  await expect(pane).not.toContainText("Private request diagnostic");
  await relay.publish({
    ...recovered,
    canAnswer: false,
    selectedID: failed.id,
    selection: 2,
  });
  await expect(pane.locator(".error")).toHaveText(
    "Could not complete this answer. Check Settings on your Mac to continue."
  );
  await relay.end();
  await expect(pane.locator(".error")).toHaveText(
    "Could not complete this answer. Start a new session on your Mac and open its viewer link."
  );
});

for (const card of [
  undefined,
  {
    id: "retained",
    language: "English",
    status: "incomplete",
    text: "A partial answer.",
  },
  {
    id: "retained",
    language: "English",
    status: "complete",
    text: "A complete answer.",
  },
  { id: "retained", language: "English", status: "failed", text: "" },
] as const) {
  test(`session end gives one recovery instruction (${card?.status ?? "empty"} answer)`, async ({
    page,
    relay,
  }) => {
    const error = card?.status === "failed" ? "" : "Quota exceeded";
    await relay.publish({
      ...empty,
      answers: card ? [card] : [],
      canAnswer: true,
      error,
      live: true,
      selectedID: card?.id,
    });
    await page.goto(await relay.viewerURL());
    await expect(page.getByRole("status")).toHaveText("Listening");
    const pane = page.getByRole("region", { exact: true, name: "Answer" });
    const notice = pane.locator(".error").filter({
      hasText: "Could not complete",
    });
    await expect(notice).toContainText(
      error
        ? "Check the error in Settings on your Mac, then request another answer."
        : "Request another answer on your Mac."
    );
    await relay.end();
    await expect(page.getByRole("status")).toHaveText("Session ended");
    const hasAnswer = card !== undefined && card.text !== "";
    const restart = "Start a new session on your Mac and open its viewer link.";
    const message = error
      ? "Could not complete the request."
      : "Could not complete this answer.";
    await expect(notice).toHaveText(
      hasAnswer ? `${message} ${restart}` : message
    );
    await expect(pane.getByText(restart, { exact: false })).toHaveCount(1);
    await expect(pane).not.toContainText("Check Settings");
    await expect(page.locator("footer")).toHaveCount(0);
    await (hasAnswer
      ? expect(pane.locator("article")).toContainText(card.text)
      : expect(
          pane.getByRole("heading", { name: "Session ended." })
        ).toBeVisible());
  });
}

test("recovery changes keep partial answers, anchors and scrolling usable", async ({
  page,
  relay,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const text = Array.from(
    { length: 60 },
    (_, index) =>
      `Paragraph ${index}. Keep this answer and the session context.`
  ).join("\n\n");
  const state: ViewState = {
    ...empty,
    answers: [
      { id: "retained", language: "English", status: "incomplete", text },
    ],
    canAnswer: true,
    live: true,
    selectedID: "retained",
  };
  await relay.publish(state);
  await page.goto(await relay.viewerURL());
  const pane = page.getByRole("region", { exact: true, name: "Answer" });
  await expect(pane.getByText("Paragraph 0.", { exact: false })).toBeVisible();
  await pane.evaluate((element) => {
    element.scrollTop = 1400;
    element.dispatchEvent(new Event("scroll"));
  });
  const anchor = await visibleAnchor(pane);
  if (!anchor) {
    throw new Error("The retained answer has no visible reading anchor");
  }
  const paragraphs = await pane.locator("article p[data-anchor]").count();
  const firstParagraph = await pane
    .locator("article p[data-anchor]")
    .first()
    .elementHandle();
  await relay.publish({
    ...state,
    canAnswer: false,
    error: "Authentication expired",
  });
  await expect(pane.getByRole("alert")).toContainText(
    "Check Settings on your Mac"
  );
  const blockedAnchor = await visibleAnchor(pane);
  expect(blockedAnchor?.id).toBe(anchor.id);
  expect(Math.abs((blockedAnchor?.offset ?? 0) - anchor.offset)).toBeLessThan(
    2
  );
  expect(await pane.locator("article p[data-anchor]").count()).toBe(paragraphs);
  expect(await firstParagraph?.evaluate((node) => node.isConnected)).toBe(true);
  await expect(
    pane.getByText("Incomplete answer", { exact: true })
  ).toHaveCount(1);
  await expect(page.locator("footer")).toContainText("history");
  await expect(page.locator("footer")).not.toContainText("request answer");

  await relay.publish({ ...state, error: "Quota exceeded" });
  await expect(pane.getByRole("alert")).toContainText(
    "then request another answer"
  );
  const recoveredAnchor = await visibleAnchor(pane);
  expect(recoveredAnchor?.id).toBe(anchor.id);
  await expect(page.locator("footer")).toContainText("request answer");
  await pane.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(
    pane.getByText("Incomplete answer", { exact: true })
  ).toBeInViewport();
});

for (const [name, cache] of [
  [
    "string offset",
    '[ ["stale", {"id":"h1.0","offset":0}], ["answer", {"id":"h1.0","offset":"-900"}] ]',
  ],
  [
    "nonfinite offset",
    '[ ["stale", {"id":"h1.0","offset":0}], ["answer", {"id":"h1.0","offset":1e400}] ]',
  ],
  [
    "invalid anchor ID",
    '[ ["stale", {"id":42,"offset":0}], ["answer", {"id":"h1.0","offset":-900}] ]',
  ],
] as const) {
  test(`a damaged reading cache (${name}) resets safely and keeps remote reading and acknowledgments usable`, async ({
    page,
    relay,
  }) => {
    const viewer = await relay.viewerURL();
    const memory = `reading:${new URL(viewer).hash.split(".")[0]}`;
    const paragraphs = Array.from(
      { length: 60 },
      (_, i) =>
        `Paragraph ${i + 1} remains readable after the damaged cache is discarded.\n\n`
    ).join("");
    const state: ViewState = {
      ...empty,
      answers: [
        {
          id: "answer",
          language: "English",
          status: "complete",
          text: `# Cache fallback\n\n${paragraphs}`,
        },
      ],
      canAnswer: true,
      live: true,
      selectedID: "answer",
    };
    await page.goto("/");
    const snapshot = await relay.publish(state);
    await page.evaluate(
      ({ key, value }) => {
        sessionStorage.setItem(key, value);
      },
      { key: memory, value: cache }
    );
    await page.goto(viewer);
    const pane = page.getByRole("region", { exact: true, name: "Answer" });
    await expect(page.getByRole("status")).toHaveText("Listening");
    await expect(
      pane.getByRole("heading", { name: "Cache fallback" })
    ).toBeVisible();
    await expect.poll(async () => await position(pane)).toBe(0);
    await expect
      .poll(
        async () =>
          await page.evaluate((key) => sessionStorage.getItem(key), memory)
      )
      .not.toContain('"stale"');
    const initial = await relay.writer.next("ack");
    expect(await decryptAcknowledgment(relay, initial)).toEqual({
      command: 0,
      seq: snapshot.seq,
    });
    const command = 1;
    const packet = await relay.publish({
      ...state,
      command: { answerID: "answer", direction: 1, id: command },
    });
    const height = await pane.evaluate((element) => element.clientHeight);
    await expect
      .poll(async () => Math.abs((await position(pane)) - height / 2))
      .toBeLessThanOrEqual(1);
    const applied = await relay.writer.next("ack");
    expect(await decryptAcknowledgment(relay, applied)).toEqual({
      command,
      seq: packet.seq,
    });
  });
}
