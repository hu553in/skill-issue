import type { Locator, WebSocketRoute } from "@playwright/test";

import { empty, failure } from "../../web/session";
import type { ViewState } from "../../web/session";
import { RelaySession } from "../relay";
import { expect, test } from "./fixtures";

type AnswerCard = ViewState["answers"][number];

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
});

test("encrypted answers render Markdown safely and expose session status", async ({
  page,
  relay,
}) => {
  const errors: Error[] = [];
  page.on("pageerror", (error) => errors.push(error));
  const answer: AnswerCard = {
    id: "answer",
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

test("scrolling, history, reconnect and session switching preserve separate reading positions", async ({
  page,
  relay,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page
    .context()
    .setExtraHTTPHeaders({ "CF-Connecting-IP": "203.0.113.20" });
  const sockets: WebSocketRoute[] = [];
  await page.routeWebSocket("**/rooms/*/socket", (socket) => {
    socket.connectToServer();
    sockets.push(socket);
  });
  const paragraphs = Array.from(
    { length: 60 },
    (_, index) =>
      `Paragraph ${index}. Use a hash map to look up the value efficiently.\n\n`
  ).join("");
  const firstAnswer: AnswerCard = {
    id: "first",
    status: "generating",
    text: `# First answer\n\n${paragraphs}`,
  };
  const secondAnswer: AnswerCard = {
    id: "second",
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
    .poll(async () => await position(pane))
    .toBeCloseTo(height / 2, 0);
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
    .poll(async () => await position(pane))
    .toBeCloseTo(afterResize + height / 2, 0);
  const originalPosition = await position(pane);
  const originalURL = await relay.viewerURL();
  const originalMemory = `reading:${new URL(originalURL).hash.split(".")[0]}`;
  const originalCache = await page.evaluate(
    (key) => sessionStorage.getItem(key),
    originalMemory
  );
  expect(originalCache).not.toBeNull();
  const other = await RelaySession.create(relay.base);
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
      .poll(async () => await position(pane))
      .toBeCloseTo(height / 2, 0);
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
