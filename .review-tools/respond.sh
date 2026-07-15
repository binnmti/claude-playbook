#!/usr/bin/env bash
# Fill the oldest pending **Response:** line in the current repo+branch's
# review session. Findings carry a per-round number (# column), and the
# Response records a per-finding verdict so the dashboard (serve.py) can
# compute adoption rates per AI/model. Run from inside the reviewed repo:
#
#   .review-tools/respond.sh "1:fix/h main.jobs に絞って修正 2:fp ^起点で不一致 3:skip"
#
#   N:verdict[/sev]  then free-text reason until the next N: token
#     verdict: fix=採用し修正 / fp=誤検知 / skip=妥当だが対応しない / dup=既報
#     /h /m /l = 書き手が再評価した実重要度 (省略=レビュアー評価に同意)
#
# Plain free text (no tokens) is still accepted but won't feed the dashboard.
# Repeat once per pending round; prints how many remain. push は pending が
# 0 になるまでブロックされる (review-push.sh)。
set -uo pipefail

MSG="$(printf '%s' "${1:-}" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ //; s/ $//')"
if [ -z "$MSG" ]; then
  echo "usage: respond.sh \"1:fix/h 理由 2:fp 理由 3:skip\"  (fix|fp|skip|dup, /h /m /l 任意)" >&2
  exit 1
fi
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "git リポジトリ内で実行してください" >&2; exit 1; }
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/append-log.sh"
REPO=$(basename "$GIT_ROOT")
BR=$(git -C "$GIT_ROOT" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$GIT_ROOT" rev-parse --short HEAD)
LOGDIR="$SELF/log"

# verdict tokens present in MSG, one "N verdict" per line (sed puts each
# token at the start of its own line; text between tokens is the reason)
TOKENS=$(printf '%s\n' "$MSG" \
  | sed -E 's/(^|[[:space:]])([0-9]+):(fix|fp|skip|dup)(\/[hml])?/\n\2:\3\4/g' \
  | sed -n 's/^\([0-9]\+\):\([a-z]\+\)\(\/[hml]\)\?.*/\1/p')

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

  # findings in the round being answered (the oldest pending one): count the
  # numbered rows of its table so verdict numbers can be validated. 0 means a
  # pre-numbering round -- skip validation there.
  NFIND=$(awk '
    /^<details>$/ { n = 0 }
    /^\| [0-9]+ \|/ { n++ }
    /^\*\*Response:\*\* _\(pending\)_$/ { print n; exit }
  ' "$SESSFILE")
  if [ "${NFIND:-0}" -gt 0 ]; then
    missing=""
    for i in $(seq 1 "$NFIND"); do
      printf '%s\n' "$TOKENS" | grep -qx "$i" || missing="${missing:+$missing }#$i"
    done
    for t in $TOKENS; do
      if [ "$t" -lt 1 ] || [ "$t" -gt "$NFIND" ]; then
        echo "指摘 #$t はこのラウンドに存在しません (指摘は #1〜#$NFIND)" >&2
        exit 1
      fi
    done
    [ -n "$missing" ] && echo "⚠ 裁定なしの指摘: $missing (ダッシュボードでは未裁定扱い)" >&2
    [ -z "$TOKENS" ] && echo "⚠ 裁定トークンなしの自由文 (ダッシュボードには乗りません)" >&2
  fi

  TMP=$(mktemp)
  MSG="$MSG" awk '
    !done && $0=="**Response:** _(pending)_" { print "**Response:** " ENVIRON["MSG"]; done=1; next }
    { print }
  ' "$SESSFILE" > "$TMP" && mv "$TMP" "$SESSFILE"
  left=$(grep -c '^\*\*Response:\*\* _(pending)_$' "$SESSFILE")
  echo "記入しました: $candidate — 残り pending ${left} 件"
) 200>"$LOCK"
rc=$?

rebuild_review_log
exit "$rc"
