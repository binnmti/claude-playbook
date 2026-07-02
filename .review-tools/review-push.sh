#!/usr/bin/env bash
# Push-time review, wired as the global pre-push git hook -- fires on every
# `git push` whether Claude or a human runs it (`gh pr create` pushes via git,
# so it fires there too). Bypass: git push --no-verify, or REVIEW_SKIP=1.
#
# Scope of one review:
#   direct push to main/master/develop -> only the commits this push adds
#     (vs the same-named remote branch). This is the merge gate.
#   feature branch, first review       -> the whole branch (merge-base..HEAD),
#     broad lens.
#   feature branch, later pushes       -> the increment since the last
#     reviewed SHA only, so a PR growing over many pushes isn't re-reviewed
#     from scratch each time (whole-branch re-review kept resurfacing old
#     findings).
#
# The reviewers inspect git themselves (read-only) rather than receiving an
# embedded diff, so the prompt stays small -- embedding the full branch as
# one argv string overran the kernel's 128KB per-argument limit and silently
# produced no review.
#
# Clean review (no findings) passes immediately. Findings block once per
# HEAD; a retry at the same HEAD passes only when every logged round's
# Response has been filled in (respond.sh).
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0
[ "${REVIEW_SKIP:-}" = "1" ] && exit 0

BASE=""
# Direct-push to a long-lived branch (e.g. monitoring repos that push straight
# to develop): review only the commits this push adds, i.e. vs the SAME-named
# remote branch -- not vs main, which would drag in the entire develop history.
CUR=$(git symbolic-ref -q --short HEAD 2>/dev/null)
case "$CUR" in
  main|master|develop)
    git rev-parse --verify -q "origin/$CUR" >/dev/null 2>&1 && BASE="origin/$CUR" ;;
esac
# Feature branch (PR workflow): review the whole branch vs its merge target.
# Pick whichever candidate HEAD is fewest commits ahead of -- that's the
# actual fork point (e.g. a branch cut from develop stays 1 commit ahead of
# origin/develop but 198 ahead of origin/main, since main is far behind
# develop) -- rather than assuming origin/HEAD (the repo's default branch,
# usually main) is always what feature branches fork from.
if [ -z "$BASE" ]; then
  BASE_COUNT=""
  for b in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
           origin/main origin/develop main develop; do
    [ -n "$b" ] || continue
    git rev-parse --verify -q "$b" >/dev/null || continue
    count=$(git rev-list --count "$b"..HEAD 2>/dev/null) || continue
    if [ -z "$BASE_COUNT" ] || [ "$count" -lt "$BASE_COUNT" ]; then
      BASE="$b"; BASE_COUNT="$count"
    fi
  done
fi
[ -z "$BASE" ] && exit 0
HEADSHA=$(git rev-parse HEAD)
MB=$(git merge-base HEAD "$BASE" 2>/dev/null) || exit 0
[ "$MB" = "$HEADSHA" ] && exit 0   # nothing ahead of base

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/append-log.sh"
REPO=$(basename "$GIT_ROOT")
BR="${CUR:-detached}"
PASS="$(git rev-parse --git-path .pr-review-passed)"
LASTREV_FILE="$(git rev-parse --git-path ".review-lastrev-$(_sanitize "$BR")")"

# Feature branches: if a previous review on this branch already covered up to
# LASTREV, review only LASTREV..HEAD this time.
RANGE_FROM="$MB"
case "$CUR" in main|master|develop) ;; *)
  LASTREV=$(cat "$LASTREV_FILE" 2>/dev/null)
  if [ -n "${LASTREV:-}" ] && [ "$LASTREV" != "$HEADSHA" ] \
     && git merge-base --is-ancestor "$MB" "$LASTREV" 2>/dev/null \
     && git merge-base --is-ancestor "$LASTREV" HEAD 2>/dev/null; then
    RANGE_FROM="$LASTREV"
  fi ;;
esac

finish_ok() {
  echo "$HEADSHA" > "$LASTREV_FILE"
  close_session "$REPO" "$BR" "${HEADSHA:0:10}"
  exit 0
}

pending_block() {
  {
    echo "════════════════════════════════════════════════════════"
    echo " push ブロック: このブランチのレビューセッションに Response 未記入の"
    echo " ラウンドが $1 件残っています。各ラウンドの指摘への対応 (修正した/"
    echo " 誤検知(理由)) を1行ずつ記録してから、もう一度 push してください:"
    echo "   $SELF/respond.sh \"指摘Aは修正 (コミットX)、Bは誤検知 (理由)\""
    echo " Skip: git push --no-verify  /  REVIEW_SKIP=1 git push …"
    echo "════════════════════════════════════════════════════════"
  } >&2
  exit 2
}

if [ "$(cat "$PASS" 2>/dev/null)" = "$HEADSHA" ]; then
  PENDING=$(session_pending_count "$REPO" "$BR")
  [ "${PENDING:-0}" -gt 0 ] && pending_block "$PENDING"
  finish_ok
fi

DIFF=$(git diff "$RANGE_FROM"...HEAD)
[ -z "$DIFF" ] && exit 0
FILES=$(git diff --name-only --diff-filter=ACMR "$RANGE_FROM"...HEAD)

HISTFILES=$(session_history_files "$REPO" "$BR")
# codex/copilot/agy can't read paths outside the repo they're sandboxed in
# (verified: copilot returns "Permission denied" for anything outside the
# working tree, even with --allow-all-tools) -- .review-tools/log/ is a
# sibling of the repo, not inside it, so copy the files in-tree (under .git/,
# untracked) before pointing reviewers at them. Cleaned up at the end.
HISTCOPY=""
if [ -n "$HISTFILES" ]; then
  HISTCOPY=".git/.review-history-context.$$.md"
  printf '%s\n' "$HISTFILES" | while IFS= read -r hf; do cat "$hf"; done > "$HISTCOPY"
fi

PROMPT="$(cat "$SELF/prompt-push.md")
このリポジトリ内で変更を自分で確認してください(read-only): \`git diff ${RANGE_FROM}...HEAD\` を実行し、
必要な変更ファイルは全文を読んでください。差分は埋め込んでいません。

変更ファイル:
${FILES}"
if [ "$RANGE_FROM" != "$MB" ]; then
  PROMPT="このブランチは ${RANGE_FROM} まで前回レビュー済みです。今回はそこからの増分のみをレビューしてください。

$PROMPT"
fi
if [ -n "$HISTCOPY" ]; then
  PROMPT="このリポジトリ+ブランチで過去に報告済みのレビュー指摘の記録が次のファイルにあります: $HISTCOPY
Response 未記入の指摘も含め、すべて既に報告済みです。該当コードが変わっていない限り、同じ指摘を繰り返さないこと。コードが変わった箇所や、記録に無い新しい問題は遠慮なく指摘すること。

$PROMPT"
fi

OUT=$(mktemp -d)
{ command -v codex >/dev/null 2>&1 && printf '%s' "$PROMPT" | codex exec --sandbox read-only --skip-git-repo-check \
    -c model_reasoning_effort=medium > "$OUT/codex" 2>"$OUT/codex.err"
  grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"; } &
{ command -v copilot >/dev/null 2>&1 && printf '%s' "$PROMPT" | copilot --model auto --allow-all-tools --log-level none 2>"$OUT/copilot.err" \
    | sed -e '/^Changes /,$d' -e '/^[[:space:]]*[●│└]/d' > "$OUT/copilot"; } &
{ command -v agy >/dev/null 2>&1 && printf '%s' "$PROMPT" | agy --print --sandbox 2>"$OUT/agy.err" \
    | sed '/<message>/,/<\/message>/d' > "$OUT/agy"; } &
wait

append_review_log "branch" "$REPO" "$BR" "${RANGE_FROM:0:10}..${HEADSHA:0:10}" "$OUT"
echo "$HEADSHA" > "$PASS"

if [ "${APPEND_FINDINGS:-0}" = 0 ]; then
  echo "PRE-PUSH REVIEW (${RANGE_FROM:0:10}..${HEADSHA:0:10}): 指摘なし" >&2
  rm -rf "$OUT"; rm -f "$HISTCOPY"
  PENDING=$(session_pending_count "$REPO" "$BR")
  [ "${PENDING:-0}" -gt 0 ] && pending_block "$PENDING"
  finish_ok
fi

{
  echo "════════════════════════════════════════════════════════"
  echo " PRE-PUSH REVIEW  (${RANGE_FROM:0:10}..${HEADSHA:0:10})  — codex + copilot + agy — Claude curates"
  echo "════════════════════════════════════════════════════════"
  for r in codex copilot agy; do
    body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
    [ -z "$body" ] && continue
    echo; echo "### $r"; echo "$body"
  done
  echo "════════════════════════════════════════════════════════"
  echo "Curate, address what matters (new commits), then push again."
  echo "各ラウンドの指摘への対応を1行ずつ記録してください (pending が残ると push できません):"
  echo "  $SELF/respond.sh \"指摘Aは修正 (コミットX)、Bは誤検知 (理由)\""
  echo "Skip: git push --no-verify  /  REVIEW_SKIP=1 git push …"
} >&2

rm -rf "$OUT"; rm -f "$HISTCOPY"
exit 2
