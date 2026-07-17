#!/usr/bin/env bash
# Push-time review, wired as the global pre-push git hook -- fires on every
# `git push` whether Claude or a human runs it (`gh pr create` pushes via git,
# so it fires there too). Bypass: git push --no-verify, or REVIEW_SKIP=1.
#
# Reviews each ref actually being pushed (the pre-push stdin lines, forwarded
# by git-hooks/pre-push) -- NOT the checked-out branch. `git push origin
# feature-x` while a synced develop was checked out used to see "nothing
# ahead of base" and slip through unreviewed. Tag pushes and deletes are
# skipped; no piped stdin (manual run) falls back to HEAD.
#
# Scope of one review:
#   push to remote main/master/develop -> only the commits this push adds
#     (vs the remote tip being replaced). This is the merge gate.
#   feature branch, first review       -> the whole branch (merge-base..sha),
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
# pushed sha; a retry at the same sha passes only when every logged round's
# Response has been filled in (respond.sh).
set -uo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$GIT_ROOT" || exit 0
[ "${REVIEW_SKIP:-}" = "1" ] && exit 0

# Master switch: reviews fire only where someone created .review-tools/.env
# (see .env.sample) with REVIEW_ENABLED=1. Keeps ports of this tree inert
# until opted in.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF/.env" ] && . "$SELF/.env"
[ "${REVIEW_ENABLED:-0}" = "1" ] || exit 0

# Clean temp files on any exit -- including SIGTERM from an outer timeout
# (e.g. the caller's Bash tool killing a long push). The per-reviewer
# `timeout` below bounds orphaned reviewers if this script itself is killed.
OUT=""; HISTCOPY=""
trap '[ -n "$OUT" ] && rm -rf "$OUT"; [ -n "$HISTCOPY" ] && rm -f "$HISTCOPY"' EXIT
trap 'exit 143' TERM INT

. "$SELF/append-log.sh"
. "$SELF/models.conf"
REPO=$(basename "$GIT_ROOT")

# Each reviewer gets a hard deadline: the review must finish inside the
# caller's patience (a stray reviewer otherwise runs on as an orphan burning
# tokens when the push gets killed from outside). Timed-out reviewers show
# up as ⚠ rows in the log.
RVTIMEOUT=300
# In a worktree git exports GIT_DIR/GIT_INDEX_FILE (absolute) to hooks; codex
# inherits them and its internal curated-sync then fetch+resets OUR worktree
# HEAD to refs/codex/curated-sync (observed 2026-07-01/02). Strip them for
# every reviewer subprocess.
GITENV=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_COMMON_DIR)

# The helpers below run inside review_one and see its locals (SHA, BR,
# LASTREV_FILE) via bash's dynamic scoping.
finish_ok() {
  echo "$SHA" > "$LASTREV_FILE"
  close_session "$REPO" "$BR" "${SHA:0:10}"
  return 0
}

pending_block() {
  {
    echo "════════════════════════════════════════════════════════"
    echo " push ブロック: このブランチのレビューセッションに Response 未記入の"
    echo " ラウンドが $1 件残っています。各ラウンドの指摘への対応 (修正した/"
    echo " 誤検知(理由)) を1行ずつ記録してから、もう一度 push してください:"
    echo "   $SELF/respond.sh \"1:fix/h 直した内容 2:fp 誤検知の理由\"  (fix|fp|skip|dup, /h /m /l 任意)"
    echo " Skip: git push --no-verify  /  REVIEW_SKIP=1 git push …"
    echo "════════════════════════════════════════════════════════"
  } >&2
  return 2
}

review_one() {  # <local-ref> <local-sha> <remote-ref> <remote-sha>
  local LREF="$1" SHA="$2" RREF="$3" RSHA="$4"
  local BR RB BASE BASE_COUNT b count MB PASS LASTREV_FILE LASTREV RANGE_FROM
  local UNREV COMMON lr R COVERED FILES HISTFILES HISTDIR PROMPT PENDING body r

  case "$LREF" in
    refs/tags/*) return 0 ;;
    refs/heads/*) BR="${LREF#refs/heads/}" ;;
    *) BR=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo detached) ;;
  esac
  RB="${RREF#refs/heads/}"

  BASE=""
  # Push to a long-lived branch (e.g. monitoring repos that push straight to
  # develop): review only the commits this push adds, i.e. vs the remote tip
  # being replaced -- the stdin remote-sha when we have it locally (fresher
  # than the origin/<name> tracking ref), else the tracking ref. Not vs main,
  # which would drag in the entire develop history.
  case "$RB" in
    main|master|develop)
      if git rev-parse --verify -q "${RSHA}^{commit}" >/dev/null 2>&1; then
        BASE="$RSHA"
      elif git rev-parse --verify -q "origin/$RB" >/dev/null 2>&1; then
        BASE="origin/$RB"
      fi ;;
  esac
  # Feature branch (PR workflow): review the whole branch vs its merge target.
  # Pick whichever candidate the pushed sha is fewest commits ahead of --
  # that's the actual fork point (e.g. a branch cut from develop stays 1
  # commit ahead of origin/develop but 198 ahead of origin/main, since main
  # is far behind develop) -- rather than assuming origin/HEAD (the repo's
  # default branch, usually main) is always what feature branches fork from.
  if [ -z "$BASE" ]; then
    BASE_COUNT=""
    for b in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
             origin/main origin/develop main develop; do
      [ -n "$b" ] || continue
      git rev-parse --verify -q "$b" >/dev/null || continue
      count=$(git rev-list --count "$b".."$SHA" 2>/dev/null) || continue
      if [ -z "$BASE_COUNT" ] || [ "$count" -lt "$BASE_COUNT" ]; then
        BASE="$b"; BASE_COUNT="$count"
      fi
    done
  fi
  [ -z "$BASE" ] && return 0
  MB=$(git merge-base "$SHA" "$BASE" 2>/dev/null) || return 0
  [ "$MB" = "$SHA" ] && return 0   # nothing ahead of base

  # Both keyed per-branch: with several refs in one push, a shared slot would
  # let one ref's state overwrite another's between the block and the retry.
  PASS="$(git rev-parse --git-path ".pr-review-passed-$(_sanitize "$BR")")"
  LASTREV_FILE="$(git rev-parse --git-path ".review-lastrev-$(_sanitize "$BR")")"

  # Feature branches: if a previous review on this branch already covered up
  # to LASTREV, review only LASTREV..sha this time.
  RANGE_FROM="$MB"
  case "$RB" in main|master|develop) ;; *)
    LASTREV=$(cat "$LASTREV_FILE" 2>/dev/null)
    if [ -n "${LASTREV:-}" ] && [ "$LASTREV" != "$SHA" ] \
       && git merge-base --is-ancestor "$MB" "$LASTREV" 2>/dev/null \
       && git merge-base --is-ancestor "$LASTREV" "$SHA" 2>/dev/null; then
      RANGE_FROM="$LASTREV"
    fi ;;
  esac

  if [ "$(cat "$PASS" 2>/dev/null)" = "$SHA" ]; then
    PENDING=$(session_pending_count "$REPO" "$BR")
    [ "${PENDING:-0}" -gt 0 ] && { pending_block "$PENDING"; return 2; }
    finish_ok; return 0
  fi

  # Content-coverage skip: if every non-merge commit this push adds already
  # cleared push review on some branch (recorded as .review-lastrev-*), the
  # work was reviewed where it was built -- so merging a reviewed feature
  # branch into develop sails through, while direct/unreviewed commits keep
  # the gate. Caveat: conflict resolutions inside a merge commit go unreviewed.
  UNREV=$(git rev-list --no-merges "$RANGE_FROM".."$SHA")
  if [ -n "$UNREV" ]; then
    COMMON=$(git rev-parse --git-common-dir)
    for lr in "$COMMON"/.review-lastrev-* "$COMMON"/worktrees/*/.review-lastrev-*; do
      [ -f "$lr" ] || continue
      R=$(cat "$lr" 2>/dev/null)
      git rev-parse --verify -q "$R^{commit}" >/dev/null 2>&1 || continue
      COVERED=$(git rev-list --no-merges "$RANGE_FROM".."$R" 2>/dev/null)
      [ -n "$COVERED" ] || continue
      UNREV=$(printf '%s\n' "$UNREV" | grep -vxF -f <(printf '%s\n' "$COVERED"))
      [ -z "$UNREV" ] && break
    done
  fi
  if [ -z "$UNREV" ]; then
    PENDING=$(session_pending_count "$REPO" "$BR")
    [ "${PENDING:-0}" -gt 0 ] && { pending_block "$PENDING"; return 2; }
    echo "PRE-PUSH REVIEW: 追加コミットは全てレビュー済み — スキップ (${RANGE_FROM:0:10}..${SHA:0:10})" >&2
    finish_ok; return 0
  fi

  git diff --quiet "$RANGE_FROM...$SHA" 2>/dev/null && return 0
  FILES=$(git diff --name-only --diff-filter=ACMR "$RANGE_FROM...$SHA")

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

  PROMPT="$(cat "$SELF/prompt-push.md")
このリポジトリ内で変更を自分で確認してください(read-only): \`git diff ${RANGE_FROM}...${SHA}\` を実行し、
必要な変更ファイルの全文は \`git show ${SHA}:<パス>\` で読んでください (push 対象が
checkout 中のブランチとは限らず、working tree の内容は別物のことがあります)。差分は埋め込んでいません。

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

  [ -n "$OUT" ] && rm -rf "$OUT"
  OUT=$(mktemp -d)
  { reviewer_on codex "$REVIEWERS_PUSH" && command -v codex >/dev/null 2>&1 && printf '%s' "$PROMPT" | "${GITENV[@]}" timeout "$RVTIMEOUT" codex exec --sandbox read-only --skip-git-repo-check \
      -m "$CODEX_MODEL_PUSH" -c model_reasoning_effort="$CODEX_EFFORT_PUSH" > "$OUT/codex" 2>"$OUT/codex.err"
    grep -qiE 'not supported|invalid_request|^ERROR' "$OUT/codex" && : > "$OUT/codex"; } &
  { reviewer_on copilot "$REVIEWERS_PUSH" && command -v copilot >/dev/null 2>&1 && printf '%s' "$PROMPT" | "${GITENV[@]}" timeout "$RVTIMEOUT" copilot --model "$COPILOT_MODEL_PUSH" --allow-all-tools --log-level none 2>"$OUT/copilot.err" \
      | sed -e '/^Changes /,$d' -e '/^[[:space:]]*[●│└]/d' > "$OUT/copilot"; } &
  # agy 1.1.3+ の headless はファイル読み/コマンド実行の許可を soft-deny する
  # (settings.json の allow ルールは公式書式でも効かなかった) ので、vllm と
  # 同様に差分を埋め込む (capped)。
  { if reviewer_on agy "$REVIEWERS_PUSH" && command -v agy >/dev/null 2>&1; then
      AGY_T0=$(date +%s)
      { printf '%s\n\n=== 変更差分 (このレビュアーはツール実行不可のため埋め込み) ===\n' "$PROMPT"
        git diff "$RANGE_FROM...$SHA"; } | head -c 60000 \
        | "${GITENV[@]}" timeout "$RVTIMEOUT" agy --sandbox --model "$AGY_MODEL_PUSH" 2>"$OUT/agy.err" \
        | sed '/<message>/,/<\/message>/d' > "$OUT/agy"
      python3 "$SELF/agy-usage.py" "$AGY_T0" >> "$OUT/agy.err" 2>/dev/null
    fi; } &
  # vllm is a bare model, not an agent -- it can't run git itself, so embed
  # the diff (capped) after the shared prompt.
  { if reviewer_on vllm "$REVIEWERS_PUSH"; then
      { printf '%s\n\n=== 変更差分 (このレビュアーはコマンド実行不可のため埋め込み) ===\n' "$PROMPT"
        git diff "$RANGE_FROM...$SHA"; } | head -c 60000 \
        | vllm_chat "$VLLM_MODEL_PUSH" > "$OUT/vllm" 2>"$OUT/vllm.err"
    fi; } &
  wait

  append_review_log "branch" "$REPO" "$BR" "${RANGE_FROM:0:10}..${SHA:0:10}" "$OUT"
  echo "$SHA" > "$PASS"

  if [ "${APPEND_FINDINGS:-0}" = 0 ] && [ "${APPEND_UNPARSED:-0}" = 0 ]; then
    echo "PRE-PUSH REVIEW (${RANGE_FROM:0:10}..${SHA:0:10}): 指摘なし" >&2
    PENDING=$(session_pending_count "$REPO" "$BR")
    [ "${PENDING:-0}" -gt 0 ] && { pending_block "$PENDING"; return 2; }
    finish_ok; return 0
  fi

  {
    echo "════════════════════════════════════════════════════════"
    echo " PRE-PUSH REVIEW  (${RANGE_FROM:0:10}..${SHA:0:10})  — ${REVIEWERS_PUSH} — Claude curates"
    echo "════════════════════════════════════════════════════════"
    for r in codex copilot agy vllm; do
      body=$(sed '/^[[:space:]]*$/d' "$OUT/$r" 2>/dev/null)
      [ -z "$body" ] && continue
      echo; echo "### $r"; echo "$body"
    done
    echo "════════════════════════════════════════════════════════"
    echo "Curate, address what matters (new commits), then push again."
    echo "各ラウンドの指摘への対応を1行ずつ記録してください (pending が残ると push できません):"
    echo "  $SELF/respond.sh \"1:fix/h 直した内容 2:fp 誤検知の理由\"  (fix|fp|skip|dup, /h /m /l 任意)"
    if [ "${APPEND_FINDINGS:-0}" = 0 ]; then
      echo "※ 今回はパース不能な形式外出力 (❓) のみ。内容に実質的な指摘が無ければ"
      echo "  そのまま再 push で通ります (Response は自動記入済み、respond.sh 不要)。"
    fi
    echo "Skip: git push --no-verify  /  REVIEW_SKIP=1 git push …"
  } >&2

  return 2
}

# pre-push stdin: "<local-ref> <local-sha> <remote-ref> <remote-sha>" per ref,
# forwarded by git-hooks/pre-push. The tty guard keeps a manual terminal run
# from hanging on stdin; without lines, fall back to reviewing HEAD.
PUSHED=""
[ ! -t 0 ] && PUSHED=$(awk 'NF>=4 && $2 !~ /^0+$/' 2>/dev/null)
if [ -z "$PUSHED" ]; then
  git rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0
  CURREF=$(git symbolic-ref -q HEAD 2>/dev/null || echo HEAD)
  PUSHED="$CURREF $(git rev-parse HEAD) $CURREF 0000000000000000000000000000000000000000"
fi

RC=0
while read -r LREF LSHA RREF RSHA; do
  [ -n "${LSHA:-}" ] || continue
  rc=0; review_one "$LREF" "$LSHA" "$RREF" "${RSHA:-0}" || rc=$?
  [ "$rc" -gt "$RC" ] && RC=$rc
done <<< "$PUSHED"
exit "$RC"
