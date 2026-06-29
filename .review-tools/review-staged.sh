#!/usr/bin/env bash
# Multi-reviewer pre-commit review. Runs codex + copilot over the staged diff
# AND the full contents of changed files, surfaces all findings, then blocks the
# commit once so the findings can be curated. A second identical commit passes.
# Bypass entirely with: git commit --no-verify
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
[ -z "$STAGED" ] && exit 0

# docs-only changes don't need code review
if ! echo "$STAGED" | grep -qvE '\.(md|txt|rst)$'; then exit 0; fi

DIFF=$(git diff --cached)
HASH=$(printf '%s' "$DIFF" | sha1sum | cut -d' ' -f1)
PASS="$GIT_ROOT/.git/.review-passed"
[ "$(cat "$PASS" 2>/dev/null)" = "$HASH" ] && exit 0

# Build context: diff + full contents of changed files (capped).
CTX=$(mktemp); MAXFILES=15; MAXLINES=800; n=0
{
  echo "=== STAGED DIFF ==="; echo "$DIFF"
  echo; echo "=== FULL CONTENTS OF CHANGED FILES ==="
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    n=$((n+1)); [ "$n" -gt "$MAXFILES" ] && { echo "(…more files omitted)"; break; }
    echo; echo "----- $f -----"; head -n "$MAXLINES" "$f"
    [ "$(wc -l <"$f")" -gt "$MAXLINES" ] && echo "(…file truncated at ${MAXLINES} lines)"
  done <<< "$STAGED"
} > "$CTX"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="$(cat "$SELF/prompt-commit.md")"$'\n\n'"$(cat "$CTX")"

OUT=$(mktemp -d)
# Prompt goes via stdin, not argv: a large staged change embedded as one argv
# string overruns the kernel's 128KB per-argument limit and silently fails.
run_codex() {
  command -v codex >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | codex exec --sandbox read-only --skip-git-repo-check -c model_reasoning_effort=low \
    > "$OUT/codex" 2>"$OUT/codex.err"
  grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"
}
run_copilot() {
  command -v copilot >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | copilot --model gemini-3.1-pro-preview --log-level none 2>"$OUT/copilot.err" \
    | sed '/^Changes /,$d' > "$OUT/copilot"
}
run_codex & run_copilot & wait

echo "────────────────────────────────────────────────────────"
echo " PRE-COMMIT REVIEW  (codex + copilot)  — Claude curates"
echo "────────────────────────────────────────────────────────"
any=0
for r in codex copilot; do
  body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
  [ -z "$body" ] && continue
  any=1
  echo; echo "### $r"; echo "$body"
done
if [ "$any" = 0 ]; then
  echo "(no reviewer produced output)"
  for r in codex copilot; do
    [ -s "$OUT/$r.err" ] && { echo "--- $r stderr (tail) ---"; tail -n 3 "$OUT/$r.err"; }
  done
fi
echo "────────────────────────────────────────────────────────"
echo "Curate the above, fix what matters, then re-commit."
echo "Skip review for this commit: git commit --no-verify"

echo "$HASH" > "$PASS"
rm -rf "$CTX" "$OUT"
exit 1
