import type { ViewState } from "../protocol";

export interface SelectionCommand {
  answerID: string;
  id: number;
  publisher: string;
}

export class AnswerSelection {
  selectedID: string | null = null;
  publisher: string | null = null;
  private client = "";
  private revision = -1;
  private request = 0;
  private pending = 0;

  disconnect() {
    this.publisher = null;
    this.pending = 0;
  }

  receive(state: ViewState, publisher: string | null, client: string) {
    const restored = publisher !== this.publisher || client !== this.client;
    if (restored) {
      this.pending = 0;
    }
    this.publisher = publisher;
    this.client = client;
    const receipt = state.selectionRequest;
    if (receipt?.client === client && receipt.id === this.pending) {
      this.pending = 0;
    }
    const remoteID =
      state.answers.find((answer) => answer.id === state.selectedID)?.id ??
      state.answers.at(-1)?.id ??
      null;
    // Streaming snapshots can precede the Mac's confirmation of a local tap.
    // Keep that tap visible until its receipt, or until the connection changes.
    if (
      publisher !== null &&
      this.pending === 0 &&
      (restored || state.selection > this.revision)
    ) {
      this.selectedID = remoteID;
    }
    if (!state.answers.some((answer) => answer.id === this.selectedID)) {
      this.selectedID = remoteID;
    }
    this.revision = Math.max(this.revision, state.selection);
  }

  move(
    answers: ViewState["answers"],
    direction: -1 | 1
  ): SelectionCommand | undefined {
    const index = answers.findIndex((answer) => answer.id === this.selectedID);
    const answer = answers[index + direction];
    if (index === -1 || !answer) {
      return undefined;
    }
    this.selectedID = answer.id;
    if (this.publisher === null) {
      return undefined;
    }
    this.request += 1;
    this.pending = this.request;
    return {
      answerID: answer.id,
      id: this.request,
      publisher: this.publisher,
    } satisfies SelectionCommand;
  }
}
