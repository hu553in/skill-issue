interface TranscriptSegment {
  id: string;
  source: "computer" | "microphone";
  start: number;
  end: number;
  text: string;
}
interface AnswerCard {
  id: string;
  text: string;
  status: "generating" | "complete" | "incomplete" | "failed";
}
interface ViewerCommand {
  id: number;
  answerID?: string | null;
  direction: number;
}
export interface ViewState {
  version: number;
  live: boolean;
  answers: AnswerCard[];
  selectedID?: string | null;
  selection: number;
  command?: ViewerCommand | null;
  transcript: TranscriptSegment[];
  mode: "answer" | "transcript";
  fontSize: number;
  language: string;
  modifiers: string;
  error: string;
}
export interface Packet {
  type: "state";
  seq: number;
  box: string;
}
export const empty: ViewState = {
  answers: [],
  error: "",
  fontSize: 20,
  language: "English",
  live: false,
  mode: "answer",
  modifiers: "⌃⌥⌘",
  selection: 0,
  transcript: [],
  version: 1,
};
export const failure = "Couldn't complete that. Try again.";
export const unbase64 = (text: string) =>
  Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), (c) =>
    // atob produces bytes, so each character is exactly one UTF-16 code unit.
    // oxlint-disable-next-line unicorn/prefer-code-point
    c.charCodeAt(0)
  );
export const base64 = (bytes: Uint8Array) => {
  let value = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    value += String.fromCodePoint(...bytes.subarray(i, i + 8192));
  }
  return btoa(value);
};
export function parseLink(fragment: string) {
  const parts = fragment.replace(/^#/u, "").split(".");
  const [room, token, key] = parts;
  if (
    parts.length !== 3 ||
    room === undefined ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(
      room
    ) ||
    token === undefined ||
    !/^[\w-]{43}$/u.test(token) ||
    key === undefined ||
    !/^[\w-]{43}$/u.test(key)
  ) {
    throw new Error(failure);
  }
  return { key, room, token };
}
const finite = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
export async function decrypt(
  key: CryptoKey,
  room: string,
  packet: Packet
): Promise<ViewState> {
  if (
    !Number.isSafeInteger(packet.seq) ||
    packet.seq < 1 ||
    typeof packet.box !== "string" ||
    packet.box.length > 4_000_000
  ) {
    throw new Error(failure);
  }
  const bytes = unbase64(packet.box);
  const data = await crypto.subtle.decrypt(
    {
      additionalData: new TextEncoder().encode(`${room}:${packet.seq}`),
      iv: bytes.slice(0, 12),
      name: "AES-GCM",
    },
    key,
    bytes.slice(12)
  );
  // Every snapshot field is validated below before it reaches viewer state.
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion
  const state = JSON.parse(new TextDecoder().decode(data)) as ViewState;
  if (
    state.version !== 1 ||
    typeof state.live !== "boolean" ||
    !Array.isArray(state.answers) ||
    !Array.isArray(state.transcript) ||
    !Number.isSafeInteger(state.selection) ||
    state.selection < 0 ||
    !["answer", "transcript"].includes(state.mode) ||
    !finite(state.fontSize) ||
    state.fontSize < 16 ||
    state.fontSize > 40 ||
    (["language", "modifiers", "error"] as const).some(
      (k) => typeof state[k] !== "string"
    )
  ) {
    throw new Error(failure);
  }
  if (
    state.selectedID !== undefined &&
    state.selectedID !== null &&
    typeof state.selectedID !== "string"
  ) {
    throw new Error(failure);
  }
  if (
    state.answers.some(
      (card: AnswerCard) =>
        typeof card.id !== "string" ||
        typeof card.text !== "string" ||
        !["generating", "complete", "incomplete", "failed"].includes(
          card.status
        )
    )
  ) {
    throw new Error(failure);
  }
  if (
    state.transcript.some(
      (line: TranscriptSegment) =>
        typeof line.id !== "string" ||
        !["computer", "microphone"].includes(line.source) ||
        !finite(line.start) ||
        !finite(line.end) ||
        line.end < line.start ||
        typeof line.text !== "string"
    )
  ) {
    throw new Error(failure);
  }
  if (
    state.command !== undefined &&
    state.command !== null &&
    (!Number.isSafeInteger(state.command.id) ||
      state.command.id < 1 ||
      ![-1, 1].includes(state.command.direction) ||
      (state.command.answerID !== undefined &&
        state.command.answerID !== null &&
        typeof state.command.answerID !== "string"))
  ) {
    throw new Error(failure);
  }
  return state;
}
export async function acknowledgment(
  key: CryptoKey,
  room: string,
  client: string,
  seq: number,
  command: number
) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        additionalData: new TextEncoder().encode(
          `${room}:ack:${client}:${seq}`
        ),
        iv,
        name: "AES-GCM",
      },
      key,
      new TextEncoder().encode(JSON.stringify({ command, seq }))
    )
  );
  const box = new Uint8Array(iv.length + cipher.length);
  box.set(iv);
  box.set(cipher, iv.length);
  return JSON.stringify({ box: base64(box), seq, type: "ack" });
}
