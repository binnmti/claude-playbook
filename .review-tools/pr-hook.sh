#!/usr/bin/env bash
# Claude Code PreToolUse hook. Fires on every Bash call; runs the pre-PR review
# when the command creates a PR or pushes a branch (so fixes pushed to an
# existing PR get the same broad-lens review, not just the initial creation).
# review-branch.sh skips when the branch is not ahead of base and blocks only
# once per HEAD, so triggering on push is idempotent. Reads the hook JSON from stdin.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
echo "$CMD" | grep -qE 'gh +pr +create|git +push' || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$ROOT" in /home/binnmti-qiqb-note/project/qiqb/*) ;; *) exit 0 ;; esac
exec "$DIR/review-branch.sh"
