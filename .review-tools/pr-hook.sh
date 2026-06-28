#!/usr/bin/env bash
# Claude Code PreToolUse hook. Fires on every Bash call; runs the pre-PR review
# only when the command creates a PR. Reads the hook JSON from stdin.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
echo "$CMD" | grep -qE 'gh +pr +create' || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$ROOT" in /home/binnmti-qiqb-note/project/qiqb/*) ;; *) exit 0 ;; esac
exec "$DIR/review-branch.sh"
