import { describe, expect, test } from "bun:test";

import type { ViewState } from "../protocol";
import { AnswerSelection } from "../web/selection";
import { empty } from "../web/session";

const state: ViewState = {
  ...empty,
  answers: ["a", "b", "c"].map((id) => ({
    id,
    language: "English",
    status: "complete",
    text: id,
  })),
  live: true,
  selectedID: "c",
  selection: 3,
};

describe("shared answer selection", () => {
  test("rapid taps survive streaming, earlier receipts and other viewers until confirmed", () => {
    const selection = new AnswerSelection();
    selection.receive(state, "mac", "phone");
    expect(selection.move(state.answers, -1)).toEqual({
      answerID: "b",
      id: 1,
      publisher: "mac",
    });
    expect(selection.move(state.answers, -1)).toEqual({
      answerID: "a",
      id: 2,
      publisher: "mac",
    });
    selection.receive(state, "mac", "phone");
    expect(selection.selectedID).toBe("a");
    selection.receive(
      {
        ...state,
        selectedID: "b",
        selection: 4,
        selectionRequest: { client: "phone", id: 1 },
      },
      "mac",
      "phone"
    );
    expect(selection.selectedID).toBe("a");
    selection.receive(
      {
        ...state,
        selection: 5,
        selectionRequest: { client: "another-phone", id: 2 },
      },
      "mac",
      "phone"
    );
    expect(selection.selectedID).toBe("a");
    selection.receive(
      {
        ...state,
        selectedID: "a",
        selection: 6,
        selectionRequest: { client: "phone", id: 2 },
      },
      "mac",
      "phone"
    );
    selection.receive(
      { ...state, selectedID: "b", selection: 7 },
      "mac",
      "phone"
    );
    expect(selection.selectedID).toBe("b");
    selection.receive(state, "mac", "phone");
    expect(selection.selectedID).toBe("b");
  });

  test("offline browsing has no requests and reconnect adopts the Mac even at the same revision", () => {
    const selection = new AnswerSelection();
    selection.receive(state, "mac", "phone");
    selection.move(state.answers, -1);
    selection.disconnect();
    expect(selection.move(state.answers, -1)).toBeUndefined();
    selection.receive(state, null, "phone");
    expect(selection.selectedID).toBe("a");
    selection.receive(state, "mac", "reconnected-phone");
    expect(selection.selectedID).toBe("c");
    expect(selection.move(state.answers, -1)?.answerID).toBe("b");
  });

  test("publisher replacement drops a lost receipt without needing an offline event", () => {
    const selection = new AnswerSelection();
    selection.receive(state, "first-mac", "phone");
    selection.move(state.answers, -1);
    selection.receive(state, "replacement-mac", "phone");
    expect(selection.selectedID).toBe("c");
    expect(selection.move(state.answers, -1)).toEqual({
      answerID: "b",
      id: 2,
      publisher: "replacement-mac",
    });
  });

  test("empty and single-answer histories stay within bounds; removed answers have a valid fallback", () => {
    const selection = new AnswerSelection();
    selection.receive(empty, null, "phone");
    expect(selection.selectedID).toBeNull();
    expect(selection.move([], 1)).toBeUndefined();
    const single: ViewState = {
      ...state,
      answers: state.answers.slice(0, 1),
      selectedID: "a",
    };
    selection.receive(single, null, "phone");
    expect(selection.selectedID).toBe("a");
    expect(selection.move(single.answers, -1)).toBeUndefined();
    expect(selection.move(single.answers, 1)).toBeUndefined();
    selection.receive(state, null, "phone");
    selection.move(state.answers, 1);
    selection.receive(single, null, "phone");
    expect(selection.selectedID).toBe("a");
    selection.receive(empty, null, "phone");
    expect(selection.selectedID).toBeNull();
  });
});
