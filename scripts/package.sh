#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
CONFIGURATION="${1:-debug}"
case "$#:$CONFIGURATION" in
0:debug | 1:debug | 1:release) ;;
*)
	echo "Usage: $0 [debug|release]" >&2
	exit 2
	;;
esac

VERSION="$(bun -p 'require("./package.json").version')"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	printf 'Invalid package.json version %s; expected MAJOR.MINOR.PATCH.\n' "$VERSION" >&2
	exit 1
fi
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "v$VERSION" ]]; then
	printf 'Release tag %s must match package.json version v%s.\n' "${GITHUB_REF_NAME:-}" "$VERSION" >&2
	exit 1
fi

swift build --configuration "$CONFIGURATION" --jobs 4 --force-resolved-versions
BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP_BUNDLE="$TASK_ROOT/dist/$CONFIGURATION/Skill Issue.app"
STAGING="$(mktemp -d "$TASK_ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/Skill Issue.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_PATH/SkillIssue" "$STAGED_APP/Contents/MacOS/SkillIssue"
iconutil --convert icns "$TASK_ROOT/assets/AppIcon.iconset" \
	--output "$STAGED_APP/Contents/Resources/AppIcon.icns"
shopt -s nullglob
for RESOURCE_BUNDLE in "$BIN_PATH"/*.bundle; do
	ditto "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done
cp "$TASK_ROOT/scripts/Info.plist" "$STAGED_APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
if [[ "$CONFIGURATION" == release && "${GITHUB_REF_TYPE:-}" == tag ]]; then
	plutil -insert SkillIssueReleaseBuild -bool YES "$STAGED_APP/Contents/Info.plist"
fi
plutil -lint "$STAGED_APP/Contents/Info.plist"
RESOURCE_PATH="$STAGED_APP/Contents/Resources/SkillIssue_SkillIssue.bundle/Contents/Resources/Resources"
bun -e 'for (const path of process.argv.slice(1)) JSON.parse(await Bun.file(path).text())' \
	"$RESOURCE_PATH/model.json" "$RESOURCE_PATH/answer-languages.json"
test -s "$RESOURCE_PATH/prompt.md"
bun scripts/notices.ts "$STAGED_APP/Contents/Resources/Notices"
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
if [[ "$CONFIGURATION" == release ]]; then
	ARCHIVE_NAME="Skill-Issue-macos-arm64.zip"
	lipo -verify_arch arm64 "$STAGED_APP/Contents/MacOS/SkillIssue"
	ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$STAGING/$ARCHIVE_NAME"
fi
mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
printf '%s\n' "$APP_BUNDLE"
if [[ "$CONFIGURATION" == release ]]; then
	mv "$STAGING/$ARCHIVE_NAME" "$TASK_ROOT/dist/$ARCHIVE_NAME"
	printf '%s\n' "$TASK_ROOT/dist/$ARCHIVE_NAME"
fi
