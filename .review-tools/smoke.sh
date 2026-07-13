#!/usr/bin/env bash
# Reviewer CLI smoke test. The reviewer CLIs self-update (agy replaced its own
# binary on 2026-07-13 and stopped reading the stdin prompt, so every review
# ran promptless for a day), so run this when a reviewer starts answering
# nonsense or after a known update. Each reviewer gets a tiny stdin prompt
# through the exact invocation the hooks use; the marker must come back.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/models.conf"
. "$SELF/append-log.sh"

MARKER="REVIEW-SMOKE-$$"
PROMPT="Reply with exactly this token and nothing else: $MARKER"
RVTIMEOUT=90
GITENV=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR)
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

enabled() { reviewer_on "$1" "$REVIEWERS_COMMIT $REVIEWERS_PUSH"; }

{ enabled codex && command -v codex >/dev/null 2>&1 && printf '%s' "$PROMPT" \
  | "${GITENV[@]}" timeout "$RVTIMEOUT" codex exec --sandbox read-only --skip-git-repo-check \
      -m "$CODEX_MODEL_COMMIT" -c model_reasoning_effort="$CODEX_EFFORT_COMMIT" \
      > "$OUT/codex" 2>&1; } &
{ enabled copilot && command -v copilot >/dev/null 2>&1 && printf '%s' "$PROMPT" \
  | "${GITENV[@]}" timeout "$RVTIMEOUT" copilot --model "$COPILOT_MODEL_COMMIT" --log-level none \
      > "$OUT/copilot" 2>&1; } &
{ enabled agy && command -v agy >/dev/null 2>&1 && printf '%s' "$PROMPT" \
  | "${GITENV[@]}" timeout "$RVTIMEOUT" agy --sandbox --model "$AGY_MODEL_COMMIT" \
      > "$OUT/agy" 2>&1; } &
{ enabled vllm && printf '%s' "$PROMPT" \
  | vllm_chat "$VLLM_MODEL_COMMIT" > "$OUT/vllm" 2>&1; } &
wait

FAIL=0
for r in codex copilot agy vllm; do
  if [ ! -e "$OUT/$r" ]; then echo "—  $r (disabled or CLI missing)"; continue; fi
  if grep -q "$MARKER" "$OUT/$r"; then
    echo "✅ $r"
  else
    echo "❌ $r — marker missing; first lines of output:"
    head -5 "$OUT/$r" | sed 's/^/     /'
    FAIL=1
  fi
done
exit "$FAIL"
