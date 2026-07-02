#!/usr/bin/env bash
# Manually close the open review session for a repo+branch -- the receiver
# for sessions close_session never seals: work abandoned, branch merged
# elsewhere, or pushed with --no-verify / REVIEW_SKIP=1. Editing REVIEW_LOG.md
# by hand doesn't stick (the next rebuild_review_log regenerates it from the
# session files). Run from inside the reviewed repo:
#   .review-tools/close.sh "理由"            # current branch
#   .review-tools/close.sh "理由" <branch>   # another branch's session
set -uo pipefail

REASON="$(printf '%s' "${1:-}" | tr '\n\t' '  ')"
if [ -z "$REASON" ]; then
  echo "usage: close.sh \"クローズ理由を1行で\" [branch]" >&2
  exit 1
fi
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "git リポジトリ内で実行してください" >&2; exit 1; }
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/append-log.sh"
REPO=$(basename "$GIT_ROOT")
BR="${2:-$(git -C "$GIT_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$GIT_ROOT" rev-parse --short HEAD)}"
LOGDIR="$SELF/log"

LOCK=$(_global_lock)
(
  flock -x 200
  candidate=$(_latest_session "$REPO" "$(_sanitize "$BR")")
  [ -z "$candidate" ] && { echo "このブランチのレビューセッションがありません ($REPO @ $BR)" >&2; exit 0; }
  SESSFILE="$LOGDIR/$candidate"
  grep -q '^<!-- SESSION CLOSED -->$' "$SESSFILE" 2>/dev/null && { echo "既にクローズ済みです ($candidate)"; exit 0; }
  {
    echo "<!-- SESSION CLOSED -->"
    echo "✅ 手動クローズ: ${REASON}（$(date '+%Y-%m-%d')）"
  } >> "$SESSFILE"
  mkdir -p "$LOGDIR/closed"
  mv "$SESSFILE" "$LOGDIR/closed/"
  echo "クローズしました: $candidate"
) 200>"$LOCK"

rebuild_review_log
