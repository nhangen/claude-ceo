#!/bin/bash
# ceo-triage-autopilot.sh — v2 adapter over the portable ticket-triage skill.
#
# The skill (nhangen/llm-tools home/.claude/skills/ticket-triage) owns the work:
# triage_update.py silently refreshes a per-host event-sourced cache (its own
# cursor, detection, and per-repo recompute); triage_surface.py reports the
# high-priority tickets that have NEWLY appeared since the last surface. This
# script is the CEO adapter: per owner it refreshes the cache, reads the
# transitions, and escalates each to ONE inbox line — state machine, not signal
# generator. A tick with no transition writes only the state file + a log line.
#
# This replaces the v1 merge-poller: cursor/recompute/dedup now live in the
# skill, so the adapter no longer parses merges or spawns /ticket-triage itself.
#
# Invoked by ceo-cron.sh / ceo-schedulerd when the ticket-triage-autopilot
# playbook fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

# Default this tick to a silent "noop" for cron's #173 success-notify gate; a
# real firing tick upgrades it to "fired" below. Set early so every exit path
# (including the skill-not-found bail) leaves a correct outcome.
[ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ] && printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"

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

PY="${CEO_TRIAGE_PYTHON:-python3}"
SKILL_DIR="${CEO_TRIAGE_SKILL_DIR:-$HOME/.claude/skills/ticket-triage/scripts}"
OWNERS="${CEO_TRIAGE_OWNERS:-nhangen}"
UPDATER="$SKILL_DIR/triage_update.py"
SURFACER="$SKILL_DIR/triage_surface.py"

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status 2>/dev/null) || PRIOR_STATUS=""
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since 2>/dev/null) || PRIOR_SINCE=""

_log() { printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

_write_state() {  # $1=status $2=since $3..=extra "k=v"
  local status="$1" since="$2"; shift 2
  local -a fields=()
  local kv; for kv in "$@"; do fields+=(--field "$kv"); done
  local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX") || { echo "ERROR: mktemp failed" >&2; return 1; }
  trap 'rm -f "$tmp"' RETURN
  if ! {
    ceo_write_alert_frontmatter --status="$status" --since="$since" \
      --last-check="$NOW" --host="$HOST" "${fields[@]}"
    printf '\n# Triage Autopilot — %s\n\n' "$HOST"
    printf 'Owners: %s. Surfaced this tick: %s.\n' "$OWNERS" "${EVENTS_TOTAL:-0}"
  } > "$tmp"; then
    echo "ERROR: failed to render state" >&2; return 1
  fi
  mv "$tmp" "$STATE_FILE"; trap - RETURN
}

# A missing skill install is a config error, not a transition. Record it on the
# state file (failure-aware), log it, and exit 0 so the scheduler isn't wedged.
if [ ! -f "$UPDATER" ] || [ ! -f "$SURFACER" ]; then
  _log "FATAL skill not found at $SKILL_DIR (set CEO_TRIAGE_SKILL_DIR)"
  EVENTS_TOTAL=0
  _write_state clear "${PRIOR_SINCE:-$NOW}" "last_error=skill_not_found:$SKILL_DIR" "events_total=0" || true
  exit 0
fi

PRIOR_FAILS=$(ceo_read_alert_field "$STATE_FILE" consec_failures 2>/dev/null) || PRIOR_FAILS=""
[[ "$PRIOR_FAILS" =~ ^[0-9]+$ ]] || PRIOR_FAILS=0
MAX_FAILS=3

EVENTS_TOTAL=0
FAILED_OWNERS=""
INCOMPLETE=0

for owner in $OWNERS; do
  # 1. Refresh the cache silently. Exit 1 = incomplete reconcile (cursor held by
  #    the skill); record it but still read whatever the cache has.
  owner_incomplete=0
  if ! "$PY" "$UPDATER" "$owner" >/dev/null 2>>"$LOG_FILE"; then
    INCOMPLETE=1; owner_incomplete=1; _log "WARN update incomplete for $owner"
  fi

  # 2. Read transitions WITHOUT consuming (preview). Consume only after the
  #    inbox write succeeds, so a failed append is retried next tick rather than
  #    lost (the inbox dedup marker prevents a double-append meanwhile).
  surf=$("$PY" "$SURFACER" "$owner" 2>>"$LOG_FILE") || { FAILED_OWNERS="$FAILED_OWNERS $owner"; _log "ERROR surface failed for $owner"; continue; }
  # Non-throwing boundary: a 0-exit with unparseable output must NOT read as
  # "no transitions" (jq would yield an empty stream and the tick would look
  # clear while real events are dropped and then consumed). Route it to the
  # failure path and never --mark it. (non-throwing-client-success-check)
  if ! printf '%s' "$surf" | jq empty >/dev/null 2>&1; then
    FAILED_OWNERS="$FAILED_OWNERS $owner"; _log "ERROR malformed surface JSON for $owner"; continue
  fi

  appended_ok=1
  while IFS=$'\t' read -r slug number title labels url; do
    [ -n "$number" ] || continue
    marker="<!-- triage-surface:${slug}#${number} -->"
    grep -qF -- "$marker" "$INBOX_FILE" 2>/dev/null && continue
    if printf -- '- [ ] **Triage:** new high-priority %s#%s — %s [%s] %s %s\n' \
         "$slug" "$number" "$title" "$labels" "$url" "$marker" >> "$INBOX_FILE"; then
      EVENTS_TOTAL=$((EVENTS_TOTAL + 1))
    else
      appended_ok=0; _log "ERROR inbox append failed for ${slug}#${number}"
    fi
  done < <(printf '%s' "$surf" | jq -r '.events[]? | [.slug, (.number|tostring), (.title//""), ((.labels//[])|join(",")), (.url//"")] | @tsv' 2>/dev/null)

  # Closed-set priority sources (zenhub/projects) report unrecognized values
  # instead of silently mis-tiering them; escalate once per owner per day.
  unk=$(printf '%s' "$surf" | jq -r '.unknown // [] | length' 2>/dev/null || echo 0)
  case "$unk" in (''|*[!0-9]*) unk=0 ;; esac
  if [ "$unk" -gt 0 ]; then
    um="<!-- triage-surface:unknown:$owner:$(date +%Y-%m-%d) -->"
    if ! grep -qF -- "$um" "$INBOX_FILE" 2>/dev/null; then
      printf -- '- [ ] **Triage:** %s ticket(s) with an unrecognized priority value for %s — check the priority source mapping %s\n' \
        "$unk" "$owner" "$um" >> "$INBOX_FILE" || appended_ok=0
    fi
  fi

  # 3. Consume the transition only after the durable write succeeded, and never
  #    on a known-incomplete cache — advancing the surfaced snapshot past tickets
  #    a partial reconcile didn't fetch would drop them permanently.
  if [ "$appended_ok" -eq 1 ] && [ "$owner_incomplete" -eq 0 ]; then
    "$PY" "$SURFACER" "$owner" --mark >/dev/null 2>>"$LOG_FILE" || { FAILED_OWNERS="$FAILED_OWNERS $owner"; _log "ERROR mark failed for $owner"; }
  fi
done

# Consecutive-failure escalation (restored from v1): logs can go unwatched, so a
# persistently failing run must reach the inbox. Reset to 0 on any clean run.
if [ -n "${FAILED_OWNERS// }" ]; then CONSEC_FAILS=$((PRIOR_FAILS + 1)); LASTERR="surface_or_mark_failed"; else CONSEC_FAILS=0; LASTERR="none"; fi
if [ "$CONSEC_FAILS" -ge "$MAX_FAILS" ]; then
  gm="<!-- triage-autopilot:giveup:$(date +%Y-%m-%d) -->"
  if ! grep -qF -- "$gm" "$INBOX_FILE" 2>/dev/null; then
    printf -- '- [ ] **Triage autopilot:** %d consecutive failing runs (owners:%s) — check %s %s\n' \
      "$CONSEC_FAILS" "$FAILED_OWNERS" "$LOG_FILE" "$gm" >> "$INBOX_FILE" || true
  fi
fi

if [ "$EVENTS_TOTAL" -gt 0 ]; then STATUS="firing"; else STATUS="clear"; fi
# A firing tick did real work (new merges escalated) — tell cron to notify (#173).
[ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ] && [ "$STATUS" = "firing" ] && printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
# SINCE resets only on a real transition into firing.
if [ "$STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"; else SINCE="$NOW"; fi

_write_state "$STATUS" "$SINCE" \
  "events_total=$EVENTS_TOTAL" \
  "incomplete=$INCOMPLETE" \
  "consec_failures=$CONSEC_FAILS" \
  "failed_owners=${FAILED_OWNERS:-none}" \
  "last_error=$LASTERR" || exit 1

_log "status=$STATUS events_total=$EVENTS_TOTAL incomplete=$INCOMPLETE consec_failures=$CONSEC_FAILS failed=${FAILED_OWNERS:-none}"
exit 0
