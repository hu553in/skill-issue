import manifest from "../package.json";

const [tag, changelogPath] = Bun.argv.slice(2);
if (
  Bun.argv.length !== 4 ||
  changelogPath === undefined ||
  changelogPath === ""
) {
  throw new Error("Usage: bun scripts/release-notes.ts TAG CHANGELOG");
}
if (tag !== `v${manifest.version}`) {
  throw new Error(`Release tag must match package.json: v${manifest.version}`);
}
if (!/^bun@\d+\.\d+\.\d+$/u.test(manifest.packageManager)) {
  throw new Error("packageManager must specify an exact Bun version");
}

const repository = "https://github.com/hu553in/skill-issue";
const source = `${repository}/tree/${tag}`;
const readme = `${repository}/blob/${tag}/README.md`;
const deploy = `https://deploy.workers.cloudflare.com/?url=${encodeURIComponent(source)}`;
const bunVersion = manifest.packageManager.slice(4);
const changelog = await Bun.file(changelogPath).text();

process.stdout.write(`## Install ${tag}

Download [Skill-Issue-macos-arm64.zip](${repository}/releases/download/${tag}/Skill-Issue-macos-arm64.zip)
for Apple Silicon and macOS 26 or later. If updating, stop the session and quit Skill Issue first.

Extract the ZIP, move \`Skill Issue.app\` to Applications, then [open the app](${readme}#open-the-app).

**Use the app, viewer and relay from the same release.** In Settings, **Viewer setup** next to
**Viewer endpoint** opens the instructions for the installed app version.

## Viewer setup

Deploy the viewer and relay to your own Cloudflare account. For a new Worker, use the button below.
For updates, follow **Deploy from source or update an existing Worker** below.

### First deployment

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](${deploy})

The button selects **${tag}** and creates a repository in your GitHub account.

1. Sign in to GitHub and Cloudflare, authorize the repository connection and choose your project name.
   Before deploying, set the build options:

   | Setting | Value |
   | --- | --- |
   | Build command | Clear this field |
   | Deploy command | \`bun deploy\` |
   | Preview builds | Off |
   | Build variable \`BUN_VERSION\` | \`${bunVersion}\` |

   The detected Build command also compiles the macOS app and requires Xcode. Leave it empty;
   \`bun deploy\` builds the viewer before publishing the Worker.

2. Deploy, then open the Worker and select **Settings > Builds > Disconnect**. The Worker stays
   deployed, and later Git pushes cannot overwrite manual updates. New Skill Issue releases do not
   update the copied repository automatically.
3. Copy the Worker's production URL into **Viewer endpoint** in the app. Optionally
   [configure Cloudflare Access](${readme}#cloudflare-access), then [start a session](${readme}#usage).

### Deploy from source or update an existing Worker

Keep the session stopped until the app and Worker both use **${tag}**.

1. Install the latest [Node.js LTS](https://nodejs.org/en/download) and
   [Bun ${bunVersion}](https://bun.sh/docs/installation#installing-older-versions),
   then download the source into a new directory:

   \`\`\`sh
   git clone --branch ${tag} --depth 1 ${repository}.git skill-issue-${tag} &&
     cd skill-issue-${tag}
   \`\`\`

   Run the remaining commands from that directory:

   \`\`\`sh
   bun ci
   bunx wrangler login
   \`\`\`

2. Set \`name\` in \`wrangler.jsonc\` to your Worker name. For an update, use the same Cloudflare
   account and Worker name, and [keep your Worker settings](${readme}#keep-your-worker-settings).
   Retain any variables, domains and routes you need, and disconnect Git builds before deploying.
3. Deploy the viewer and relay:

   \`\`\`sh
   bun deploy
   \`\`\`

4. Copy the production URL into **Viewer endpoint**. For an update, confirm that the address has
   stayed the same. If you already use Access, [check the Worker's addresses](${readme}#4-check-the-workers-other-addresses).
   To add protection, [configure Cloudflare Access](${readme}#cloudflare-access).
   Then [start a new session](${readme}#usage).

${changelog}`);
