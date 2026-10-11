# Skill Issue

[![CI](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml/badge.svg)](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml)

A macOS menu bar app that captures the main display, computer audio and microphone. Speech
recognition runs locally. Press **Control + Option + Command + Space** to get help with the current
question through your ChatGPT subscription. Read the answer on a private web page from your phone or
another device.

Click the menu bar icon to open or close Settings. The viewer shows one answer at a time; scrolling
and history navigation are controlled from the Mac.

## Run

Requires Apple Silicon, macOS 26+, full Xcode with the Metal Toolchain, and [Bun](https://bun.sh).
Use an Xcode toolchain satisfying `Package.swift` and the Bun version in `package.json`.

```sh
xcodebuild -downloadComponent metalToolchain
bun install --frozen-lockfile
bun run dev
```

In another terminal, build and launch the app:

```sh
bun run run:swift
```

In Settings, sign in with ChatGPT, choose your microphone and answer language, and leave Viewer on
**Answers**. Start a session and allow microphone and screen/system audio access. The model
downloads once into `~/Library/Application Support/Skill Issue/Models/`; first use needs internet
and about 643 MB of storage.

The default viewer server, `http://127.0.0.1:8787`, works on this Mac only. To read from a phone,
[deploy the viewer](#public-viewer), then open the session link or scan its QR code. Keep the
phone's browser foreground and unlocked; Screen Wake Lock is best effort.

Settings are locked while listening. **Transcript preview** is a diagnostic mode selected before
starting a session. Answer language defaults to English and is independent of speech recognition;
choices live in `native/Resources/answer-languages.json`.

## During a session

Hold **Control + Option + Command** for all commands:

| Key   | Action                                                       |
| ----- | ------------------------------------------------------------ |
| Space | Answer the current question                                  |
| ↑ / ↓ | Scroll by half the viewer's visible height                   |
| ← / → | Previous / next answer, restoring its reading position       |
| + / − | Increase / decrease text size, keeping your reading position |
| H     | Hide / show the app's menu bar icon                          |

Text size starts at 20, changes by 2 between 16 and 40, and is saved across app restarts. The +/=
key works with or without Shift. Streaming and reconnects preserve your selected answer and reading
position. Pressing Answer again cancels the current generation and captures fresh context; its
partial answer remains in history. Holding Space does not repeat requests.

H hides only this app's icon; macOS capture indicators remain visible. Reopen the app to show
Settings if its icon is hidden.

## Public viewer

```sh
bunx wrangler login
bun run deploy
```

Set **Viewer server** to the printed HTTPS URL and start a new session. The Cloudflare Worker serves
the viewer and encrypted relay. No tunnels or open ports are required on your Mac; Cloudflare's
account limits apply.

## Data and privacy

- ChatGPT credentials stay in the Mac's Keychain. Requests go directly to OpenAI using your
  subscription with `store: false`. Model availability and limits depend on
  [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source).
- Each Answer captures a screenshot and finalizes a batch of captured audio. Chronological
  transcripts, screenshots and earlier AI suggestions form the request history. Viewing an old
  answer does not change that context. Audio is not uploaded.
- One local Nemotron ASR model serves separate computer and microphone streams. These are audio
  sources, not verified speaker identities. English and Russian were checked; other languages have
  not been evaluated here.
- History stays in memory, including after request errors. There is no automatic truncation; long
  sessions can reach the model's context limit. The app does not save recordings or screenshots to
  disk. Model assets remain cached.
- Viewer snapshots use AES-256-GCM; the key stays in the link's URL fragment. The relay stores
  encrypted state. Readers cannot publish state or control the Mac. Anyone with the full link can
  read the session, and the link remains in browser history.
- Stop, Quit and fatal session errors stop capture and request room deletion. Failed deletion shows
  an error; an abandoned room expires after two hours without publisher activity. Active sessions
  renew it. The browser stores reading positions, not answer text. There are no analytics or
  third-party page assets.

## Development

Install [Homebrew](https://brew.sh), then run:

```sh
bun setup:swift
bun check
bun check:fix
```

The pre-commit hook runs `check:fix`; commit messages use Conventional Commits. `lint:fix` formats
without tests. Swift uses `swift format`, SwiftLint and compiler warnings as errors. Web code uses
Ultracite/Oxlint/Oxfmt, type-aware linting, TypeScript, Stylelint and Knip. Shell scripts use shfmt
and ShellCheck.

| Command                 | Purpose                                                   |
| ----------------------- | --------------------------------------------------------- |
| `bun check:web`         | Web/relay lint, types, unit coverage and Chromium tests   |
| `bun check:swift`       | Swift lint, coverage, unused-code analysis and native E2E |
| `bun test:sanitize`     | Swift tests with Thread Sanitizer                         |
| `bun run build:swift`   | Package `dist/debug/Skill Issue.app`                      |
| `bun run build:release` | Package `dist/release/Skill Issue.app`                    |
| `bun run run:swift`     | Build and launch the debug app                            |

Integration tests run against a disposable local Worker without ChatGPT credentials or capture
permissions. CI runs the same web, Swift and sanitizer gates. Coverage reports go into `coverage/`.
Builds include dependency license notices. Packaging commands do not launch the app; the launch
command waits for a running session to stop before replacing its bundle.

For VS Code debugging, launch with `bun run run:swift`, then select **Attach to Skill Issue** and
choose the running `SkillIssue` process.

The optional real-model test needs WAV clips of at most 12 seconds: `en_constraints.wav` containing
"do not sort" and "not the values", and `ru_constraints.wav` containing "сортировать нельзя" and "а
не сами значения". Clips are resampled to 16 kHz:

```sh
SKILL_ISSUE_ASR_CHECK_DIR=/path/to/fixtures bun test:asr
```

The speech library and model are pinned; updates require real-model validation. Model updates must
also update manifest sizes and hashes and [THIRD_PARTY.md](THIRD_PARTY.md). Renovate updates Bun
dependencies, JOSESwift and GitHub Actions. A real ChatGPT call and physical-phone Safari test
remain necessary before relying on the app.

Local bundles are ad hoc signed; Developer ID signing and notarization are not configured.
Rebuilding can require Keychain and screen approval again. If screen access remains denied, remove
its old entry in **System Settings > Privacy & Security > Screen & System Audio Recording**, add the
current app bundle, then quit and reopen.

If a build cannot find Metal after a reboot, run `swift package clean` and retry; see the
[upstream cache issue](https://github.com/swiftlang/swift-build/issues/1798).

MIT licensed. See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency and model licenses.
