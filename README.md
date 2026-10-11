# Skill Issue 🐢

[![CI](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml/badge.svg)](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml)

A macOS menu bar app for interview assistance. It transcribes computer audio and your microphone
locally. On request, it uses your ChatGPT subscription to answer the current question with context
from the main display. Read answers on your phone through an encrypted web viewer and control it
from your Mac.

Skill Issue is deliberately opinionated and simple, with a small set of controls and predictable
defaults to keep it **easy to use under interview stress**.

[Install](#install) | [Viewer endpoint](#viewer-endpoint) | [Usage](#usage) |
[Data and privacy](#data-and-privacy) | [Development](#development)

## Install

Requires Apple Silicon and macOS 26+. For a source build, see [Development](#development).

1. Sign in to GitHub and open a successful main-branch run in
   [Actions](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml?query=branch%3Amain).
2. Download `Skill-Issue-macos-arm64.zip` from **Artifacts**, extract it, and move `Skill Issue.app`
   to Applications. Artifacts expire according to the repository's retention settings.
3. Open the app. It lives in the menu bar; click its icon to open or close Settings.

The app is ad hoc signed without an Apple developer certificate and is not notarized. If macOS
blocks it, use **System Settings > Privacy & Security > Open Anyway** after attempting to open it;
see [Apple's instructions](https://support.apple.com/en-us/102445).

Alternatively, remove the quarantine attribute from the downloaded app in Terminal, then open it
again:

```sh
xattr -dr com.apple.quarantine "/Applications/Skill Issue.app"
```

This removes only the quarantine attribute and preserves other extended attributes.

## Viewer endpoint

To read answers on your phone, deploy the viewer and relay to your own Cloudflare account. Its usage
limits and billing apply. The server needs no ChatGPT credentials, tunnels or open ports on your
Mac.

Room creation is currently public and IP-rate-limited. Encryption protects existing sessions, but
anyone who can reach the server can create their own rooms. Private server access is tracked in
[#9](https://github.com/hu553in/skill-issue/issues/9).

### Deploy to Cloudflare

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/hu553in/skill-issue)

Sign in to GitHub and Cloudflare and authorize the repository connection. Cloudflare copies this
repository into your GitHub account and configures the relay's Durable Object storage from
`wrangler.jsonc`.

Use these build settings:

| Setting                      | Value                                                         |
| ---------------------------- | ------------------------------------------------------------- |
| Root directory               | Repository root                                               |
| Build command                | Leave empty                                                   |
| Deploy command               | `bun deploy`                                                  |
| Preview builds               | Disabled                                                      |
| Preview command              | `true` if the dashboard requires a value                      |
| Build variable `BUN_VERSION` | The version after `bun@` in `package.json`'s `packageManager` |

`bun deploy` builds the web assets before publishing the Worker. Clear the automatically detected
Build command because `build` also compiles the macOS app and requires Xcode. Keep preview builds
disabled; `true` exits without deploying. See Cloudflare's
[build settings](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/).

### Deploy from a checkout

With [Bun](https://bun.sh) installed at the version declared in `package.json`, run:

```sh
bun install --frozen-lockfile
bunx wrangler login
bun deploy
```

## Usage

1. Open Settings, sign in with ChatGPT, and choose your microphone and answer language.
2. Set **Viewer endpoint** to your Worker's HTTPS URL from the Cloudflare dashboard or terminal
   output. The default `http://127.0.0.1:8787` works only on this Mac and is intended for
   [local development](#run-locally).
3. Start a session and allow microphone and screen/system audio access. On first use, the app
   downloads about 642 MB of speech-model files.
4. Open the session link on your phone or scan its QR code. Keep the browser in the foreground and
   the phone unlocked; Screen Wake Lock is best effort.

Setup fields are locked while listening. Answer language defaults to English and is independent of
speech recognition.

**Model** and **Reasoning effort** load from your ChatGPT account after sign-in. The default model
is `gpt-6-luna`, or the first available model; effort defaults to `low`, or the first supported
level. Choices are saved between launches. Changing the model resets effort to its default. Both
selectors stay disabled until choices load; if the catalog supplies no supported effort levels, the
effort selector stays disabled and the app omits that parameter from requests.

The status badge is beside the app title; errors appear below it. A failed model-catalog load offers
**Retry** there. **Quit** and **Command + Q** ask for confirmation before stopping the session and
closing the app. **Cancel** keeps the app and session running.

### Keyboard shortcuts

Hold **Control + Option + Command** for all commands:

| Key   | Action                                                       |
| ----- | ------------------------------------------------------------ |
| Space | Request an answer to the current question                    |
| ↑ / ↓ | Scroll by half the viewer's visible height                   |
| ← / → | Previous / next answer, restoring its reading position       |
| + / − | Increase / decrease text size, keeping your reading position |
| H     | Hide / show the app's menu bar icon                          |

The viewer shows one answer at a time. Streaming and reconnects preserve your selected answer and
reading position. Pressing Space again cancels the current generation and captures fresh context;
its partial answer remains in history. Holding Space does not repeat requests.

Text size starts at 20, changes by 2 between 16 and 40, and is saved across app restarts. The +/=
key works with or without Shift. H hides only this app's icon; macOS capture indicators remain
visible. Reopen the app to show Settings if its icon is hidden.

## Data and privacy

- ChatGPT credentials stay in the Mac's Keychain. Requests go directly to OpenAI using your
  subscription with `store: false`. Model availability and limits depend on
  [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source).
- Each answer request captures a screenshot and finalizes a batch of captured audio. Chronological
  transcripts, screenshots and earlier AI suggestions form the request history. Viewing an old
  answer does not change that context. Audio is not uploaded.
- One local Nemotron ASR model serves separate computer and microphone streams. These are audio
  sources, not verified speaker identities. English and Russian were checked; other languages have
  not been evaluated here.
- History stays in memory, including after request errors. There is no automatic truncation; long
  sessions can reach the model's context limit. The app does not save recordings or screenshots to
  disk. Model files remain cached in `~/Library/Application Support/Skill Issue/Models/`.
- Viewer snapshots use AES-256-GCM; the key stays in the link's URL fragment. The relay stores
  encrypted state. Readers cannot publish state or control the Mac. Anyone with the full link can
  read the session, and the link remains in browser history.
- Stop, Quit and fatal session errors stop capture and request room deletion. Failed deletion shows
  an error; an abandoned room expires after two hours without publisher activity. Active sessions
  renew it. The browser stores reading positions, not answer text. There are no analytics or
  third-party page assets.

## Development

### Setup

Use full Xcode with a Swift toolchain satisfying [Package.swift](Package.swift),
[Bun](https://bun.sh) at the version in [package.json](package.json), and
[Homebrew](https://brew.sh) for SwiftLint and shfmt. Run from a checkout:

```sh
xcodebuild -downloadComponent metalToolchain
bun install --frozen-lockfile
bun setup:swift
```

### Run locally

Start the local viewer server:

```sh
bun dev
```

In another terminal, build and launch the app:

```sh
bun run:swift
```

Use `http://127.0.0.1:8787` as **Viewer endpoint**. The launch command waits for a running session
to stop before replacing its debug bundle. For VS Code debugging, select **Attach to Skill Issue**
and choose the running `SkillIssue` process.

### Build and package

```sh
bun build:release
```

This creates `dist/release/Skill Issue.app` and `dist/Skill-Issue-macos-arm64.zip`. CI runs the same
command as part of the Swift checks and uploads the ZIP after they pass. For a debug bundle, use
`bun build:swift`; its output is `dist/debug/Skill Issue.app`. Both packaging commands include
dependency license notices and do not launch the app.

### Checks

Swift uses `swift format`, SwiftLint and compiler warnings as errors. Web code uses
Ultracite/Oxlint/Oxfmt, type-aware linting, TypeScript, Stylelint and Knip. Oxfmt also formats
Markdown and configuration files. Shell scripts use shfmt and ShellCheck.

| Command             | Purpose                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------ |
| `bun lint`          | Check formatting and lint without tests                                                    |
| `bun lint:fix`      | Format and apply lint fixes without tests                                                  |
| `bun check`         | Run the web and Swift checks                                                               |
| `bun check:fix`     | Format, apply lint fixes and run `check`                                                   |
| `bun check:web`     | Web/relay lint, types, config checks, dependency audit, coverage and Chromium tests        |
| `bun check:swift`   | Swift lint, coverage, unused-code analysis, Release packaging and native relay integration |
| `bun test:sanitize` | Run Swift tests with Thread Sanitizer                                                      |

The pre-commit hook runs `check:fix`; commit messages use Conventional Commits. CI runs the web,
Swift and sanitizer checks. Integration tests use a disposable local Worker without ChatGPT
credentials or capture permissions. Native integration checks CryptoKit/WebCrypto interoperability
through the relay. Automated tests do not exercise real capture, a live ChatGPT account or
physical-phone Safari. Coverage reports go into `coverage/`.

### Speech-model validation

The optional real-model test needs WAV clips of at most 12 seconds: `en_constraints.wav` containing
"do not sort" and "not the values", and `ru_constraints.wav` containing "сортировать нельзя" and "а
не сами значения". Clips are resampled to 16 kHz:

```sh
SKILL_ISSUE_ASR_CHECK_DIR=/path/to/fixtures bun test:asr
```

The speech library and model are pinned; updates require real-model validation. Model updates must
also update manifest sizes and hashes and [THIRD_PARTY.md](THIRD_PARTY.md). Renovate updates Bun
dependencies, JOSESwift and GitHub Actions.

### Troubleshooting

To inspect app output or unified system logs, run one of these commands:

```sh
bun run:swift --logs
bun run:swift --telemetry
```

Both rebuild and relaunch the debug app. `--logs` follows stdout/stderr in `dist/app.log`;
`--telemetry` follows system logs for the app's subsystem. Use `--debug` to start under LLDB or
`--verify` to launch and check that the process is running.

Rebuilding an ad hoc signed app can require Keychain and screen approval again. If screen access
remains denied, remove its old entry in **System Settings > Privacy & Security > Screen & System
Audio Recording**, add the current app bundle, then quit and reopen.

If a build cannot find Metal after a reboot, run `swift package clean` and retry; see the
[upstream cache issue](https://github.com/swiftlang/swift-build/issues/1798).

## License

[MIT](LICENSE). See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency and model licenses.
