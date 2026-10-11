#!/usr/bin/env bash
set -euo pipefail
case "$#:${1:-}" in
1:check | 1:fix) MODE="$1" ;;
*)
	printf 'Usage: %s check|fix\n' "$0" >&2
	exit 2
	;;
esac
# swift-format requires this extensionless filename; Oxfmt needs a JSON parser hint.
FORMATTED="$(mktemp)"
trap 'rm -f "$FORMATTED"' EXIT
bun x --no-install oxfmt --stdin-filepath swift-format.json <.swift-format >"$FORMATTED"
if [[ "$MODE" == fix ]]; then
	cat "$FORMATTED" >.swift-format
else
	diff .swift-format "$FORMATTED"
fi
