# Skill Issue 🐢

[![CI](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml/badge.svg)](https://github.com/hu553in/skill-issue/actions/workflows/ci.yml)

A macOS menu bar interview assistant that transcribes computer audio and your microphone locally.
Request answers through your ChatGPT subscription, using the conversation and a screenshot of your
main display as context. Read answers on your phone and control the encrypted viewer from your Mac.

Skill Issue is opinionated and simple, with few controls and predictable defaults to keep it **easy
to use under interview stress**.

[Install](#install) | [Viewer endpoint](#viewer-endpoint) | [Usage](#usage) |
[Recovery](#recovery) | [Data and privacy](#data-and-privacy) | [Development](#development)

## Install

Requires Apple Silicon and macOS 26+. For a source build, see [Development](#development).

Install with [Homebrew](https://brew.sh). If switching from a manual installation, quit the app and
remove its old copy from Applications first:

```sh
brew install --cask hu553in/tap/skill-issue
```

Alternatively, download `Skill-Issue-macos-arm64.zip` from
[Releases](https://github.com/hu553in/skill-issue/releases), extract it, and move `Skill Issue.app`
to Applications.

Open the app. It lives in the menu bar; click its icon to open or close Settings.

The app is ad hoc signed without an Apple developer certificate and is not notarized. If macOS
blocks it, use **System Settings > Privacy & Security > Open Anyway** after attempting to open it;
see [Apple's instructions](https://support.apple.com/en-us/102445).

<details>
<summary>Remove the download quarantine in Terminal</summary>

Run the command below, then open the app again:

```sh
xattr -dr com.apple.quarantine "/Applications/Skill Issue.app"
```

This removes only the quarantine attribute and preserves other extended attributes.

</details>

### Update and uninstall

Stop the session and quit the app before updating or uninstalling. When updating, deploy the
[Worker](#viewer-endpoint) from the same release tag before starting a new session.

To update:

```sh
brew update
brew upgrade --cask hu553in/tap/skill-issue
```

For a manual installation, replace the app with the ZIP from the new release.

To uninstall:

```sh
brew uninstall --cask hu553in/tap/skill-issue
```

## Viewer endpoint

**Deploy the viewer and relay to your own Cloudflare account.** Its limits and billing apply. The
server needs no ChatGPT credentials, tunnels or open ports on your Mac.

For a released app, [deploy from a checkout](#deploy-from-a-checkout) using the same release tag.
Disable automatic Cloudflare builds from `main` so later pushes cannot replace that Worker with a
newer version. The button below deploys `main`; use it with an app built from the same commit.

Cloudflare Access is optional. Without it, anyone can create rooms and use your deployment's
resources, subject to IP rate limits. Sessions remain encrypted. Follow
[Cloudflare Access](#cloudflare-access) to restrict the deployment to your Mac and approved browser
users.

### Deploy to Cloudflare

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/hu553in/skill-issue)

Sign in to GitHub and Cloudflare and authorize the repository connection. Cloudflare copies this
repository into your GitHub account and configures the relay's Durable Object storage from
`wrangler.jsonc`.

Use these build settings:

| Setting                      | Value                                                           |
| ---------------------------- | --------------------------------------------------------------- |
| Root directory               | Repository root                                                 |
| Build command                | Leave empty                                                     |
| Deploy command               | `bun deploy`                                                    |
| Builds for Preview branches  | Off                                                             |
| Preview command              | Leave Cloudflare's default; unused while preview builds are off |
| Build variable `BUN_VERSION` | The version after `bun@` in `package.json`'s `packageManager`   |

`bun deploy` builds the web assets before publishing the Worker. Clear the automatically detected
Build command because `build` also compiles the macOS app and requires Xcode.

For an existing Worker, these settings are under **Settings > Builds**. Use the **Production** tab
for build/deploy commands and `BUN_VERSION`. In **Previews Base**, turn **Builds for Preview
branches** off. Production-branch pushes still deploy automatically.

### Deploy from a checkout

Use a checkout matching your installed app. For a released app, check out its release tag first.
With [Bun](https://bun.sh) at the version declared in that checkout's `package.json`, run:

```sh
bun ci
bunx wrangler login
bun deploy
```

### Cloudflare Access

After deploying the Worker, create **one Access application with two separate policies**: email
sign-in for the browser and a service token for the Mac.

#### 1. Enable email sign-in

Open **Zero Trust** in your Cloudflare account and complete its initial setup if needed.

Open
[Identity providers](https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fone%2Fintegrations%2Fidentity-providers)
under **Integrations**. If **One-time PIN** is missing, select **Add an identity provider > One-time
PIN** and save. This enables login codes by email.

#### 2. Create the Mac's service token

Open
[Service Tokens](https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fone%2Faccess-controls%2Fservice-credentials%2Fservice-tokens)
under **Access controls > Service credentials**.

1. Select **Create Service Token**.
2. Set **Service token name** to `Skill Issue Mac`; leave the default duration.
3. Select **Generate token** and copy **Client ID** and **Client Secret** for Configure in Skill
   Issue.

**Copy both now: the secret is shown only once.**

#### 3. Protect the viewer hostname

Open [Applications](https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fone%2Faccess-controls%2Fapps)
under **Access controls**. Select **Create new application > Self-hosted and private > Public DNS >
Continue with Self-hosted and private**. To update an existing application, open its name instead.

In **Destinations > Public hostnames**, select **Switch to custom input** and enter the complete
hostname, for example `skill-issue.example.workers.dev`. **Do not include `https://` or a path.**
Under **Details**, set **Name** to `Skill Issue`. A custom domain is optional.

**Use Public hostnames, not Add Workers or Worker Access.**

In **Access policies**, use **Create new policy** twice:

| Policy Name           | Action           | Include rule                                 |
| --------------------- | ---------------- | -------------------------------------------- |
| `Skill Issue browser` | **Allow**        | **Emails** > each email you allow to sign in |
| `Skill Issue Mac`     | **Service Auth** | **Service Token** > `Skill Issue Mac`        |

Select **Save policy** after each one. Leave the optional policy settings at their defaults; the MFA
override stays off. **Both policies must appear in this application's Access policies list.** For
existing policies, use **Add existing policy** instead of creating duplicates.

Under **Authentication > Identity**, turn **Accept all available identity providers** off and choose
**One-time PIN**. Finish with **Create**, or **Save** for an existing application.

#### 4. Check the Worker's other addresses

Open [Workers & Pages](https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fworkers-and-pages), then your
Worker.

- **Domains > Worker URL > Production:** keep it on if this protected `workers.dev` address is your
  viewer endpoint.
- **Domains > Worker URL > Preview:** keep it off. The project's `preview_urls: false` preserves
  this on later deploys.
- **Settings > Builds > Previews Base > Builds for Preview branches:** keep it off. This does not
  disable production-branch deploys.

<details>
<summary>If you use a custom domain or additional routes</summary>

Access protection applies to the hostname you entered, not every address of the same Worker. Check
**Custom Domains and Routes** in the Worker's **Domains** tab. Add each additional hostname under
**Destinations > Public hostnames** in the same Access application, or remove the unused route.

If you use only a custom domain, turn **Worker URL > Production** off to disable `workers.dev`. Also
add `"workers_dev": false` to your checkout's `wrangler.jsonc`; otherwise a later deploy can enable
it again. Keep **Preview** off separately.

</details>

#### 5. Connect the Mac and phone

1. In Skill Issue Settings, set **Viewer endpoint** to the protected HTTPS address. Turn **Use
   Cloudflare Access** on, open **Configure**, paste the token's **Client ID** and **Client
   secret**, then **Save**.
2. On your phone, open the endpoint without a session link and sign in with an allowed email.
3. Start a session on the Mac, then open its full link or scan its QR code on the phone.

If Cloudflare sign-in returns you to a page asking for the private viewer link, reopen that same
link or scan the QR code again. Cloudflare can drop the private part of the link during the first
login.

<details>
<summary>Access settings and recovery</summary>

| What you see              | What to do                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------- |
| **Setup required** on Mac | Open **Configure** and save the service token before starting a session.                          |
| Access denied on Mac      | Check the token's expiry and Service Auth policy, update **Configure**, then start a new session. |
| **Sign in** in the viewer | Sign in again; reopen the session link if needed. The Mac's session continues.                    |
| Temporary connection loss | Wait for automatic reconnection.                                                                  |

- An Access refusal stops the Mac's session; existing answers remain until the next Start. An
  already open WebSocket checks Access again only when it reconnects.
- If you lose the Client Secret,
  [rotate it in Cloudflare](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/#rotate-service-token-secrets)
  and update **Configure**.
- Turning **Use Cloudflare Access** off keeps the credentials but stops sending them. It does not
  remove the protection in Cloudflare. The app never falls back to unprotected requests
  automatically.
- Credentials stay in Keychain for the configured origin. Another endpoint never receives them; they
  are not included in viewer links or QR codes.
- Access settings are locked during sessions and operations. For local development, leave Access
  off; HTTP is accepted only for loopback addresses.

</details>

## Usage

1. Open Settings, sign in with ChatGPT, and choose your microphone and answer language.
2. Set **Viewer endpoint** to your Worker's HTTPS URL from the Cloudflare dashboard or terminal
   output. The default `http://127.0.0.1:8787` works only on this Mac and is intended for
   [local development](#run-locally).
3. Start a session and allow microphone and screen/system audio access. On first use, the app
   downloads about 642 MB of speech-model files.
4. Open the session link on your phone or scan its QR code. Keep the browser in the foreground and
   the phone unlocked.

### Settings

- **Model and Reasoning effort** load after ChatGPT sign-in. You can change them between requests.
  Both stay disabled while choices load or an answer is being prepared or generated.
- **Microphone, Answer language, Viewer endpoint and Cloudflare Access** are locked during sessions
  and operations.
- **Answer language** defaults to English and is independent of speech recognition.

<details>
<summary>Model defaults and saved choices</summary>

- The default model is `gpt-6-luna`, or the first available model.
- Reasoning effort defaults to `low`, or the first supported level. If none are available, the
  selector stays disabled.
- Model and effort choices survive app restarts. Changing the model resets effort to its default.

</details>

### ChatGPT accounts

When signed out, choose **Sign in with ChatGPT** if no accounts are saved. Otherwise, select an
**Account** or **Another account**, then choose **Sign in**. Selecting an account does not start
sign-in.

To switch accounts, **Sign out** first. Local tokens are removed and account registrations stay
saved for repeat sign-in. If OpenAI cannot confirm remote sign-out, use
[account recovery](#account-and-keychain-problems) to disconnect it.

### Keyboard shortcuts

Hold **Control + Option + Command** for all commands. To use other modifier keys, stop the session
and choose **Change…** next to **Controls**. Pick at least two keys; the choice survives app
restarts and updates every shortcut hint, including the viewer.

| Key   | Action                                                       |
| ----- | ------------------------------------------------------------ |
| Space | Request an answer to the current question                    |
| ↑ / ↓ | Scroll by half the viewer's visible height                   |
| ← / → | Previous / next answer, restoring its reading position       |
| + / − | Increase / decrease text size, keeping your reading position |
| H     | Hide / show the app's menu bar icon                          |

The viewer shows one answer at a time. Streaming and reconnects preserve your selection and reading
position. **Thinking** refers to the current request, including when you read an earlier answer.

- **Request again:** Space cancels the current generation and captures fresh context. Its partial
  answer stays in history. Holding Space does not repeat requests.
- **Text size:** starts at 20, changes by 2 from 16 to 40, and survives app restarts. The +/= key
  also accepts an extra Shift when Shift is not part of your chosen modifiers.
- **Hide the icon:** H hides the app's icon; macOS capture indicators remain visible. Reopen the app
  to show Settings when the icon is hidden.
- **Quit:** the button and Command + Q ask for confirmation. Cancel keeps the session running.

**Starting a new session clears the previous session's answers and captured context.**

## Recovery

Answer requests never retry automatically. Existing answers and captured context remain available
during recovery, until you start a new session.

| Problem                          | What to do                                                                    |
| -------------------------------- | ----------------------------------------------------------------------------- |
| Temporary answer failure         | Choose **Retry** or **Request answer**, as offered.                           |
| ChatGPT usage limit              | Open **View usage**, check your app and plan limits, then **Request answer**. |
| Usage limit while loading models | Open **View usage**, check your limits, then **Retry** to reload models.      |
| Viewer connection stopped        | Reload the viewer or reopen the current link from the Mac.                    |

Temporary viewer interruptions reconnect automatically. For Cloudflare sign-in or service-token
errors, see [Access recovery](#cloudflare-access).

### Account and Keychain problems

- **Plan permission missing:** choose **Enable ChatGPT plan usage**. If ChatGPT requires sign-in or
  renewed permission during a session, the session stops and shows the recovery action.
- **Saved accounts unavailable:** choose **Retry** before signing in. Saved registrations stay
  intact.
- **Credentials could not be saved:** restore Keychain access, then choose **Retry**. It saves the
  credentials without requesting another answer. Your session and answers stay available; quitting
  before the save succeeds may require signing in again.
- **Remote sign-out unconfirmed:** choose **Open ChatGPT**, then **Settings > Security and login >
  Sign in with ChatGPT > Skill Issue > Disconnect**.

## Data and privacy

### On your Mac

- Audio is transcribed locally by Nemotron and is not uploaded. Computer audio and microphone are
  separate sources, not verified speaker identities. English and Russian were checked; other
  languages have not been evaluated here.
- History stays in memory, including after request errors. Recordings and screenshots are not saved
  to disk. History is not truncated automatically, so long sessions can fill the model's context
  window.
- Model files are cached in `~/Library/Application Support/Skill Issue/Models/`.
- ChatGPT tokens, verified account registrations and Access service credentials stay in Keychain.

### Sent to OpenAI

The app sends chronological transcripts, screenshots and earlier AI suggestions directly to OpenAI.
Each answer request adds a screenshot and the latest transcripts. Reading an old answer does not
change that context.

Requests use your ChatGPT subscription with `store: false`. Model availability and limits depend on
[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source).

### Stored by the viewer and relay

- The relay stores AES-256-GCM encrypted state. The decryption key is in the link's URL fragment and
  is never sent to the relay. Readers cannot publish state or control the Mac.
- **Anyone with the full link can read the session**, unless Cloudflare Access restricts browser
  access. The link remains in browser history.
- The browser saves reading positions, not answer text. During Access sign-in, the tab temporarily
  saves the private viewer link to restore it after login.
- Stop, Quit and fatal session errors stop capture and request room deletion. Failed deletion shows
  an error. Abandoned rooms expire after two hours without publisher activity; active sessions renew
  them.

Access credentials are sent only to their configured origin, using HTTPS or loopback HTTP, with
redirects blocked. They are not included in session links or QR codes. The viewer has no analytics
or third-party page assets.

## Development

### Setup

Use full Xcode with a Swift toolchain satisfying [Package.swift](Package.swift),
[Bun](https://bun.sh) at the version in [package.json](package.json), and
[Homebrew](https://brew.sh) for SwiftLint and shfmt. Run from a checkout:

```sh
xcodebuild -downloadComponent metalToolchain
bun ci
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

Use `http://127.0.0.1:8787` as **Viewer endpoint**. If the app is already running, confirm **Quit**
when prompted. The command waits for cleanup before replacing and relaunching the debug app.

For VS Code debugging, select **Attach to Skill Issue** and choose the running `SkillIssue` process.

### Build and package

```sh
bun build:release
```

Outputs:

- App: `dist/release/Skill Issue.app`.
- ZIP: `dist/Skill-Issue-macos-arm64.zip`, also uploaded by CI after the Swift checks pass.

For a debug bundle, run `bun build:swift`; the output is `dist/debug/Skill Issue.app`. Both commands
include dependency license notices and do not launch the app.

### Releases

```sh
bun release:patch
bun release:minor
bun release:major
```

Release It! runs the full check, updates `package.json`, creates the conventional release commit and
annotated `vX.Y.Z` tag, and pushes both. Run from a clean `main` checkout tracking `origin/main`,
with Node.js satisfying
[Release It!'s requirements](https://github.com/release-it/release-it/blob/main/package.json).

CI publishes a GitHub release with generated notes and the checked ZIP after the web, Swift and
sanitizer checks pass. Published release tags and assets are immutable; fixes need a new version.
The app's version and build number come from `package.json`; packaging rejects a mismatched release
tag. The same tag identifies the matching Worker source.

After publication, CI uses `brew bump` to open a cask update PR in
[`hu553in/homebrew-tap`](https://github.com/hu553in/homebrew-tap). Review and merge it to make the
release available through Homebrew. The tap also checks for updates daily.

Set the `HOMEBREW_TAP_TOKEN` Actions secret in this repository to a fine-grained personal access
token restricted to `hu553in/homebrew-tap`, with **Contents: Read and write** and **Pull requests:
Read and write**.

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
Swift and sanitizer checks. Coverage reports go into `coverage/`.

Integration tests use a disposable local Worker without ChatGPT credentials or capture permissions.
Native integration tests check CryptoKit/WebCrypto interoperability through the relay. Real capture,
a live ChatGPT account and physical-phone Safari are not covered by automated tests.

### Speech-model validation

For the optional real-model test, prepare WAV clips of at most 12 seconds:

- `en_constraints.wav`: include "do not sort" and "not the values".
- `ru_constraints.wav`: include "сортировать нельзя" and "а не сами значения".

Clips are resampled to 16 kHz. Run:

```sh
SKILL_ISSUE_ASR_CHECK_DIR=/path/to/fixtures bun test:asr
```

The speech library and model are pinned; updates require real-model validation. Model updates must
also update manifest sizes and hashes and [THIRD_PARTY.md](THIRD_PARTY.md). Renovate updates Bun
dependencies, versioned Swift packages and GitHub Actions.

### Troubleshooting

To inspect app output or unified system logs, run one of these commands:

```sh
bun run:swift --logs
bun run:swift --telemetry
```

Both commands rebuild and relaunch the debug app:

- `--logs` follows stdout/stderr in `dist/app.log`.
- `--telemetry` follows system logs for the app's subsystem.
- `--debug` starts under LLDB instead.
- `--verify` launches the app and checks that its process is running.

Rebuilding an ad hoc signed app can require Keychain and screen approval again. If screen access
remains denied, remove its old entry in **System Settings > Privacy & Security > Screen & System
Audio Recording**, add the current app bundle, then quit and reopen.

## License

[MIT](LICENSE). See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency and model licenses.
