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

# Clean temp files on any exit, including SIGTERM from an outer timeout.
CTX=""; OUT=""; HISTCOPY=""
trap '[ -n "$CTX" ] && rm -f "$CTX"; [ -n "$OUT" ] && rm -rf "$OUT"; [ -n "$HISTCOPY" ] && rm -f "$HISTCOPY"' EXIT
trap 'exit 143' TERM INT

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
. "$SELF/models.conf"
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
  # in a worktree .git is a file, not a dir -- fall back to the tree root
  HISTDIR=.git; [ -d .git ] || HISTDIR=.
  HISTCOPY="$HISTDIR/.review-history-context.$$.md"
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
# Each reviewer gets a hard deadline so a commit review always finishes
# inside the caller's patience; timed-out reviewers show up as ⚠ rows.
RVTIMEOUT=120
# In a worktree git exports GIT_DIR/GIT_INDEX_FILE (absolute) to hooks; codex
# inherits them and its internal curated-sync then fetch+resets OUR worktree
# HEAD to refs/codex/curated-sync (observed 2026-07-01/02). Strip them for
# every reviewer subprocess.
GITENV=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR)
run_codex() {
  reviewer_on codex "$REVIEWERS_COMMIT" || return
  command -v codex >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | "${GITENV[@]}" timeout "$RVTIMEOUT" codex exec --sandbox read-only --skip-git-repo-check \
    -m "$CODEX_MODEL_COMMIT" -c model_reasoning_effort="$CODEX_EFFORT_COMMIT" \
    > "$OUT/codex" 2>"$OUT/codex.err"
  grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"
}
run_copilot() {
  reviewer_on copilot "$REVIEWERS_COMMIT" || return
  command -v copilot >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | "${GITENV[@]}" timeout "$RVTIMEOUT" copilot --model "$COPILOT_MODEL_COMMIT" --log-level none 2>"$OUT/copilot.err" \
    | sed -e '/^Changes /,$d' -e '/^[[:space:]]*[●│└]/d' > "$OUT/copilot"
}
run_agy() {
  reviewer_on agy "$REVIEWERS_COMMIT" || return
  command -v agy >/dev/null 2>&1 || return
  printf '%s' "$PROMPT" | "${GITENV[@]}" timeout "$RVTIMEOUT" agy --sandbox --model "$AGY_MODEL_COMMIT" 2>"$OUT/agy.err" \
    | sed '/<message>/,/<\/message>/d' > "$OUT/agy"
}
run_vllm() {
  reviewer_on vllm "$REVIEWERS_COMMIT" || return
  printf '%s' "$PROMPT" | head -c 60000 \
    | vllm_chat "$VLLM_MODEL_COMMIT" > "$OUT/vllm" 2>"$OUT/vllm.err"
}
run_codex & run_copilot & run_agy & run_vllm & wait

append_review_log "commit" "$REPO" "$BR" "${HASH:0:10}" "$OUT"

if [ "${APPEND_FINDINGS:-0}" = 0 ] && [ "${APPEND_UNPARSED:-0}" = 0 ]; then
  echo "PRE-COMMIT REVIEW: 指摘なし — コミットを通します (${REVIEWERS_COMMIT})"
  exit 0
fi

echo "────────────────────────────────────────────────────────"
echo " PRE-COMMIT REVIEW  (${REVIEWERS_COMMIT})  — Claude curates"
echo "────────────────────────────────────────────────────────"
for r in codex copilot agy vllm; do
  body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
  [ -z "$body" ] && continue
  echo; echo "### $r"; echo "$body"
done
echo "────────────────────────────────────────────────────────"
echo "Curate the above, fix what matters, then re-commit (同一内容の再コミットは通ります)."
echo "その後、この回の指摘への対応を1行で記録してください (push までに必須):"
echo "  $SELF/respond.sh \"指摘Aは修正、Bは誤検知 (理由)\""
if [ "${APPEND_FINDINGS:-0}" = 0 ]; then
  echo "※ 今回はパース不能な形式外出力 (❓) のみ。内容に実質的な指摘が無ければ"
  echo "  そのまま再コミットで通ります (Response は自動記入済み、respond.sh 不要)。"
fi
echo "Skip: git commit --no-verify  /  REVIEW_SKIP=1 git commit …"

echo "$HASH" > "$PASS"
exit 1
