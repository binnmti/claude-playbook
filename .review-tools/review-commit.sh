#!/usr/bin/env bash
# Commit-time review (fires on `git commit`). Runs codex + copilot + agy over
# the staged diff AND the full contents of changed files. Clean review (no
# findings) passes immediately; findings block the commit once so they can be
# curated, and a second identical commit passes.
# Bypass: git commit --no-verify, or REVIEW_SKIP=1 git commit …
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0
[ "${REVIEW_SKIP:-}" = "1" ] && exit 0

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
[ -z "$STAGED" ] && exit 0

# docs-only changes don't need code review
if ! echo "$STAGED" | grep -qvE '\.(md|txt|rst)$'; then exit 0; fi

DIFF=$(git diff --cached)
HASH=$(printf '%s' "$DIFF" | sha1sum | cut -d' ' -f1)
PASS="$(git rev-parse --git-path .review-passed)"
[ "$(cat "$PASS" 2>/dev/null)" = "$HASH" ] && exit 0

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/append-log.sh"
REPO=$(basename "$GIT_ROOT")
BR=$(git symbolic-ref -q --short HEAD 2>/dev/null || git rev-parse --short HEAD)
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

PROMPT="$(cat "$SELF/prompt-commit.md")"$'\n\n'"$(cat "$CTX")"
if [ -n "$HISTCOPY" ]; then
  PROMPT="このリポジトリ+ブランチで過去に報告済みのレビュー指摘の記録が次のファイルにあります: $HISTCOPY
Response 未記入の指摘も含め、すべて既に報告済みです。該当コードが変わっていない限り、同じ指摘を繰り返さないこと。コードが変わった箇所や、記録に無い新しい問題は遠慮なく指摘すること。

$PROMPT"
fi

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
  printf '%s' "$PROMPT" | copilot --model auto --log-level none 2>"$OUT/copilot.err" \
    | sed -e '/^Changes /,$d' -e '/^[[:space:]]*[●│└]/d' > "$OUT/copilot"
}
run_agy() {
  command -v agy >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | agy --print --sandbox 2>"$OUT/agy.err" \
    | sed '/<message>/,/<\/message>/d' > "$OUT/agy"
}
run_codex & run_copilot & run_agy & wait

append_review_log "commit" "$REPO" "$BR" "${HASH:0:10}" "$OUT"

if [ "${APPEND_FINDINGS:-0}" = 0 ]; then
  echo "PRE-COMMIT REVIEW: 指摘なし — コミットを通します (codex + copilot + agy)"
  rm -rf "$CTX" "$OUT"
  rm -f "$HISTCOPY"
  exit 0
fi

echo "────────────────────────────────────────────────────────"
echo " PRE-COMMIT REVIEW  (codex + copilot + agy)  — Claude curates"
echo "────────────────────────────────────────────────────────"
for r in codex copilot agy; do
  body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
  [ -z "$body" ] && continue
  echo; echo "### $r"; echo "$body"
done
echo "────────────────────────────────────────────────────────"
echo "Curate the above, fix what matters, then re-commit (同一内容の再コミットは通ります)."
echo "その後、この回の指摘への対応を1行で記録してください (push までに必須):"
echo "  $SELF/respond.sh \"指摘Aは修正、Bは誤検知 (理由)\""
echo "Skip: git commit --no-verify  /  REVIEW_SKIP=1 git commit …"

echo "$HASH" > "$PASS"
rm -rf "$CTX" "$OUT"
rm -f "$HISTCOPY"
exit 1
