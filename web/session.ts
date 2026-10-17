import { base64 } from "@scure/base";
import * as v from "valibot";

import type { Packet, ViewState } from "../protocol";
import {
  StatePacketSchema,
  ViewerLinkSchema,
  ViewStateSchema,
} from "../protocol";
import type { SelectionCommand } from "./selection";

export const empty: ViewState = {
  answers: [],
  audioEnabled: true,
  canAnswer: false,
  error: "",
  fontSize: 20,
  live: false,
  modifiers: "⌃⌥⌘",
  selection: 0,
  version: 3,
};
export const failure = "Couldn't complete that.";
export function parseLink(fragment: string) {
  const result = v.safeParse(
    ViewerLinkSchema,
    fragment.replace(/^#/u, "").split(".")
  );
  if (!result.success) {
    throw new Error(failure);
  }
  const [room, token, key] = result.output;
  return { key, room, token };
}
const pendingAccessLink = "skill-issue:access-link";
export function viewerFragment() {
  let pending: string | null;
  try {
    pending = sessionStorage.getItem(pendingAccessLink);
    sessionStorage.removeItem(pendingAccessLink);
  } catch {
    return location.hash;
  }
  if (location.hash || pending === null || pending === "") {
    return location.hash;
  }
  try {
    parseLink(pending);
    const url = new URL(location.href);
    url.hash = pending;
    history.replaceState(history.state, "", url);
    return location.hash;
  } catch {
    return location.hash;
  }
}
export function rememberAccessLink(fragment: string) {
  try {
    parseLink(fragment);
    sessionStorage.setItem(pendingAccessLink, fragment);
  } catch {
    /* Reopen the original viewer link if this browser cannot retain it. */
  }
}
export async function decrypt(
  key: CryptoKey,
  room: string,
  packet: Packet
): Promise<ViewState> {
  v.parse(StatePacketSchema, packet);
  const bytes = base64.decode(packet.box);
  const data = await crypto.subtle.decrypt(
    {
      additionalData: new TextEncoder().encode(`${room}:${packet.seq}`),
      iv: bytes.slice(0, 12),
      name: "AES-GCM",
    },
    key,
    bytes.slice(12)
  );
  return v.parse(ViewStateSchema, JSON.parse(new TextDecoder().decode(data)));
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
  return JSON.stringify({ box: base64.encode(box), seq, type: "ack" });
}

export async function selectAnswer(
  key: CryptoKey,
  room: string,
  client: string,
  { answerID, id, publisher }: SelectionCommand
) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        additionalData: new TextEncoder().encode(
          `${room}:select:${client}:${publisher}:${id}`
        ),
        iv,
        name: "AES-GCM",
      },
      key,
      new TextEncoder().encode(JSON.stringify({ answerID }))
    )
  );
  const box = new Uint8Array(iv.length + cipher.length);
  box.set(iv);
  box.set(cipher, iv.length);
  return JSON.stringify({
    box: base64.encode(box),
    id,
    publisher,
    type: "select",
  });
}
