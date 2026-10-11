import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import type { CSSProperties } from "react";
import { createRoot } from "react-dom/client";

import answerLanguages from "../native/Resources/answer-languages.json";
import { Answer } from "./Answer";
import { readingAnchor, restoreAnchor, scrollPage } from "./reading";
import type { Anchor } from "./reading";
import {
  acknowledgment,
  decrypt,
  empty,
  failure,
  parseLink,
  unbase64,
} from "./session";
import type { ViewState } from "./session";

import "./style.css";

interface Update {
  state: ViewState;
  reconnect: boolean;
  applied: (command: number) => void;
}
const restartGuide =
  "Start a new session on your Mac and open its viewer link.";
const App = () => {
  const [update, setUpdate] = useState<Update>({
    applied: () => {
      /* The empty state has no command to acknowledge. */
    },
    reconnect: true,
    state: empty,
  });
  const { state } = update;
  const [status, setStatus] = useState("Connecting…");
  const keepAwake =
    state.live && status !== "Session ended" && status !== failure;
  const [fragment, setFragment] = useState(() => location.hash);
  const pane = useRef<HTMLElement>(null);
  const anchors = useRef(new Map<string, Anchor>());
  const active = useRef("");
  const readingSize = useRef(empty.fontSize);
  const command = useRef(0);
  const selection = useRef(-1);
  const selected = useRef<string | null>(null);
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const memoryKey = useRef(`reading:${fragment.split(".")[0]}`);
  const save = useCallback(() => {
    if (!pane.current || !active.current) {
      return;
    }
    const anchor = readingAnchor(pane.current);
    if (!anchor) {
      return;
    }
    anchors.current.set(active.current, anchor);
    try {
      sessionStorage.setItem(
        memoryKey.current,
        JSON.stringify([...anchors.current])
      );
    } catch {
      /* Reading works without browser storage. */
    }
  }, []);
  useEffect(() => {
    const changed = () => {
      setFragment(location.hash);
    };
    window.addEventListener("hashchange", changed);
    return () => {
      window.removeEventListener("hashchange", changed);
    };
  }, []);
  useEffect(() => {
    anchors.current.clear();
    active.current = "";
    memoryKey.current = `reading:${fragment.split(".")[0]}`;
    command.current = 0;
    selection.current = -1;
    selected.current = null;
    setSelectedID(null);
    try {
      // This viewer owns the saved tuple format; unreadable storage is ignored.
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion
      const cached = JSON.parse(
        sessionStorage.getItem(memoryKey.current) ?? "[]"
      ) as [string, Anchor][];
      anchors.current = new Map(cached);
    } catch {
      /* Ignore damaged position cache. */
    }
    if (pane.current) {
      restoreAnchor(pane.current);
    }
    setUpdate({
      applied: () => {
        /* The empty state has no command to acknowledge. */
      },
      reconnect: true,
      state: empty,
    });
    setStatus("Connecting…");
    if (!fragment) {
      return;
    }
    let socket: WebSocket | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let disposed = false;
    let ended = false;
    let generation = 0;
    let highest = 0;
    let lastReceived = Date.now();
    async function connect() {
      generation += 1;
      const run = generation;
      try {
        const { room, token, key: rawKey } = parseLink(fragment);
        const key = await crypto.subtle.importKey(
          "raw",
          unbase64(rawKey),
          "AES-GCM",
          false,
          ["decrypt", "encrypt"]
        );
        if (disposed || run !== generation) {
          return;
        }
        const url = new URL(`/rooms/${room}/socket`, location.origin);
        url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
        const ws = new WebSocket(url);
        socket = ws;
        let queue = Promise.resolve();
        let client = "";
        let first = true;
        ws.addEventListener("open", () => {
          ws.send(JSON.stringify({ role: "reader", token, type: "auth" }));
        });
        ws.addEventListener("message", (event: MessageEvent<unknown>) => {
          lastReceived = Date.now();
          queue = queue
            .then(async () => {
              if (disposed || run !== generation) {
                return;
              }
              const { data } = event;
              if (typeof data !== "string") {
                throw new TypeError(failure);
              }
              const packet: unknown = JSON.parse(data);
              if (
                typeof packet !== "object" ||
                packet === null ||
                !("type" in packet)
              ) {
                throw new Error(failure);
              }
              if (packet.type === "ready") {
                if (
                  !("client" in packet) ||
                  typeof packet.client !== "string"
                ) {
                  throw new Error(failure);
                }
                ({ client } = packet);
                if (ws.readyState === WebSocket.OPEN) {
                  setStatus("Connected");
                }
                return;
              }
              if (packet.type === "offline") {
                if (ws.readyState === WebSocket.OPEN) {
                  setStatus("Mac disconnected");
                }
                return;
              }
              if (packet.type === "ended") {
                ended = true;
                setStatus("Session ended");
                return;
              }
              if (packet.type !== "state") {
                return;
              }
              if (
                !("seq" in packet) ||
                typeof packet.seq !== "number" ||
                !("box" in packet) ||
                typeof packet.box !== "string"
              ) {
                throw new Error(failure);
              }
              const { box, seq } = packet;
              if (seq < highest) {
                return;
              }
              const next = await decrypt(key, room, {
                box,
                seq,
                type: "state",
              });
              if (disposed || ended || run !== generation) {
                return;
              }
              const reconnect = first;
              first = false;
              highest = seq;
              save();
              await new Promise<void>((resolve) => {
                setUpdate({
                  applied: (appliedCommand) => {
                    void acknowledgment(key, room, client, seq, appliedCommand)
                      .then((ack) => {
                        if (ws.readyState === WebSocket.OPEN) {
                          ws.send(ack);
                        }
                      })
                      .catch(() => {
                        /* A disconnected peer cannot receive acknowledgment. */
                      });
                    resolve();
                  },
                  reconnect,
                  state: next,
                });
              });
              if (
                !disposed &&
                run === generation &&
                ws.readyState === WebSocket.OPEN
              ) {
                setStatus(next.live ? "Listening" : "Connected");
              }
            })
            .catch(() => {
              if (!disposed && run === generation) {
                ended = true;
                setStatus(failure);
                ws.close();
              }
            });
        });
        ws.addEventListener("close", (event) => {
          if (disposed || ended || run !== generation) {
            return;
          }
          if (event.code === 1008) {
            ended = true;
            setStatus(failure);
            return;
          }
          setStatus("Reconnecting…");
          timer = setTimeout(() => {
            void connect();
          }, 1500);
        });
      } catch {
        if (!disposed && run === generation) {
          setStatus(failure);
        }
      }
    }
    void connect();
    const watchdog = setInterval(() => {
      if (
        !disposed &&
        !ended &&
        document.visibilityState === "visible" &&
        Date.now() - lastReceived > 35_000
      ) {
        socket?.close();
      }
    }, 10_000);
    const visibility = () => {
      if (
        document.visibilityState === "visible" &&
        !ended &&
        socket?.readyState === WebSocket.CLOSED
      ) {
        clearTimeout(timer);
        void connect();
      }
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      disposed = true;
      clearTimeout(timer);
      clearInterval(watchdog);
      document.removeEventListener("visibilitychange", visibility);
      socket?.close();
    };
  }, [fragment, save]);
  useLayoutEffect(() => {
    if (state === empty) {
      return;
    }
    if (state.selection >= selection.current) {
      selection.current = state.selection;
      selected.current = state.selectedID ?? null;
    }
    if (selectedID !== selected.current) {
      setSelectedID(selected.current);
      return;
    }
    const element = pane.current;
    const id = selectedID ?? "empty";
    if (element) {
      restoreAnchor(
        element,
        anchors.current.get(id),
        active.current !== id || readingSize.current !== state.fontSize
      );
      active.current = id;
      readingSize.current = state.fontSize;
    }
    if (state.command && state.command.id > command.current) {
      command.current = state.command.id;
      if (
        !update.reconnect &&
        element &&
        state.command.answerID === selectedID
      ) {
        scrollPage(element, state.command.direction);
      }
    }
    save();
    update.applied(command.current);
  }, [update, state, selectedID, save]);
  useEffect(() => {
    let disposed = false;
    let lock: WakeLockSentinel | undefined;
    let requesting = false;
    const acquire = async () => {
      if (
        !keepAwake ||
        document.visibilityState !== "visible" ||
        !("wakeLock" in navigator) ||
        requesting ||
        (lock && !lock.released)
      ) {
        return;
      }
      requesting = true;
      try {
        const next = await navigator.wakeLock.request("screen");
        if (disposed) {
          await next.release();
        } else {
          lock = next;
        }
      } catch {
        /* Best effort when browser or battery policy denies it. */
      } finally {
        requesting = false;
      }
    };
    void acquire();
    const visibility = () => {
      void acquire();
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      disposed = true;
      document.removeEventListener("visibilitychange", visibility);
      void lock?.release();
    };
  }, [keepAwake]);

  if (!fragment) {
    return (
      <main className="viewer">
        <div className="reading welcome">
          <h1>Skill Issue</h1>
          <p>
            Open the private viewer link from your Mac, or scan its QR code.
          </p>
        </div>
      </main>
    );
  }
  const index = state.answers.findIndex((answer) => answer.id === selectedID);
  const card = state.answers[index];
  const answerLanguage = answerLanguages.find(
    (language) => language.name === state.language
  );
  const sessionEnded = status === "Session ended";
  const busy = card?.status === "generating" && !sessionEnded;
  const shownStatus = status === "Listening" && busy ? "Thinking…" : status;
  const answerPosition =
    index === -1 ? "Ready" : `${index + 1} / ${state.answers.length}`;
  const answerHeading = busy
    ? "Preparing your answer…"
    : "Press Space to request an answer.";
  const readingStyle: CSSProperties & { "--reading-size": string } = {
    "--reading-size": `${state.fontSize / 16}rem`,
  };
  return (
    <main className="viewer" style={readingStyle}>
      <div className="meta">
        <span className="position">{answerPosition}</span>
        <output className="status">
          <i className={status === "Listening" ? "live" : ""} />
          {shownStatus}
        </output>
      </div>
      <section
        className="reading"
        ref={pane}
        onScroll={save}
        tabIndex={0}
        aria-label="Answer"
      >
        {state.error && (
          <p className="error" role="alert" data-anchor="error">
            {failure}
          </p>
        )}
        <article className="answer" lang={answerLanguage?.tag} aria-busy={busy}>
          {card !== undefined && card.text !== "" ? (
            <Answer text={card.text} />
          ) : (
            <div className="empty" lang="en">
              <h1 data-anchor="empty-heading">
                {sessionEnded ? "Session ended." : answerHeading}
              </h1>
              <p data-anchor="empty-guide">
                {sessionEnded && restartGuide}
                {!sessionEnded &&
                  busy &&
                  "Keep listening. Your answer will appear here."}
                {!sessionEnded && !busy && (
                  <>
                    Hold <kbd>{state.modifiers}</kbd> and press <kbd>Space</kbd>{" "}
                    on your Mac.
                  </>
                )}
              </p>
            </div>
          )}
          {card?.status === "incomplete" && (
            <p className="error" lang="en" data-anchor="answer-note">
              Incomplete answer
            </p>
          )}
          {card?.status === "failed" && !state.error && (
            <p className="error" lang="en" data-anchor="error">
              {failure}
            </p>
          )}
        </article>
      </section>
      {!sessionEnded && (
        <footer className="hints">
          <span>
            Hold <kbd>{state.modifiers}</kbd>
          </span>
          <span>
            <kbd>Space</kbd> request answer
          </span>
          <span>
            <kbd>↑↓</kbd> read
          </span>
          <span>
            <kbd>←→</kbd> history
          </span>
          <span>
            <kbd>+/−</kbd> text size
          </span>
        </footer>
      )}
    </main>
  );
};
const root = document.querySelector("#root");
if (!root) {
  throw new Error("Missing viewer root element");
}
createRoot(root).render(<App />);
