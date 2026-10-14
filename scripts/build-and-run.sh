#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
MODE="${1:-run}"
case "$#:$MODE" in
0:run | 1:run | 1:--verify | 1:--debug | 1:--logs | 1:--telemetry) ;;
*)
	echo "Usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2
	exit 2
	;;
esac
# Confirm the build succeeds before asking an active session to stop.
swift build --jobs 4 --force-resolved-versions
# Let the app finish session cleanup before replacing its debug bundle.
swift "$TASK_ROOT/scripts/quit.swift" "$TASK_ROOT/scripts/Info.plist"
bash "$TASK_ROOT/scripts/package.sh" debug
APP_BUNDLE="$TASK_ROOT/dist/debug/Skill Issue.app"
case "$MODE" in
run) /usr/bin/open -n "$APP_BUNDLE" ;;
--verify)
	/usr/bin/open -n "$APP_BUNDLE"
	sleep 2
	pgrep -x SkillIssue >/dev/null
	;;
--debug) lldb -- "$APP_BUNDLE/Contents/MacOS/SkillIssue" ;;
--logs)
	: >"$TASK_ROOT/dist/app.log"
	/usr/bin/open -n --stdout "$TASK_ROOT/dist/app.log" --stderr "$TASK_ROOT/dist/app.log" "$APP_BUNDLE"
	tail -f "$TASK_ROOT/dist/app.log"
	;;
--telemetry)
	/usr/bin/open -n "$APP_BUNDLE"
	/usr/bin/log stream --info --style compact --predicate 'subsystem == "com.github.hu553in.skill-issue"'
	;;
esac
