import { assert, looseObject, string } from "valibot";
import { WebSocket } from "ws";

import type { ViewerPacket } from "../../protocol";

type Message =
  | ViewerPacket
  | { type: "ready"; client: string }
  | { type: "ack"; client: string; seq: number; box: string }
  | {
      type: "select";
      client: string;
      publisher: string;
      id: number;
      box: string;
    }
  | { type: "peers"; readers: string[] }
  | { type: "offline" }
  | { type: "ended" };
type TypedMessage<T extends Message["type"]> = Extract<Message, { type: T }>;
const MessageEnvelopeSchema = looseObject({ type: string() });
export class Peer {
  readonly socket: WebSocket;
  readonly closed: Promise<WebSocket.CloseEvent>;
  private readonly messages: Message[] = [];
  private readonly waiting = new Set<() => void>();
  private failure: Error | undefined;

  constructor(
    endpoint: string,
    role: "writer" | "reader",
    token: string,
    clientIP?: string
  ) {
    this.socket = new WebSocket(
      endpoint,
      ["skill-issue", `skill-issue.${role}.${token}`],
      {
        headers: clientIP === undefined ? {} : { "CF-Connecting-IP": clientIP },
      }
    );
    const closed = Promise.withResolvers<WebSocket.CloseEvent>();
    this.closed = closed.promise;
    this.socket.addEventListener(
      "close",
      (event) => {
        closed.resolve(event);
        this.notify();
      },
      { once: true }
    );
    this.socket.addEventListener("message", (event) => {
      try {
        if (typeof event.data !== "string") {
          throw new TypeError("Expected a text WebSocket packet");
        }
        const message = JSON.parse(event.data) as Message;
        assert(MessageEnvelopeSchema, message);
        this.messages.push(message);
      } catch (error) {
        this.failure =
          error instanceof Error ? error : new Error(String(error));
      }
      this.notify();
    });
    this.socket.on("error", (error) => {
      this.failure = new Error(`WebSocket connection failed: ${endpoint}`, {
        cause: error,
      });
      this.notify();
    });
  }

  private notify() {
    for (const notify of this.waiting) {
      notify();
    }
  }

  send(message: unknown) {
    this.socket.send(
      typeof message === "string" ? message : JSON.stringify(message)
    );
  }

  async next<T extends Message["type"]>(type: T): Promise<TypedMessage<T>> {
    const pending = Promise.withResolvers<TypedMessage<T>>();
    const timeout = setTimeout(() => {
      pending.reject(new Error(`Timed out waiting for ${type}`));
    }, 5000);
    const check = () => {
      const index = this.messages.findIndex((message) => message.type === type);
      if (index !== -1) {
        this.waiting.delete(check);
        pending.resolve(this.messages.splice(index, 1)[0] as TypedMessage<T>);
      } else if (this.failure !== undefined) {
        pending.reject(this.failure);
      } else if (this.socket.readyState === WebSocket.CLOSED) {
        pending.reject(new Error(`Socket closed before ${type}`));
      }
    };
    this.waiting.add(check);
    check();
    try {
      return await pending.promise;
    } finally {
      clearTimeout(timeout);
      this.waiting.delete(check);
    }
  }

  async close() {
    this.socket.close(1000);
    await this.closed;
  }
}
