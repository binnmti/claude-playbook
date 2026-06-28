#!/usr/bin/env bash
# Pre-PR review. Reviews the whole branch (merge-base..HEAD) with full file
# contents and a broad lens (architecture, breaking changes, test coverage).
# Blocks once per branch HEAD; a retry at the same HEAD passes.
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0

BASE=""
for b in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
         origin/main origin/develop main develop; do
  [ -n "$b" ] && git rev-parse --verify -q "$b" >/dev/null && { BASE="$b"; break; }
done
[ -z "$BASE" ] && exit 0
MB=$(git merge-base HEAD "$BASE" 2>/dev/null) || exit 0
[ "$MB" = "$(git rev-parse HEAD)" ] && exit 0   # nothing ahead of base

DIFF=$(git diff "$MB"...HEAD)
[ -z "$DIFF" ] && exit 0
FILES=$(git diff --name-only --diff-filter=ACMR "$MB"...HEAD)

HEADSHA=$(git rev-parse HEAD)
PASS="$(git rev-parse --git-path .pr-review-passed)"
[ "$(cat "$PASS" 2>/dev/null)" = "$HEADSHA" ] && exit 0

CTX=$(mktemp); MAXFILES=25; MAXLINES=1200; n=0
{
  echo "=== BRANCH DIFF ($BASE...HEAD) ==="; echo "$DIFF"
  echo; echo "=== FULL CONTENTS OF CHANGED FILES ==="
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    n=$((n+1)); [ "$n" -gt "$MAXFILES" ] && { echo "(…more files omitted)"; break; }
    echo; echo "----- $f -----"; head -n "$MAXLINES" "$f"
  done <<< "$FILES"
} > "$CTX"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="$(cat "$SELF/prompt-branch.md")"$'\n\n'"$(cat "$CTX")"

OUT=$(mktemp -d)
{ command -v codex >/dev/null 2>&1 && codex exec --sandbox read-only --skip-git-repo-check \
    -c model_reasoning_effort=medium "$PROMPT" < /dev/null 2>/dev/null > "$OUT/codex"
  grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"; } &
{ command -v copilot >/dev/null 2>&1 && copilot -p "$PROMPT" --model gemini-3.1-pro-preview --log-level none < /dev/null 2>/dev/null \
    | sed '/^Changes /,$d' > "$OUT/copilot"; } &
wait

{
  echo "════════════════════════════════════════════════════════"
  echo " PRE-PR REVIEW  ($BASE...HEAD)  — codex + copilot — Claude curates"
  echo "════════════════════════════════════════════════════════"
  any=0
  for r in codex copilot; do
    body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
    [ -z "$body" ] && continue
    any=1; echo; echo "### $r"; echo "$body"
  done
  [ "$any" = 0 ] && echo "(no reviewer output — check codex/copilot auth)"
  echo "════════════════════════════════════════════════════════"
  echo "Curate, address what matters (new commits), then re-run the PR command."
} >&2

echo "$HEADSHA" > "$PASS"
rm -rf "$CTX" "$OUT"
exit 2
