export interface Anchor {
  id: string;
  offset: number;
}
const destinations = new WeakMap<HTMLElement, number>();
const corrections = new WeakMap<HTMLElement, number>();
const watched = new WeakSet<HTMLElement>();
function clearCorrection(pane: HTMLElement) {
  const frame = corrections.get(pane);
  if (frame !== undefined) {
    cancelAnimationFrame(frame);
  }
  corrections.delete(pane);
}
export function cancelScroll(pane: HTMLElement) {
  clearCorrection(pane);
  if (!destinations.delete(pane)) {
    return;
  }
  pane.scrollTo({ behavior: "instant", top: pane.scrollTop });
}
export function readingAnchor(pane: HTMLElement): Anchor | undefined {
  const { top } = pane.getBoundingClientRect();
  const elements = [...pane.querySelectorAll<HTMLElement>("[data-anchor]")];
  const visible = elements.filter(
    (element) =>
      element.getBoundingClientRect().bottom > top + 1 &&
      element.getBoundingClientRect().top < top + pane.clientHeight
  );
  // Nested lists and code blocks have parent anchors too. Save the first visible
  // leaf so font-size changes preserve the paragraph or code line being read.
  const element = visible.find(
    (parent) =>
      !visible.some((child) => child !== parent && parent.contains(child))
  );
  const id = element?.dataset["anchor"];
  return element && id !== undefined
    ? {
        id,
        offset: element.getBoundingClientRect().top - top,
      }
    : undefined;
}
export function restoreAnchor(
  pane: HTMLElement,
  anchor?: Anchor,
  interrupt = true
) {
  // Streaming snapshots must not cancel a manual scroll between animation frames.
  const scrolling = destinations.has(pane) || corrections.has(pane);
  if (!interrupt && scrolling) {
    return;
  }
  clearCorrection(pane);
  destinations.delete(pane);
  const position = () => {
    if (!anchor) {
      return 0;
    }
    const element = pane.querySelector<HTMLElement>(
      `[data-anchor="${CSS.escape(anchor.id)}"]`
    );
    return element
      ? pane.scrollTop +
          element.getBoundingClientRect().top -
          pane.getBoundingClientRect().top -
          anchor.offset
      : pane.scrollTop;
  };
  const top = position();
  if (scrolling || Math.abs(top - pane.scrollTop) > 0.5) {
    pane.scrollTo({ behavior: "instant", top });
  }
  // A compositor frame already queued before cancellation can land afterwards.
  // Correct once, unless newer navigation or direct input supersedes the restore.
  if (scrolling) {
    corrections.set(
      pane,
      requestAnimationFrame(() => {
        corrections.delete(pane);
        pane.scrollTo({ behavior: "instant", top: position() });
      })
    );
  }
}
export function scrollPage(pane: HTMLElement, direction: number) {
  clearCorrection(pane);
  if (!watched.has(pane)) {
    watched.add(pane);
    pane.addEventListener("scrollend", () => {
      if (
        Math.abs(pane.scrollTop - (destinations.get(pane) ?? pane.scrollTop)) <
        1
      ) {
        destinations.delete(pane);
      }
    });
    for (const event of ["wheel", "touchstart", "pointerdown"]) {
      pane.addEventListener(
        event,
        () => {
          cancelScroll(pane);
        },
        { passive: true }
      );
    }
    pane.addEventListener("keydown", (event) => {
      if (
        [
          "ArrowUp",
          "ArrowDown",
          "PageUp",
          "PageDown",
          "Home",
          "End",
          " ",
        ].includes(event.key)
      ) {
        cancelScroll(pane);
      }
    });
  }
  const previous = destinations.get(pane) ?? pane.scrollTop;
  const top = Math.max(
    0,
    Math.min(
      pane.scrollHeight - pane.clientHeight,
      previous + direction * pane.clientHeight * 0.5
    )
  );
  if (top === previous) {
    return;
  }
  const behavior = matchMedia("(prefers-reduced-motion: reduce)").matches
    ? "auto"
    : "smooth";
  if (behavior === "smooth") {
    destinations.set(pane, top);
  } else {
    destinations.delete(pane);
  }
  pane.scrollTo({ behavior, top });
}
