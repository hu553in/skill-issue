#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 0 ]]; then
	printf 'Usage: SKILL_ISSUE_ASR_CHECK_DIR=/path/to/fixtures %s\n' "$0" >&2
	exit 2
fi
: "${SKILL_ISSUE_ASR_CHECK_DIR:?Set SKILL_ISSUE_ASR_CHECK_DIR to the directory containing en_constraints.wav and ru_constraints.wav}"
test -f "$SKILL_ISSUE_ASR_CHECK_DIR/en_constraints.wav"
test -f "$SKILL_ISSUE_ASR_CHECK_DIR/ru_constraints.wav"
swift test --jobs 4 --force-resolved-versions --filter twoSourcesAndAnswerCuts
