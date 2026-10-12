import type { Packet } from "../../protocol";

type Message =
  | Packet
  | { type: "ready"; client: string }
  | { type: "ack"; client: string; seq: number; box: string }
  | { type: "peers"; readers: string[] }
  | { type: "offline" }
  | { type: "ended" };
type TypedMessage<T extends Message["type"]> = Extract<Message, { type: T }>;
// Bun and Node accept handshake headers; lib.dom only declares browser overloads.
const Socket = WebSocket as typeof WebSocket & {
  new (
    endpoint: string,
    options: { protocols: string[]; headers: Record<string, string> }
  ): WebSocket;
};

export class Peer {
  readonly socket: WebSocket;
  readonly closed: Promise<CloseEvent>;
  private readonly messages: Message[] = [];
  private readonly waiting = new Set<() => void>();

  constructor(
    endpoint: string,
    role: "writer" | "reader",
    token: string,
    clientIP?: string
  ) {
    this.socket = new Socket(endpoint, {
      headers: clientIP === undefined ? {} : { "CF-Connecting-IP": clientIP },
      protocols: ["skill-issue", `skill-issue.${role}.${token}`],
    });
    const closed = Promise.withResolvers<CloseEvent>();
    this.closed = closed.promise;
    this.socket.addEventListener("close", closed.resolve, { once: true });
    this.socket.addEventListener("message", (event) => {
      this.messages.push(JSON.parse(String(event.data)) as Message);
      for (const notify of this.waiting) {
        notify();
      }
    });
    this.socket.addEventListener("close", () => {
      for (const notify of this.waiting) {
        notify();
      }
    });
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
