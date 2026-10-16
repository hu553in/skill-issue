#!/usr/bin/env bash
set -euo pipefail

case "$#:${1:-}" in
1:coverage | 1:analyze) MODE="$1" ;;
*)
	printf 'Usage: %s coverage|analyze\n' "$0" >&2
	exit 2
	;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
QUALITY_ROOT="$ROOT/.build/quality"
FLAGS=(--scratch-path "$QUALITY_ROOT" --jobs 4 --force-resolved-versions --enable-code-coverage)
mkdir -p "$ROOT/.build"
TEMP="$(mktemp -d "$ROOT/.build/quality-run.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT

SOURCE_FILES=()
NATIVE_FILES=()
while IFS= read -r source; do
	SOURCE_FILES+=("$ROOT/$source")
	# README_SCREENSHOTS tooling has no executable code in the normal app or test binary.
	if [[ "$source" == native/* && "$source" != native/ReadmeScreenshots.swift ]]; then
		NATIVE_FILES+=("$ROOT/$source")
	fi
done < <(find native tests -type f -name '*.swift' -print | LC_ALL=C sort)
if [[ ${#NATIVE_FILES[@]} -eq 0 || ${#SOURCE_FILES[@]} -eq ${#NATIVE_FILES[@]} ]]; then
	printf 'Swift quality checks require application and test sources.\n' >&2
	exit 1
fi

{
	xcrun swift --version
	xcrun --find swiftc
	xcrun --show-sdk-path
	xcrun --show-sdk-version
	# Metal's cryptex mount can change after a reboot.
	xcrun --find metal
	printf '%s\n' "${SDKROOT:-}" "${DEVELOPER_DIR:-}" "${FLAGS[@]}" "${SOURCE_FILES[@]}"
	shasum -a 256 Package.swift Package.resolved
} >"$TEMP/identity"
if ! cmp -s "$TEMP/identity" "$QUALITY_ROOT/analysis-identity"; then
	rm -rf "$QUALITY_ROOT"
	mkdir -p "$QUALITY_ROOT"
	cp "$TEMP/identity" "$QUALITY_ROOT/analysis-identity"
fi

BIN_PATH="$(xcrun swift build "${FLAGS[@]}" --show-bin-path)"
if [[ "$MODE" == coverage ]]; then
	rm -rf "$BIN_PATH/codecov"
	rm -f coverage/swift/lcov.info
	# The real-model check has a separate command and never belongs in this gate.
	unset SKILL_ISSUE_ASR_CHECK_DIR
fi
if ! xcrun swift build --build-tests "${FLAGS[@]}" --verbose >"$TEMP/build.log" 2>&1; then
	cat "$TEMP/build.log" >&2
	exit 1
fi
tail -n 18 "$TEMP/build.log"

# SwiftLint selects the first invocation for a file and expands its live response
# file. Keep fresh commands first, retaining commands omitted by incremental builds.
touch "$QUALITY_ROOT/compiler.log"
awk '/swiftc / && / -module-name (SkillIssue|CoreTests) / && !seen[$0]++' \
	"$TEMP/build.log" "$QUALITY_ROOT/compiler.log" >"$TEMP/compiler.log"
for module in SkillIssue CoreTests; do
	if ! grep -Eq " -module-name $module " "$TEMP/compiler.log"; then
		printf 'Missing compiler invocation for %s; remove .build/quality and retry.\n' "$module" >&2
		exit 1
	fi
done
mv "$TEMP/compiler.log" "$QUALITY_ROOT/compiler.log"

if [[ "$MODE" == analyze ]]; then
	STATUS=0
	swiftlint analyze "${SOURCE_FILES[@]}" --config "$ROOT/.swiftlint.yml" \
		--compiler-log-path "$QUALITY_ROOT/compiler.log" --strict --reporter xcode \
		>"$TEMP/analyze.log" 2>&1 || STATUS=$?
	cat "$TEMP/analyze.log"
	if [[ $STATUS -ne 0 ]]; then exit "$STATUS"; fi
	# SourceKit failures can produce exit 0, as can analyzing no files.
	if grep -Eq '(^|[[:space:]])(warning|error):' "$TEMP/analyze.log" ||
		! grep -Eq "Done analyzing! Found 0 violations, 0 serious in ${#SOURCE_FILES[@]} files\\." "$TEMP/analyze.log"; then
		printf 'Swift analysis did not complete successfully for every application and test source.\n' >&2
		exit 1
	fi
else
	if ! xcrun swift test "${FLAGS[@]}" --skip-build --verbose >"$TEMP/test.log" 2>&1; then
		cat "$TEMP/test.log" >&2
		exit 1
	fi
	tail -n 18 "$TEMP/test.log"
	PROFILE="$BIN_PATH/codecov/default.profdata"
	TEST_BINARY="$BIN_PATH/CoreTests.xctest/Contents/MacOS/CoreTests"
	if [[ ! -f "$PROFILE" || ! -f "$TEST_BINARY" ]]; then
		printf 'SwiftBuild did not produce the CoreTests bundle and coverage profile.\n' >&2
		exit 1
	fi
	xcrun llvm-cov report "$TEST_BINARY" --instr-profile "$PROFILE" "${NATIVE_FILES[@]}"
	xcrun llvm-cov export "$TEST_BINARY" --instr-profile "$PROFILE" --format=lcov \
		"${NATIVE_FILES[@]}" >"$TEMP/lcov.info"
	for source in "${NATIVE_FILES[@]}"; do
		if ! grep -Fxq "SF:$source" "$TEMP/lcov.info"; then
			printf 'Missing Swift coverage data for %s.\n' "$source" >&2
			exit 1
		fi
	done
	mkdir -p coverage/swift
	mv "$TEMP/lcov.info" coverage/swift/lcov.info
fi
