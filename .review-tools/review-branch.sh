#!/usr/bin/env bash
# Pre-PR review. Reviews the whole branch (merge-base..HEAD) with a broad lens
# (architecture, breaking changes, test coverage). The reviewers inspect git
# themselves (read-only) rather than receiving an embedded diff, so the prompt
# stays small -- embedding the full branch as one argv string overran the
# kernel's 128KB per-argument limit and silently produced no review.
# Blocks once per branch HEAD; a retry at the same HEAD passes.
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0

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
if [ -z "$BASE" ]; then
  for b in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
           origin/main origin/develop main develop; do
    [ -n "$b" ] && git rev-parse --verify -q "$b" >/dev/null && { BASE="$b"; break; }
  done
fi
[ -z "$BASE" ] && exit 0
MB=$(git merge-base HEAD "$BASE" 2>/dev/null) || exit 0
[ "$MB" = "$(git rev-parse HEAD)" ] && exit 0   # nothing ahead of base

DIFF=$(git diff "$MB"...HEAD)
[ -z "$DIFF" ] && exit 0
FILES=$(git diff --name-only --diff-filter=ACMR "$MB"...HEAD)

HEADSHA=$(git rev-parse HEAD)
PASS="$(git rev-parse --git-path .pr-review-passed)"
[ "$(cat "$PASS" 2>/dev/null)" = "$HEADSHA" ] && exit 0

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="$(cat "$SELF/prompt-branch.md")
このリポジトリ内で変更を自分で確認してください(read-only): \`git diff ${MB}...HEAD\` を実行し、
必要な変更ファイルは全文を読んでください。差分は埋め込んでいません。

変更ファイル:
${FILES}"

OUT=$(mktemp -d)
{ command -v codex >/dev/null 2>&1 && printf '%s' "$PROMPT" | codex exec --sandbox read-only --skip-git-repo-check \
    -c model_reasoning_effort=medium > "$OUT/codex" 2>"$OUT/codex.err"
  grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"; } &
{ command -v copilot >/dev/null 2>&1 && printf '%s' "$PROMPT" | copilot --model auto --allow-all-tools --log-level none 2>"$OUT/copilot.err" \
    | sed '/^Changes /,$d' > "$OUT/copilot"; } &
{ command -v agy >/dev/null 2>&1 && printf '%s' "$PROMPT" | agy --print --sandbox 2>"$OUT/agy.err" \
    | sed '/<message>/,/<\/message>/d' > "$OUT/agy"; } &
wait

{
  echo "════════════════════════════════════════════════════════"
  echo " PRE-PR REVIEW  ($BASE...HEAD)  — codex + copilot + agy — Claude curates"
  echo "════════════════════════════════════════════════════════"
  any=0
  for r in codex copilot agy; do
    body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
    [ -z "$body" ] && continue
    any=1; echo; echo "### $r"; echo "$body"
  done
  if [ "$any" = 0 ]; then
    echo "(no reviewer output)"
    for r in codex copilot agy; do
      [ -s "$OUT/$r.err" ] && { echo "--- $r stderr (tail) ---"; tail -n 3 "$OUT/$r.err"; }
    done
  fi
  echo "════════════════════════════════════════════════════════"
  echo "Curate, address what matters (new commits), then re-run the PR command."
} >&2

echo "$HEADSHA" > "$PASS"
rm -rf "$OUT"
exit 2
