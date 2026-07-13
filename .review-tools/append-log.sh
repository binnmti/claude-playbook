# Shared by review-commit.sh / review-push.sh. Called after $SELF is set.
#
# One file per "session" = everything from after the last successful push on
# a branch up to the next one: every blocked commit round, every blocked
# push attempt, appended in order. Filename is `repo__branch__timestamp.md`
# -- the timestamp guarantees no two sessions ever collide on a name, so
# there's nothing to archive/rename when a branch name gets reused later.
#
# Concurrency: a single global lock (log/.lock) serializes the "find my
# repo+branch's open session file, or start one" step across ALL repos and
# branches. That step is a handful of `echo`s, not real work (the slow part
# -- running codex/copilot/agy -- already happened before the lock is
# taken), so one lock for everything is simpler than a lock per repo+branch
# and the loss of cross-branch parallelism is negligible in practice.
#
# REVIEW_LOG.md is a generated index: open sessions ("進行中") and
# closed/pushed sessions ("完了"), each newest first. The blow-by-blow for
# any one session lives in its file: open sessions sit directly under log/,
# closed ones are moved to log/closed/ on close so the root only shows
# work in flight.
#
# Per-AI status badge: ✅ no issues   ❌N  N findings (severity breakdown is
# in the table below)   ⚠ no output (crash/timeout suspected)   ❓ output
# didn't follow the expected bullet format (raw text kept below)   — CLI not
# installed or disabled in models.conf, never ran.

_sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

# reviewer_on <name> <enabled-list> -- is this reviewer in the phase's list?
reviewer_on() { case " ${2:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# vllm_chat <model> -- OpenAI-compatible chat call, prompt on stdin, answer on
# stdout. Used for reviewers that are a bare model behind an API, not an agent
# CLI, so the caller must embed everything the model needs in the prompt.
vllm_chat() {
  python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"temperature":0,"messages":[{"role":"user","content":sys.stdin.read()}]}))' "$1" \
  | curl -sS -m "${RVTIMEOUT:-120}" "$VLLM_BASE_URL/chat/completions" \
      -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' \
      --data-binary @- \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d["choices"][0]["message"]["content"])'
}

_global_lock() {
  mkdir -p "$SELF/log"
  printf '%s' "$SELF/log/.lock"
}

# Newest session file basename under log/ for repo+sanitized-branch, empty if
# none. Prefix-anchored (a repo named "prototype" must not match
# "monitoring-prototype" sessions -- grep -F substring matching did).
_latest_session() {
  ls -1 "$SELF/log" 2>/dev/null | awk -v p="${1}__${2}__" 'index($0,p)==1' | sort -r | head -1
}

# Finds the most recent non-closed session file for repo+branch, or decides
# a fresh filename if none exists / the most recent one is already closed.
# Must be called only while already holding the global lock.
_resolve_session_file() {
  local repo="$1" branch="$2"
  local branch_san; branch_san=$(_sanitize "$branch")
  local LOGDIR="$SELF/log"
  local candidate
  candidate=$(_latest_session "$repo" "$branch_san")
  if [ -n "$candidate" ] && ! grep -q '^<!-- SESSION CLOSED -->$' "$LOGDIR/$candidate" 2>/dev/null; then
    printf '%s\n' "$LOGDIR/$candidate"
  else
    local ts; ts=$(date '+%Y%m%dT%H%M%S%N')
    printf '%s\n' "$LOGDIR/${repo}__${branch_san}__${ts}.md"
  fi
}

# Read-only: up to the 3 most recent session files for repo+branch (oldest
# first, one absolute path per line) -- open or closed, curated or not. A
# pending Response still means the finding was already reported, so it must
# not be re-raised on unchanged code; the Response line is enrichment (fixed
# vs false positive), not the gate. Requiring a curated Response here was
# why dedup never worked: Responses were rarely filled, so reviewers never
# saw any history and kept repeating themselves.
# codex/copilot/agy can't read paths outside the repo they're sandboxed in,
# so callers must cat these into the target repo (e.g. under .git/) before
# pointing a reviewer at them -- see review-commit.sh / review-push.sh.
session_history_files() {
  local repo="$1" branch="$2"
  local branch_san; branch_san=$(_sanitize "$branch")
  local LOGDIR="$SELF/log"
  # open sessions live in log/, closed ones in log/closed/ -- both count as
  # history. Filenames end in a timestamp, so sorting by basename gives
  # recency regardless of directory.
  { ls -1 "$LOGDIR" 2>/dev/null | sed "s|^|$LOGDIR/|"
    ls -1 "$LOGDIR/closed" 2>/dev/null | sed "s|^|$LOGDIR/closed/|"; } \
    | grep -F "/${repo}__${branch_san}__" \
    | awk -F/ '{print $NF "\t" $0}' | sort -k1,1r | head -3 | sort -k1,1 | cut -f2
}

# Read-only: how many rounds in the current open session for repo+branch
# still have an unfilled Response. 0 if there's no open session, or it's
# already closed, or every round is curated. Used to gate the "retry at the
# same HEAD passes silently" escape hatch in review-push.sh (commit-side has
# no pending gate by design: Responses are due by push, not per commit)
# -- so a retry can't slip past rounds nobody ever curated
# (that's how the same false positive kept resurfacing across pushes: the
# escape hatch only checks whether the ref changed, never whether the
# previous round's Response got filled in).
session_pending_count() {
  local repo="$1" branch="$2"
  local branch_san; branch_san=$(_sanitize "$branch")
  local LOGDIR="$SELF/log"
  local candidate
  candidate=$(_latest_session "$repo" "$branch_san")
  [ -n "$candidate" ] || { printf '0\n'; return 0; }
  local SESSFILE="$LOGDIR/$candidate"
  if grep -q '^<!-- SESSION CLOSED -->$' "$SESSFILE" 2>/dev/null; then
    printf '0\n'
  else
    grep -c '^\*\*Response:\*\* _(pending)_$' "$SESSFILE" 2>/dev/null
  fi
}

# Sets APPEND_FINDINGS (global) to the number of real findings logged, so
# callers can pass cleanly (no block) when a round found nothing.
# APPEND_UNPARSED (global) counts ❓ reviewers -- output that had neither
# NO_ISSUES nor any parseable finding. Those may hide real findings, so
# callers block once on them too instead of passing as "指摘なし".
append_review_log() {
  local KIND="$1" REPO="$2" BRANCH="$3" REF="$4" OUTDIR="$5"
  APPEND_FINDINGS=0
  APPEND_UNPARSED=0

  # Rows: sortA \t sortB \t rank \t icon \t loc \t ai \t finding
  #   sortA=0 real findings (sortB=location, version-sorted so :10 > :9)
  #   sortA=1 status rows -- no issues(9) / no output(8) / unparsed(7)
  local ROWS; ROWS=$(mktemp)
  for r in codex copilot agy vllm; do
    local f="$OUTDIR/$r"
    [ -e "$f" ] || continue   # CLI not installed -- this reviewer never ran
    # unwrap markdown links (agy emits `[path:N](file://…)` inside the
    # location brackets, which broke the table parse below)
    local body; body=$(sed -E -e 's/\[([^][]*)\]\((file|https?):[^)]*\)/\1/g' -e '/^[[:space:]]*$/d' "$f")
    if [ -z "$body" ]; then
      local errtail; errtail=$(tail -n 2 "$OUTDIR/$r.err" 2>/dev/null | tr '\n\t' '  ' | sed 's/|/\\|/g' | cut -c1-200)
      printf '1\t%s\t8\t⚠\t—\t%s\t(出力なし%s)\n' "$r" "$r" "${errtail:+ — stderr: $errtail}" >> "$ROWS"
      continue
    fi
    local hits
    hits=$(printf '%s\n' "$body" | sed -E -n \
      's/^-[[:space:]]*\[([^]]+)\][[:space:]]*(.*)\(重大度:[[:space:]]*(high|med|low)[^)]*\)[[:space:]]*$/\1\t\2\t\3/Ip')
    if [ -n "$hits" ]; then
      while IFS=$'\t' read -r loc finding sev; do
        [ -z "$loc" ] && continue
        sev=$(printf '%s' "$sev" | tr 'A-Z' 'a-z')
        local rank icon
        case "$sev" in
          high) rank=0; icon="🔴 high" ;;
          med)  rank=1; icon="🟡 med"  ;;
          low)  rank=2; icon="🟢 low"  ;;
          *)    rank=3; icon="$sev"    ;;
        esac
        loc=$(printf '%s' "$loc" | sed 's/|/\\|/g')
        finding=$(printf '%s' "$finding" | sed -e 's/|/\\|/g' -e 's/[[:space:]]*$//')
        printf '0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$loc" "$rank" "$icon" "$loc" "$r" "$finding" >> "$ROWS"
      done <<< "$hits"
    elif printf '%s\n' "$body" | grep -qw 'NO_ISSUES'; then
      # verdict token present and no findings parsed -- clean, even when the
      # reviewer chatters before it (those rounds used to pile up as ❓)
      printf '1\t%s\t9\t✅\t—\t%s\t問題なし\n' "$r" "$r" >> "$ROWS"
    else
      local oneline; oneline=$(printf '%s' "$body" | tr '\n' ' ' | sed 's/|/\\|/g')
      printf '1\t%s\t7\t❓\t—\t%s\t%s\n' "$r" "$r" "$oneline" >> "$ROWS"
    fi
  done

  if [ ! -s "$ROWS" ]; then
    rm -f "$ROWS"
    return 0   # no reviewer CLI available at all -- nothing to log
  fi
  APPEND_FINDINGS=$(awk -F'\t' '$1==0' "$ROWS" | wc -l)
  APPEND_UNPARSED=$(awk -F'\t' '$1==1 && $3==7' "$ROWS" | wc -l)

  local AIROWS; AIROWS=$(mktemp)
  local BADGELINE="" badge r
  for r in codex copilot agy vllm; do
    awk -F'\t' -v ai="$r" '$6==ai' "$ROWS" > "$AIROWS"
    if [ ! -s "$AIROWS" ]; then
      badge="—"
    else
      local n; n=$(awk -F'\t' '$1==0' "$AIROWS" | wc -l)
      if [ "$n" -gt 0 ]; then
        badge="❌${n}"
      else
        local rank; rank=$(awk -F'\t' '{print $3}' "$AIROWS" | head -1)
        case "$rank" in
          9) badge="✅" ;;
          8) badge="⚠" ;;
          *) badge="❓" ;;
        esac
      fi
    fi
    BADGELINE="${BADGELINE:+$BADGELINE  ·  }$r $badge"
  done
  rm -f "$AIROWS"

  local DISPLAY_TS; DISPLAY_TS=$(date '+%Y-%m-%d %H:%M %Z')

  # which model each enabled reviewer ran with, from the models.conf vars
  # (<NAME>_MODEL_<PHASE>) -- one compact line inside the details body so the
  # summary row stays short
  local PH LIST MLINE="" mr mv m
  case "$KIND" in
    commit) PH=COMMIT; LIST="${REVIEWERS_COMMIT:-}" ;;
    *)      PH=PUSH;   LIST="${REVIEWERS_PUSH:-}" ;;
  esac
  for mr in $LIST; do
    mv="${mr^^}_MODEL_${PH}"; m="${!mv:-}"
    [ -z "$m" ] && continue
    if [ "$mr" = codex ]; then mv="CODEX_EFFORT_${PH}"; m="$m/${!mv:-}"; fi
    MLINE="${MLINE:+$MLINE · }${mr}=${m}"
  done

  local SORTED; SORTED=$(mktemp)
  sort -t $'\t' -k1,1n -k2,2V -k3,3n "$ROWS" > "$SORTED"

  local LOCK; LOCK=$(_global_lock)
  (
    flock -x 200
    local SESSFILE; SESSFILE=$(_resolve_session_file "$REPO" "$BRANCH")
    {
      echo "<details>"
      echo "<summary>${DISPLAY_TS} — (${KIND}, \`${REF}\`) — ${BADGELINE}</summary>"
      echo
      [ -n "$MLINE" ] && { echo "_models: ${MLINE}_"; echo; }
      echo "| 重大度 | 場所 | AI | 指摘 |"
      echo "|---|---|---|---|"
      while IFS=$'\t' read -r _sortA _sortB _rank icon loc ai finding; do
        [ "$loc" != "—" ] && loc="\`$loc\`"
        printf '| %s | %s | %s | %s |\n' "$icon" "$loc" "$ai" "$finding"
      done < "$SORTED"
      echo
      if [ "$APPEND_FINDINGS" -gt 0 ]; then
        echo "**Response:** _(pending)_"
      elif [ "$APPEND_UNPARSED" -gt 0 ]; then
        echo "**Response:** 形式外出力のみ・指摘としてはパース不能 (自動記入)"
      else
        echo "**Response:** 指摘なし (自動記入)"
      fi
      echo
      echo "</details>"
      echo
    } >> "$SESSFILE"
  ) 200>"$LOCK"

  rm -f "$ROWS" "$SORTED"
  rebuild_review_log
}

# Called from review-push.sh once a push actually goes through (review
# didn't block). Seals the session file and adds one line to the root index.
# No-op if there's no open session for this repo+branch (nothing happened
# worth a log line -- e.g. a fully silent first-try clean push).
close_session() {
  local REPO="$1" BRANCH="$2" REF="$3"
  local branch_san; branch_san=$(_sanitize "$BRANCH")
  local LOGDIR="$SELF/log"
  mkdir -p "$LOGDIR"
  local LOCK; LOCK=$(_global_lock)
  (
    flock -x 200
    local candidate
    candidate=$(_latest_session "$REPO" "$branch_san")
    [ -z "$candidate" ] && exit 0
    local SESSFILE="$LOGDIR/$candidate"
    grep -q '^<!-- SESSION CLOSED -->$' "$SESSFILE" 2>/dev/null && exit 0
    local rounds; rounds=$(grep -c '^<details>' "$SESSFILE" 2>/dev/null); rounds=${rounds:-0}
    {
      echo "<!-- SESSION CLOSED -->"
      echo "✅ push 成立: \`${REF}\`（${rounds}ラウンド）"
    } >> "$SESSFILE"
    mkdir -p "$LOGDIR/closed"
    mv "$SESSFILE" "$LOGDIR/closed/"
  ) 200>"$LOCK"

  rebuild_review_log
}

# Regenerates REVIEW_LOG.md: open sessions ("進行中") and closed/pushed
# sessions ("完了"), each newest first (by file mtime, since filenames start
# with repo/branch text rather than a sortable timestamp prefix). Called
# after every round (not just close), so root reflects work the moment it
# starts. Safe to call redundantly -- it only ever reads what's already
# durably on disk under log/, so a lost race here just means a stale view
# until the next append/close rebuilds it again.
rebuild_review_log() {
  local LOG="$SELF/REVIEW_LOG.md"
  local LOGDIR="$SELF/log"
  mkdir -p "$LOGDIR"
  local TMP; TMP=$(mktemp)
  chmod 644 "$TMP"
  {
    cat <<'HEADER'
# Review Log

進行中のセッション（まだpushが通っていない、直近の状態）と、push成立した
セッションの索引。詳しい指摘文・重大度は各行のリンク先を開く。

HEADER
    echo "## 進行中"
    echo
    local f path repo branch rounds pending lastresp any
    any=0
    for f in $(ls -tp "$LOGDIR" 2>/dev/null | grep -v '/$'); do
      [[ "$f" == .* ]] && continue
      path="$LOGDIR/$f"
      grep -q '^<!-- SESSION CLOSED -->$' "$path" && continue
      any=1
      repo=$(printf '%s' "$f" | awk -F'__' '{print $1}')
      branch=$(printf '%s' "$f" | awk -F'__' '{print $2}')
      # no `|| echo 0`: grep -c already prints 0 (while exiting 1), so the
      # fallback produced a doubled "0\n0" in the index line
      rounds=$(grep -c '^<details>' "$path" 2>/dev/null); rounds=${rounds:-0}
      pending=$(grep -c '^\*\*Response:\*\* _(pending)_$' "$path" 2>/dev/null); pending=${pending:-0}
      lastresp=$(grep '^\*\*Response:\*\*' "$path" | tail -1)
      lastresp="${lastresp#\*\*Response:\*\* }"
      echo "- 🔄 **${repo}** @ \`${branch}\` — ${rounds}ラウンド, Response未記入 ${pending}件, 最新: ${lastresp} — [詳細](log/${f})"
    done
    [ "$any" = 0 ] && echo "_(進行中のセッションなし)_"
    echo
    echo "## 完了 (push成立)"
    echo
    any=0
    local closeline
    for f in $(ls -t "$LOGDIR/closed" 2>/dev/null); do
      [[ "$f" == .* ]] && continue
      path="$LOGDIR/closed/$f"
      any=1
      closeline=$(grep '^✅' "$path" | tail -1)
      closeline=${closeline#✅ push 成立: }
      closeline=${closeline#✅ }
      repo=$(printf '%s' "$f" | awk -F'__' '{print $1}')
      branch=$(printf '%s' "$f" | awk -F'__' '{print $2}')
      echo "- **${repo}** @ \`${branch}\` — ${closeline} — [詳細](log/closed/${f})"
    done
    [ "$any" = 0 ] && echo "_(まだ無し)_"
  } > "$TMP"
  mv "$TMP" "$LOG"
}
