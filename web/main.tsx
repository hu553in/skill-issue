import ReconnectingWebSocket from "partysocket/ws";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import type { CSSProperties, ReactNode } from "react";
import { createRoot } from "react-dom/client";

import answerLanguages from "../native/Resources/answer-languages.json";
import { parseViewerMessage } from "../protocol";
import type { ViewState } from "../protocol";
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

import "./style.css";

interface Update {
  state: ViewState;
  reconnect: boolean;
  applied: (command: number) => void;
}
const restartGuide =
  "Start a new session on your Mac and open its viewer link.";
const connectionGuide =
  "Reload this viewer, or reopen it from Skill Issue on your Mac.";
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
    let socket: ReconnectingWebSocket | undefined;
    let disposed = false;
    let ended = false;
    let established = false;
    let generation = 0;
    let highest = 0;
    let started = Date.now();
    let lastReceived = started;
    async function connect() {
      try {
        const { room, token, key: rawKey } = parseLink(fragment);
        const key = await crypto.subtle.importKey(
          "raw",
          unbase64(rawKey),
          "AES-GCM",
          false,
          ["decrypt", "encrypt"]
        );
        if (disposed || ended) {
          return;
        }
        const url = new URL(`/rooms/${room}/socket`, location.origin);
        url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
        const ws = new ReconnectingWebSocket(
          url.href,
          ["skill-issue", `skill-issue.reader.${token}`],
          {
            maxEnqueuedMessages: 0,
            minReconnectionDelay: 1500,
            shouldReconnectOnClose: (event) =>
              !disposed && !ended && event.code !== 1008,
          }
        );
        socket = ws;
        let queue = Promise.resolve();
        let client = "";
        let first = true;
        ws.addEventListener("open", () => {
          generation += 1;
          queue = Promise.resolve();
          client = "";
          first = true;
          lastReceived = Date.now();
        });
        ws.addEventListener("message", (event: MessageEvent<unknown>) => {
          if (disposed || ended) {
            return;
          }
          const run = generation;
          lastReceived = Date.now();
          let packet: ReturnType<typeof parseViewerMessage>;
          try {
            if (typeof event.data !== "string") {
              throw new TypeError(failure);
            }
            packet = parseViewerMessage(JSON.parse(event.data));
            if (packet?.type === "ended") {
              // Close the transport while retaining final snapshots already in the queue.
              ended = true;
              setStatus("Session ended");
              ws.close();
              return;
            }
          } catch {
            generation += 1;
            ended = true;
            setStatus(failure);
            ws.close();
            return;
          }
          if (!packet) {
            return;
          }
          queue = queue
            .then(async () => {
              if (disposed || run !== generation) {
                return;
              }
              if (packet.type === "ready") {
                ({ client } = packet);
                established = true;
                if (!ended && ws.readyState === WebSocket.OPEN) {
                  setStatus("Connected");
                }
                return;
              }
              if (packet.type === "offline") {
                if (!ended && ws.readyState === WebSocket.OPEN) {
                  setStatus("Mac disconnected");
                }
                return;
              }
              if (packet.type !== "state") {
                return;
              }
              const { seq } = packet;
              if (seq < highest) {
                return;
              }
              const next = await decrypt(key, room, packet);
              if (disposed || run !== generation) {
                return;
              }
              const reconnect = first;
              first = false;
              highest = seq;
              save();
              await new Promise<void>((resolve) => {
                setUpdate({
                  applied: (appliedCommand) => {
                    if (disposed || ended || run !== generation) {
                      resolve();
                      return;
                    }
                    void acknowledgment(key, room, client, seq, appliedCommand)
                      .then((ack) => {
                        if (
                          !disposed &&
                          !ended &&
                          run === generation &&
                          ws.readyState === WebSocket.OPEN
                        ) {
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
                !ended &&
                run === generation &&
                ws.readyState === WebSocket.OPEN
              ) {
                setStatus(next.live ? "Listening" : "Connected");
              }
            })
            .catch(() => {
              if (!disposed && !ended && run === generation) {
                generation += 1;
                ended = true;
                setStatus(failure);
                ws.close();
              }
            });
        });
        ws.addEventListener("close", (event) => {
          if (disposed || ended) {
            return;
          }
          generation += 1;
          if (event.code === 1008) {
            ended = true;
            setStatus(failure);
            return;
          }
          if (established) {
            established = false;
            started = Date.now();
          }
          setStatus("Reconnecting…");
        });
      } catch {
        if (!disposed) {
          ended = true;
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
        Date.now() - (established ? lastReceived : started) > 35_000
      ) {
        if (established) {
          socket?.reconnect();
        } else {
          // Rejected upgrades expose no HTTP status to the browser. Bound each
          // establishment without assuming why it failed or admitting a socket.
          generation += 1;
          ended = true;
          setStatus(failure);
          socket?.close();
        }
      }
    }, 10_000);
    const visibility = () => {
      if (
        document.visibilityState === "visible" &&
        !ended &&
        socket?.readyState === WebSocket.CLOSED
      ) {
        socket.reconnect();
      }
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      disposed = true;
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
  const viewerFailed = status === failure;
  const listening = status === "Listening";
  const generating =
    listening && state.answers.some((answer) => answer.status === "generating");
  const busy = listening && card?.status === "generating";
  const shownStatus = generating ? "Thinking…" : status;
  const answerPosition =
    index === -1 ? "No answers yet" : `${index + 1} / ${state.answers.length}`;
  const canRequest = state.canAnswer && listening;
  let answerHeading = "Waiting for your Mac.";
  let answerGuide: ReactNode =
    "Your viewer will update when your Mac is ready.";
  if (sessionEnded) {
    answerHeading = "Session ended.";
    answerGuide = restartGuide;
  } else if (viewerFailed) {
    answerHeading = "Couldn't open this viewer.";
    answerGuide = connectionGuide;
  } else if (status === "Mac disconnected") {
    answerHeading = "Mac disconnected.";
    answerGuide =
      "Keep Skill Issue open on your Mac. The viewer will reconnect automatically.";
  } else if (status === "Connecting…" || status === "Reconnecting…") {
    answerHeading = status;
    answerGuide = "Waiting for the viewer connection.";
  } else if (busy) {
    answerHeading = "Preparing your answer…";
    answerGuide = "Keep listening. Your answer will appear here.";
  } else if (canRequest) {
    answerHeading = "Press Space to request an answer.";
    answerGuide = (
      <>
        Hold <kbd>{state.modifiers}</kbd> and press <kbd>Space</kbd> on your
        Mac.
      </>
    );
  } else if (state.error) {
    answerHeading = "Check your Mac to continue.";
    answerGuide = "Open Settings in Skill Issue for the error and next steps.";
  }
  const readingStyle: CSSProperties & { "--reading-size": string } = {
    "--reading-size": `${state.fontSize / 16}rem`,
  };
  return (
    <main className="viewer" style={readingStyle}>
      <div className="meta">
        <span className="position">{answerPosition}</span>
        <output className="status">
          <i className={listening ? "live" : ""} />
          {shownStatus}
        </output>
      </div>
      {viewerFailed && card !== undefined && card.text !== "" && (
        <p className="error connection-error" role="alert">
          The viewer connection stopped. {connectionGuide}
        </p>
      )}
      <section
        className="reading"
        ref={pane}
        onScroll={save}
        tabIndex={0}
        aria-label="Answer"
      >
        {state.error && !viewerFailed && (
          <p className="error" role="alert" data-anchor="error">
            Could not complete the request.{" "}
            {canRequest
              ? "Check the error in Settings on your Mac, then request another answer."
              : "Check Settings on your Mac to continue."}
          </p>
        )}
        <article className="answer" lang={answerLanguage?.tag} aria-busy={busy}>
          {card !== undefined && card.text !== "" ? (
            <Answer text={card.text} />
          ) : (
            <div className="empty" lang="en">
              <h1 data-anchor="empty-heading">{answerHeading}</h1>
              <p data-anchor="empty-guide">{answerGuide}</p>
            </div>
          )}
          {(card?.status === "incomplete" ||
            (card?.status === "generating" && sessionEnded)) && (
            <p className="error" lang="en" data-anchor="answer-note">
              Incomplete answer
            </p>
          )}
          {card?.status === "failed" && !state.error && !viewerFailed && (
            <p className="error" lang="en" data-anchor="error">
              {failure}
            </p>
          )}
        </article>
      </section>
      {!sessionEnded && !viewerFailed && (
        <footer className="hints">
          <span>
            Hold <kbd>{state.modifiers}</kbd>
          </span>
          {canRequest && (
            <span>
              <kbd>Space</kbd> request answer
            </span>
          )}
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
