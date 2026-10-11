import { base64, base64urlnopad } from "@scure/base";

import type { Packet, ViewState } from "../protocol";
import { Peer } from "./e2e/peer";

interface RoomCredentials {
  id: string;
  writer: string;
  reader: string;
}
export class RelaySession {
  readonly base: string;
  readonly room: RoomCredentials;
  readonly key: CryptoKey;
  readonly writer: Peer;
  readonly peers: Peer[] = [];
  private sequence = 0;
  private ended = false;

  private constructor(
    base: string,
    room: RoomCredentials,
    key: CryptoKey,
    writer: Peer
  ) {
    this.base = base;
    this.room = room;
    this.key = key;
    this.writer = writer;
  }

  static async create(base: string) {
    const response = await fetch(`${base}/rooms`, { method: "POST" });
    if (!response.ok) {
      throw new Error(`Room creation failed: ${response.status}`);
    }
    const room = (await response.json()) as RoomCredentials;
    const key = await crypto.subtle.generateKey(
      { length: 256, name: "AES-GCM" },
      true,
      ["encrypt", "decrypt"]
    );
    const endpoint = `${base.replace(/^http/u, "ws")}/rooms/${room.id}/socket`;
    const writer = new Peer(endpoint, "writer", room.writer);
    const session = new RelaySession(base, room, key, writer);
    session.peers.push(writer);
    try {
      await writer.next("ready");
      return session;
    } catch (error) {
      await session.dispose();
      throw error;
    }
  }

  async viewerURL() {
    const bytes = new Uint8Array(
      await crypto.subtle.exportKey("raw", this.key)
    );
    const secret = base64urlnopad.encode(bytes);
    return `${this.base}/#${this.room.id}.${this.room.reader}.${secret}`;
  }

  async connect(
    role: "writer" | "reader",
    token = role === "writer" ? this.room.writer : this.room.reader
  ) {
    const peer = new Peer(
      `${this.base.replace(/^http/u, "ws")}/rooms/${this.room.id}/socket`,
      role,
      token
    );
    this.peers.push(peer);
    const ready = await peer.next("ready");
    return { client: ready.client, peer };
  }

  async publish(state: ViewState, writer = this.writer): Promise<Packet> {
    this.sequence += 1;
    const seq = this.sequence;
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = new Uint8Array(
      await crypto.subtle.encrypt(
        {
          additionalData: new TextEncoder().encode(`${this.room.id}:${seq}`),
          iv,
          name: "AES-GCM",
        },
        this.key,
        new TextEncoder().encode(JSON.stringify(state))
      )
    );
    const box = new Uint8Array(iv.length + ciphertext.length);
    box.set(iv);
    box.set(ciphertext, iv.length);
    const packet: Packet = { box: base64.encode(box), seq, type: "state" };
    writer.send(packet);
    return packet;
  }

  async end() {
    if (this.ended) {
      return;
    }
    const response = await fetch(`${this.base}/rooms/${this.room.id}/end`, {
      headers: { Authorization: `Bearer ${this.room.writer}` },
      method: "POST",
    });
    if (!response.ok) {
      throw new Error(`Room deletion failed: ${response.status}`);
    }
    this.ended = true;
  }

  async dispose() {
    try {
      await this.end();
    } finally {
      await Promise.all(
        this.peers.map(async (peer) => {
          await peer.close();
        })
      );
    }
  }
}
