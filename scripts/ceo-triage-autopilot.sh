#!/bin/bash
# ceo-triage-autopilot.sh — Poll merged PRs, run ticket-triage on new merges.
#
# State machine, not signal generator. On a cron tick with no new merges since
# last_merge_check, writes one state file (overwrite), one log line (append),
# and does nothing else. On new merges, spawns `claude --print` to invoke
# /ticket-triage, parses a strict fenced-JSON output, and appends the top-3
# results to $CEO_VAULT/CEO/inbox.md with per-ticket dedup markers.
#
# Invoked by ceo-cron.sh when the ticket-triage-autopilot playbook fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

: "${HOME:?HOME must be set before ceo-triage-autopilot}"
VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

ALERTS_DIR="$CEO_DIR/alerts"
LOG_DIR="$CEO_DIR/log/triage-autopilot"
STATE_FILE="$ALERTS_DIR/triage-autopilot-$HOST.md"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).md"
INBOX_FILE="$CEO_DIR/inbox.md"

mkdir -p "$ALERTS_DIR" "$LOG_DIR"
touch "$INBOX_FILE"

GH_BIN="${CEO_GH_BIN:-gh}"
CLAUDE_BIN="${CEO_TRIAGE_CLAUDE_BIN:-claude}"
REPO_LIST_FILE="${CEO_TRIAGE_REPO_LIST:-$HOME/.config/branch-cleanup/repos.md}"
PIPELINE="${CEO_TRIAGE_PIPELINE:-inbox}"
MAX_RETRIES=3

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

# ---- Read prior state. ---------------------------------------------------
PRIOR_STATUS=""
PRIOR_SINCE=""
PRIOR_LAST_CHECK=""
PRIOR_FAILS=0

_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *)
        printf 'WARN: ceo-triage-autopilot: unrecognized prior status %q\n' "$PRIOR_STATUS" >&2
        PRIOR_STATUS="unknown"
        ;;
    esac
    ;;
  1)
    printf 'WARN: ceo-triage-autopilot: state file %s missing status field\n' "$STATE_FILE" >&2
    PRIOR_STATUS="unknown"
    ;;
  2) PRIOR_STATUS="" ;;  # first run
esac
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since) || PRIOR_SINCE=""
PRIOR_LAST_CHECK=$(ceo_read_alert_field "$STATE_FILE" last_merge_check) || PRIOR_LAST_CHECK=""
_pf=$(ceo_read_alert_field "$STATE_FILE" consec_failures) || _pf=""
if [[ "$_pf" =~ ^[0-9]+$ ]]; then
  PRIOR_FAILS="$_pf"
elif [ -n "$_pf" ]; then
  printf 'WARN: ceo-triage-autopilot: corrupted consec_failures field %q; resetting to 0\n' "$_pf" >&2
fi

FIRST_RUN=0
if [ -z "$PRIOR_LAST_CHECK" ]; then
  FIRST_RUN=1
fi

# ---- Parse repo list. ----------------------------------------------------
# Markdown table: "| `repo-name` | `local-path` |"
# Extract the second column (local path) by stripping backticks and pipes.
REPO_PATHS=()
if [ -r "$REPO_LIST_FILE" ]; then
  while IFS= read -r line; do
    case "$line" in
      "| Repo "*|"|------"*|"|---"*|"") continue ;;
    esac
    [[ "$line" != "|"* ]] && continue
    path=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//')
    [ -z "$path" ] && continue
    REPO_PATHS+=("$path")
  done < "$REPO_LIST_FILE"
else
  printf 'WARN: ceo-triage-autopilot: repo list %s not readable; nothing to poll\n' "$REPO_LIST_FILE" >&2
fi

# ---- Detect new merges since PRIOR_LAST_CHECK. ---------------------------
# First run: baseline only, do not spawn triage.
NEW_MERGES_JSON="[]"
NEW_MERGE_COUNT=0
TICK_HAD_ERRORS=0
LAST_ERROR=""
if [ "$FIRST_RUN" -eq 0 ] && [ "${#REPO_PATHS[@]}" -gt 0 ]; then
  SEARCH_SINCE="$PRIOR_LAST_CHECK"
  MERGES_PARTS=()
  for repo_path in "${REPO_PATHS[@]}"; do
    [ -d "$repo_path/.git" ] || [ -f "$repo_path/.git" ] || continue
    repo_slug=$(git -C "$repo_path" config --get remote.origin.url 2>/dev/null \
      | sed -E 's#.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')
    if [ -z "$repo_slug" ] || [[ "$repo_slug" != */* ]]; then
      printf 'WARN: ceo-triage-autopilot: could not derive OWNER/REPO from %s\n' "$repo_path" >&2
      TICK_HAD_ERRORS=1
      LAST_ERROR="missing_remote:$(basename "$repo_path")"
      continue
    fi
    gh_stderr=$(mktemp)
    if out=$("$GH_BIN" pr list --repo "$repo_slug" \
                --search "is:merged author:@me merged:>=$SEARCH_SINCE" \
                --json number,title,mergedAt,url \
                --limit 100 2>"$gh_stderr"); then
      rm -f "$gh_stderr"
      if [ -n "$out" ] && [ "$out" != "[]" ]; then
        if annotated=$(printf '%s' "$out" | jq -c --arg r "$repo_slug" 'map(. + {repo: $r})' 2>/dev/null); then
          [ -n "$annotated" ] && [ "$annotated" != "[]" ] && MERGES_PARTS+=("$annotated")
        else
          printf 'WARN: ceo-triage-autopilot: jq annotation failed for %s\n' "$repo_slug" >&2
          TICK_HAD_ERRORS=1
          LAST_ERROR="jq_annotate:$repo_slug"
        fi
      fi
    else
      printf 'WARN: ceo-triage-autopilot: gh pr list failed for %s: %s\n' "$repo_slug" "$(head -c 200 "$gh_stderr" 2>/dev/null)" >&2
      rm -f "$gh_stderr"
      TICK_HAD_ERRORS=1
      LAST_ERROR="gh_failed:$repo_slug"
    fi
  done
  if [ "${#MERGES_PARTS[@]}" -gt 0 ]; then
    NEW_MERGES_JSON=$(printf '%s\n' "${MERGES_PARTS[@]}" | jq -s 'add // []' 2>/dev/null || printf '[]')
    NEW_MERGE_COUNT=$(printf '%s' "$NEW_MERGES_JSON" | jq 'length' 2>/dev/null || echo 0)
  fi
fi

# ---- Classify merges by repo owner, triage per source. ------------------
# ZenHub and the nhangenam account are AM-only; personal nhangen/* repos have
# no ZenHub board so they triage from GitHub issues (#133). Owners in neither
# set are skipped (logged) — their merges still advance the cursor so they are
# not re-evaluated every tick.
ZENHUB_OWNERS="${CEO_TRIAGE_ZENHUB_OWNERS:-awesomemotive nhangenam}"
GITHUB_OWNERS="${CEO_TRIAGE_GITHUB_OWNERS:-nhangen}"

_classify_owner() {  # $1 = owner/repo slug -> zenhub | github | skip
  local owner="${1%%/*}"
  case " $ZENHUB_OWNERS " in *" $owner "*) printf 'zenhub'; return 0 ;; esac
  case " $GITHUB_OWNERS " in *" $owner "*) printf 'github'; return 0 ;; esac
  printf 'skip'
}

_merge_lines() {  # stdin = merges JSON array -> shell-safe "- repo#n: title" lines
  jq -r '.[] | "- \(.repo)#\(.number): \(.title)"' 2>/dev/null \
    | sed 's/`/'\''/g; s/\$/_/g'
}

_zenhub_prompt() {  # $1 = merge_lines
  cat <<PROMPT_EOF
You are running on behalf of an automated playbook. Newly merged PRs since the last triage:

$1

Invoke the /ticket-triage skill against the "${PIPELINE}" pipeline. Output exactly one fenced JSON block at the end of your response with this schema, and nothing else after it:

\`\`\`json
{"tickets":[{"id":"<ticket-id>","title":"<short title>","url":"<url>","score":<0..1>,"reason":"<one-line>"}]}
\`\`\`

At most 3 tickets. If triage cannot run (auth failure, no candidates), emit \`{"tickets":[]}\`. Do not emit any other JSON block.
PROMPT_EOF
}

_github_prompt() {  # $1 = owner/repo slug, $2 = merge_lines
  cat <<PROMPT_EOF
You are running on behalf of an automated playbook. Newly merged PRs since the last triage:

$2

Invoke the /ticket-triage skill against the "$1" repo (GitHub-issues source — a personal repo with no ZenHub board). Output exactly one fenced JSON block at the end of your response with this schema, and nothing else after it:

\`\`\`json
{"tickets":[{"id":"<ticket-id>","title":"<short title>","url":"<url>","score":<0..1>,"reason":"<one-line>"}]}
\`\`\`

At most 3 tickets. If triage cannot run (no candidates), emit \`{"tickets":[]}\`. Do not emit any other JSON block.
PROMPT_EOF
}

# Spawn one triage, parse the fenced tickets JSON, append up to 3 deduped lines
# to the inbox. Updates TICKETS_WRITTEN; returns 0 on success, 1 on any failure.
_triage_spawn() {  # $1 = prompt text
  local prompt="$1" claude_out json_block marker line
  if ! claude_out=$("$CLAUDE_BIN" --print "$prompt" 2>/dev/null); then
    printf 'WARN: ceo-triage-autopilot: claude invocation failed\n' >&2
    return 1
  fi
  json_block=$(printf '%s\n' "$claude_out" | awk '
    /^```json[[:space:]]*$/ { capture=1; buf=""; next }
    /^```[[:space:]]*$/ && capture { print buf; capture=0; buf=""; next }
    capture { buf = buf $0 "\n" }
  ' | tail -c 65536)
  if [ -z "$json_block" ] || ! printf '%s' "$json_block" | jq -e '.tickets | type == "array" and length <= 3' >/dev/null 2>&1; then
    printf 'WARN: ceo-triage-autopilot: claude output had no valid tickets JSON block\n' >&2
    return 1
  fi
  while IFS=$'\t' read -r tid title url score reason; do
    [ -z "$tid" ] && continue
    marker="<!-- triage-autopilot:$tid -->"
    if grep -qF -- "$marker" "$INBOX_FILE" 2>/dev/null; then
      continue
    fi
    line="- [ ] Triage: **$tid** — $title (score $score; $reason) [$url] $marker"
    if printf '%s\n' "$line" >> "$INBOX_FILE"; then
      TICKETS_WRITTEN=$((TICKETS_WRITTEN + 1))
    else
      printf 'ERROR: ceo-triage-autopilot: failed to append to %s\n' "$INBOX_FILE" >&2
      LAST_ERROR="inbox_append_failed"
      return 1
    fi
  done < <(printf '%s' "$json_block" | jq -r '.tickets[] | [.id, .title, .url, (.score|tostring), .reason] | @tsv')
  return 0
}

# ---- Spawn triage if new merges seen. -----------------------------------
TRIAGE_RAN=0
TRIAGE_OK=0
TICKETS_WRITTEN=0
CONSEC_FAILURES="$PRIOR_FAILS"
SPAWNS_ATTEMPTED=0
SPAWNS_FAILED=0

if [ "$NEW_MERGE_COUNT" -gt 0 ]; then
  # Distinct slugs among this tick's merges.
  SLUGS=()
  while IFS= read -r _slug; do
    [ -n "$_slug" ] && SLUGS+=("$_slug")
  done < <(printf '%s' "$NEW_MERGES_JSON" | jq -r '[.[].repo] | unique[]' 2>/dev/null)

  # ZenHub: one spawn covering all AM merges — the OM board is unified across
  # products, so a single pipeline triage serves every AM repo.
  zenhub_merges=$(printf '%s' "$NEW_MERGES_JSON" | jq -c --arg owners "$ZENHUB_OWNERS" '
    ($owners | split(" ")) as $o
    | [.[] | (.repo | split("/")[0]) as $own | select(($o | index($own)) != null)]' 2>/dev/null || printf '[]')
  if [ "$(printf '%s' "$zenhub_merges" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    SPAWNS_ATTEMPTED=$((SPAWNS_ATTEMPTED + 1))
    _ml=$(printf '%s' "$zenhub_merges" | _merge_lines)
    if ! _triage_spawn "$(_zenhub_prompt "$_ml")"; then SPAWNS_FAILED=$((SPAWNS_FAILED + 1)); fi
  fi

  # GitHub: one spawn per distinct personal repo (each needs its own slug).
  for _slug in "${SLUGS[@]}"; do
    [ "$(_classify_owner "$_slug")" = "github" ] || continue
    SPAWNS_ATTEMPTED=$((SPAWNS_ATTEMPTED + 1))
    _rm=$(printf '%s' "$NEW_MERGES_JSON" | jq -c --arg r "$_slug" '[.[] | select(.repo == $r)]' 2>/dev/null || printf '[]')
    _ml=$(printf '%s' "$_rm" | _merge_lines)
    if ! _triage_spawn "$(_github_prompt "$_slug" "$_ml")"; then SPAWNS_FAILED=$((SPAWNS_FAILED + 1)); fi
  done

  # Skipped owners: log, no spawn. Their merges still advance the cursor.
  for _slug in "${SLUGS[@]}"; do
    [ "$(_classify_owner "$_slug")" = "skip" ] || continue
    printf 'INFO: ceo-triage-autopilot: skipping %s (owner not routed to zenhub or github)\n' "$_slug" >&2
  done

  if [ "$SPAWNS_ATTEMPTED" -gt 0 ]; then
    TRIAGE_RAN=1
    if [ "$SPAWNS_FAILED" -eq 0 ]; then
      TRIAGE_OK=1
      CONSEC_FAILURES=0
    else
      CONSEC_FAILURES=$((CONSEC_FAILURES + 1))
    fi
  fi
fi

# ---- Resolve CURRENT_STATUS + last_merge_check advancement. ---------------
# Fire only when a triage actually ran; merges that were all skip-routed (no
# spawn) are a clear tick that still advances the cursor.
if [ "$SPAWNS_ATTEMPTED" -gt 0 ]; then
  CURRENT_STATUS="firing"
else
  CURRENT_STATUS="clear"
fi

# Advance the cursor when:
#   - first run (baseline)
#   - no new merges this tick
#   - new merges + triage succeeded
#   - new merges + triage failed BUT we've hit the retry cap (give up)
if [ "$FIRST_RUN" -eq 1 ]; then
  NEW_LAST_CHECK="$NOW"
elif [ "$TICK_HAD_ERRORS" -eq 1 ]; then
  # ANY per-repo gh/jq error holds the cursor. A partial success would
  # otherwise drop the failed repo's merge window permanently. Re-running
  # triage next tick is cheap (marker dedup no-ops already-written tickets).
  NEW_LAST_CHECK="$PRIOR_LAST_CHECK"
elif [ "$SPAWNS_ATTEMPTED" -eq 0 ] || [ "$TRIAGE_OK" -eq 1 ]; then
  # No merges, all-skip merges, or every spawned source succeeded.
  NEW_LAST_CHECK="$NOW"
elif [ "$CONSEC_FAILURES" -ge "$MAX_RETRIES" ]; then
  NEW_LAST_CHECK="$NOW"
  giveup_marker="<!-- triage-autopilot:giveup:$(date +%Y-%m-%d) -->"
  if ! grep -qF -- "$giveup_marker" "$INBOX_FILE" 2>/dev/null; then
    printf -- '- [ ] Triage autopilot gave up after %d tries — manual /ticket-triage needed for merges since %s %s\n' \
      "$CONSEC_FAILURES" "$PRIOR_LAST_CHECK" "$giveup_marker" >> "$INBOX_FILE"
  fi
  printf 'WARN: ceo-triage-autopilot: %d consecutive failures; advancing cursor anyway\n' "$CONSEC_FAILURES" >&2
  CONSEC_FAILURES=0
else
  NEW_LAST_CHECK="$PRIOR_LAST_CHECK"
fi

# SINCE: only reset on real transition into firing.
if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
fi

# ---- Atomic state write. -------------------------------------------------
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  printf 'ERROR: ceo-triage-autopilot: mktemp failed\n' >&2
  exit 1
}
trap 'rm -f "$STATE_TMP"' EXIT

if ! {
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field last_merge_check="$NEW_LAST_CHECK" \
    --field new_merges="$NEW_MERGE_COUNT" \
    --field triage_ran="$TRIAGE_RAN" \
    --field tickets_written="$TICKETS_WRITTEN" \
    --field consec_failures="$CONSEC_FAILURES" \
    --field last_error="${LAST_ERROR:-none}"
  printf '\n# Triage Autopilot — %s\n\n' "$HOST"
  if [ "$FIRST_RUN" -eq 1 ]; then
    printf 'Baseline established. The first cron tick after install does not trigger triage; the next merge will.\n'
  elif [ "$NEW_MERGE_COUNT" -gt 0 ]; then
    printf 'New merges seen this tick: %d. Triage ran: %d. Tickets written: %d.\n' \
      "$NEW_MERGE_COUNT" "$TRIAGE_RAN" "$TICKETS_WRITTEN"
  else
    printf 'No new merges since %s.\n' "$PRIOR_LAST_CHECK"
  fi
} > "$STATE_TMP"; then
  printf 'ERROR: ceo-triage-autopilot: failed to render state\n' >&2
  exit 1
fi

mv "$STATE_TMP" "$STATE_FILE"
trap - EXIT

if ! printf '%s status=%s new_merges=%d triage_ran=%d tickets_written=%d consec_failures=%d\n' \
    "$NOW" "$CURRENT_STATUS" "$NEW_MERGE_COUNT" "$TRIAGE_RAN" "$TICKETS_WRITTEN" "$CONSEC_FAILURES" \
    >> "$LOG_FILE" 2>/dev/null; then
  printf 'WARN: ceo-triage-autopilot: failed to append log line to %s\n' "$LOG_FILE" >&2
fi

exit 0
