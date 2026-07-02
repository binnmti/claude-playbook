#!/usr/bin/env bash
# Fill the oldest pending **Response:** line in the current repo+branch's
# review session -- one line recording how that round's findings were
# dispositioned (fixed / false positive / wontfix + why). Run from inside
# the reviewed repo:
#   .review-tools/respond.sh "指摘Aは修正 (abc123)、Bは誤検知 (理由)"
# Repeat once per pending round; prints how many remain. push は pending が
# 0 になるまでブロックされる (review-push.sh)。
set -uo pipefail

MSG="$(printf '%s' "${1:-}" | tr '\n\t' '  ')"
if [ -z "$MSG" ]; then
  echo "usage: respond.sh \"この回の指摘への対応を1行で\"" >&2
  exit 1
fi
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "git リポジトリ内で実行してください" >&2; exit 1; }
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/append-log.sh"
REPO=$(basename "$GIT_ROOT")
BR=$(git -C "$GIT_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$GIT_ROOT" rev-parse --short HEAD)
LOGDIR="$SELF/log"

LOCK=$(_global_lock)
(
  flock -x 200
  # Same file the push gate (session_pending_count) looks at: the most
  # recent session for this repo+branch.
  candidate=$(_latest_session "$REPO" "$(_sanitize "$BR")")
  [ -z "$candidate" ] && { echo "このブランチのレビューセッションがありません ($REPO @ $BR)" >&2; exit 0; }
  SESSFILE="$LOGDIR/$candidate"
  if ! grep -q '^\*\*Response:\*\* _(pending)_$' "$SESSFILE"; then
    echo "pending の Response はありません ($candidate)"
    exit 0
  fi
  TMP=$(mktemp)
  MSG="$MSG" awk '
    !done && $0=="**Response:** _(pending)_" { print "**Response:** " ENVIRON["MSG"]; done=1; next }
    { print }
  ' "$SESSFILE" > "$TMP" && mv "$TMP" "$SESSFILE"
  left=$(grep -c '^\*\*Response:\*\* _(pending)_$' "$SESSFILE")
  echo "記入しました: $candidate — 残り pending ${left} 件"
) 200>"$LOCK"

rebuild_review_log
