#!/bin/bash
# ceo-process-watchdog.sh — Kill known orphaned runaway processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

DRY_RUN="${CEO_PROCESS_WATCHDOG_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: unknown flag '$1' (expected: --dry-run)" >&2; exit 1 ;;
  esac
  shift
done

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

ALERTS_DIR="$CEO_DIR/alerts"
LOG_DIR="$CEO_DIR/log/process-watchdog"
STATE_FILE="$ALERTS_DIR/process-watchdog-$HOST.md"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).md"
mkdir -p "$ALERTS_DIR" "$LOG_DIR"

TARGET_LABEL="${CEO_PROCESS_WATCHDOG_LABEL:-gitnexus-mcp}"
TARGET_MATCH="${CEO_PROCESS_WATCHDOG_MATCH:-node /opt/homebrew/bin/gitnexus mcp}"
AGE_MINUTES="${CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES:-30}"
CPU_PERCENT="${CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT:-20}"
TERM_GRACE_SECONDS="${CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS:-5}"
KILL_AFTER_TERM="${CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM:-1}"

case "$AGE_MINUTES" in (''|*[!0-9]*) echo "ERROR: CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES must be an integer" >&2; exit 1 ;; esac
case "$TERM_GRACE_SECONDS" in (''|*[!0-9]*) echo "ERROR: CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS must be an integer" >&2; exit 1 ;; esac
case "$KILL_AFTER_TERM" in (0|1) ;; (*) echo "ERROR: CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM must be 0 or 1" >&2; exit 1 ;; esac
awk -v n="$CPU_PERCENT" 'BEGIN { exit (n ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1) }' || {
  echo "ERROR: CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT must be numeric" >&2
  exit 1
}

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)
AGE_SECONDS=$((AGE_MINUTES * 60))

# The signal primitive is the only seam: tests point it at a stub so every
# branch of terminate_pid below still runs. `kill` alone resolves to the builtin.
KILL_BIN="${CEO_PROCESS_WATCHDOG_KILL_BIN:-kill}"

filter_candidates() {
  awk -v min_age="$AGE_SECONDS" -v min_cpu="$CPU_PERCENT" -v needle="$TARGET_MATCH" '
    function etime_seconds(s, parts, rest, days, n, h, m, sec) {
      days = 0
      if (index(s, "-") > 0) {
        split(s, parts, "-")
        days = parts[1] + 0
        rest = parts[2]
      } else {
        rest = s
      }
      n = split(rest, parts, ":")
      if (n == 3) {
        h = parts[1] + 0; m = parts[2] + 0; sec = parts[3] + 0
      } else if (n == 2) {
        h = 0; m = parts[1] + 0; sec = parts[2] + 0
      } else {
        h = 0; m = 0; sec = rest + 0
      }
      return (days * 86400) + (h * 3600) + (m * 60) + sec
    }
    /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/ {
      pid = $1
      ppid = $2
      etime = $3
      cpu = $4 + 0
      cmd = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", cmd)
      age = etime_seconds(etime)
      if (ppid == 1 && index(cmd, needle) > 0 && age >= min_age && cpu >= min_cpu) {
        printf "%s\t%s\t%s\t%.1f\n", pid, etime, age, cpu
      }
    }
  '
}

# Identity only (orphaned, same command), not age/CPU: a process winding down
# after TERM drops below the CPU floor, and that must not read as a reused PID.
# rc 0 = still ours, 1 = something else owns the PID, 2 = ps printed nothing.
pid_still_matches() {
  local pid="$1" line
  line=$(ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null || true)
  [ -n "$line" ] || return 2
  printf '%s\n' "$line" | awk -v pid="$pid" -v needle="$TARGET_MATCH" '
    $1 == pid && $2 == 1 && index($0, needle) > 0 { found = 1 }
    END { exit !found }'
}

# Prints the outcome: killed | gone-before-signal | survived-term | failed.
terminate_pid() {
  local pid="$1"
  if ! pid_still_matches "$pid"; then echo "gone-before-signal"; return; fi
  if ! "$KILL_BIN" -TERM "$pid" 2>/dev/null; then echo "failed"; return; fi
  sleep "$TERM_GRACE_SECONDS"
  if ! "$KILL_BIN" -0 "$pid" 2>/dev/null; then echo "killed"; return; fi
  if [ "$KILL_AFTER_TERM" != "1" ]; then echo "survived-term"; return; fi
  # Alive but no longer ours means the PID was reused after our process exited.
  # Alive with no ps answer at all proves nothing, so it is not a kill.
  local rc=0
  pid_still_matches "$pid" || rc=$?
  if [ "$rc" -eq 1 ]; then echo "killed"; return; fi
  if [ "$rc" -eq 2 ]; then echo "failed"; return; fi
  if ! "$KILL_BIN" -KILL "$pid" 2>/dev/null; then echo "failed"; return; fi
  sleep 1
  if "$KILL_BIN" -0 "$pid" 2>/dev/null; then echo "failed"; return; fi
  echo "killed"
}

notify_kills() {
  [ "$DRY_RUN" = "0" ] || return 0
  [ "${#KILLED[@]}" -gt 0 ] || return 0
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf 'WARN: process-watchdog: jq or curl missing; kill notification not sent\n' >&2
    return 0
  fi

  local settings_file="$CEO_DIR/settings.json"
  local events="failures"
  if [ -f "$settings_file" ]; then
    events=$(jq -r '.notify_events // "failures"' "$settings_file" 2>/dev/null || echo "failures")
  fi
  [ "$events" != "off" ] || return 0

  local secrets_file="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"
  local webhook="${CEO_DISCORD_WEBHOOK:-}"
  if [ -z "$webhook" ] && [ -f "$secrets_file" ]; then
    webhook=$(jq -r '.discord_webhook // ""' "$secrets_file" 2>/dev/null) || {
      printf 'WARN: process-watchdog: could not parse %s; kill notification not sent\n' "$secrets_file" >&2
      return 0
    }
  fi
  [ -n "$webhook" ] || return 0

  local pids="" row pid _etime _age _cpu
  for row in "${KILLED[@]}"; do
    IFS='|' read -r pid _etime _age _cpu <<< "$row"
    if [ -z "$pids" ]; then pids="$pid"; else pids="$pids, $pid"; fi
  done

  local alert_rel="CEO/alerts/process-watchdog-$HOST.md"
  local payload
  payload=$(jq -n \
    --arg title "process-watchdog killed orphaned process(es)" \
    --arg desc "Terminated ${#KILLED[@]} ${TARGET_LABEL} process(es). Clear checks stay silent." \
    --arg host "$HOST" \
    --arg target "$TARGET_LABEL" \
    --arg pids "$pids" \
    --arg criteria "PPID=1, age >= ${AGE_MINUTES}m, CPU >= ${CPU_PERCENT}%" \
    --arg alert "$alert_rel" \
    '{
      username: "CEO Cron",
      embeds: [{
        title: $title,
        description: $desc,
        color: 15105570,
        fields: [
          {name: "Host", value: $host, inline: true},
          {name: "Target", value: $target, inline: true},
          {name: "PIDs", value: $pids, inline: true},
          {name: "Criteria", value: $criteria, inline: false},
          {name: "Alert", value: $alert, inline: false}
        ]
      }]
    }')

  local debug_log="${CEO_PROCESS_WATCHDOG_NOTIFY_LOG:-/tmp/process-watchdog-notify.log}"
  printf '%s host=%s killed=%s posting=1\n' "$NOW" "$HOST" "${#KILLED[@]}" >> "$debug_log" 2>/dev/null || true
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --max-time 10 -d "$payload" "$webhook" 2>/dev/null) || http_code=000
  if ! [[ $http_code =~ ^2[0-9]{2}$ ]]; then
    printf '%s host=%s killed=%s post_failed=1 status=%s\n' "$NOW" "$HOST" "${#KILLED[@]}" "$http_code" >> "$debug_log" 2>/dev/null || true
    printf 'WARN: process-watchdog: kill notification failed (HTTP %s)\n' "$http_code" >&2
  fi
}

# macOS still ships Bash 3.2, where an empty array expanded under `set -u`
# aborts. Every config read happens above; nounset stays off for the rest of the
# script because every array below can legitimately be empty.
set +u

# Read the table before filtering it: a failed or empty listing must not be
# reported as "no runaways". A live host always has processes.
PS_OUT=$(ps -axo pid=,ppid=,etime=,pcpu=,command=) || PS_OUT=""
if [ -z "$PS_OUT" ]; then
  printf 'ERROR: process-watchdog: ps returned no process table; alert left unchanged\n' >&2
  exit 1
fi

CANDIDATE_LINES=$(printf '%s\n' "$PS_OUT" | filter_candidates) || {
  printf 'ERROR: process-watchdog: candidate filter failed; alert left unchanged\n' >&2
  exit 1
}
CANDIDATES=()
while IFS=$'\t' read -r pid etime age cpu; do
  [ -n "$pid" ] || continue
  CANDIDATES+=("$pid|$etime|$age|$cpu")
done <<< "$CANDIDATE_LINES"

KILLED=()
FAILED=()
ROWS=()
for row in "${CANDIDATES[@]}"; do
  IFS='|' read -r pid etime age cpu <<< "$row"
  if [ "$DRY_RUN" = "1" ]; then
    result="would-kill"
  else
    result=$(terminate_pid "$pid")
  fi
  case "$result" in
    killed) KILLED+=("$row") ;;
    would-kill|gone-before-signal) ;;
    *) FAILED+=("$row") ;;
  esac
  ROWS+=("$row|$result")
done

# A candidate that exited on its own before any signal leaves nothing to report.
STATUS="clear"
for row in "${ROWS[@]}"; do
  case "$row" in *"|gone-before-signal") ;; *) STATUS="firing" ;; esac
done

PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status 2>/dev/null) || PRIOR_STATUS=""
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since 2>/dev/null) || PRIOR_SINCE=""
if [ "$STATUS" = "$PRIOR_STATUS" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
fi

STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  printf 'ERROR: process-watchdog: mktemp failed for %s\n' "$STATE_FILE" >&2
  exit 1
}
trap 'rm -f "$STATE_TMP"' EXIT

{
  ceo_write_alert_frontmatter \
    --status="$STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field target="$TARGET_LABEL" \
    --field min_age_minutes="$AGE_MINUTES" \
    --field min_cpu_percent="$CPU_PERCENT" \
    --field candidate_count="${#CANDIDATES[@]}" \
    --field killed_count="${#KILLED[@]}" \
    --field failed_count="${#FAILED[@]}" \
    --field dry_run="$DRY_RUN"
  printf '\n# Process Watchdog — %s\n\n' "$HOST"
  printf "Target: \`%s\`\n\n" "$TARGET_LABEL"
  printf "Criteria: \`PPID=1\`, age >= \`%sm\`, CPU >= \`%s%%\`.\n\n" "$AGE_MINUTES" "$CPU_PERCENT"
  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    printf 'No matching orphaned runaway processes found.\n'
  else
    if [ "$DRY_RUN" = "1" ]; then
      printf 'Dry run: would terminate %s process(es).\n\n' "${#CANDIDATES[@]}"
    else
      printf 'Terminated %s of %s matching process(es).\n\n' "${#KILLED[@]}" "${#CANDIDATES[@]}"
    fi
    printf '| PID | Elapsed | Age seconds | CPU %% | Result |\n'
    printf '|---:|---:|---:|---:|---|\n'
    for row in "${ROWS[@]}"; do
      IFS='|' read -r pid etime age cpu result <<< "$row"
      printf '| %s | %s | %s | %s | %s |\n' "$pid" "$etime" "$age" "$cpu" "$result"
    done
  fi
} > "$STATE_TMP"

mv "$STATE_TMP" "$STATE_FILE"
trap - EXIT

if ! printf '%s host=%s status=%s target=%s candidates=%s killed=%s failed=%s dry_run=%s age_min=%s cpu_min=%s\n' \
    "$NOW" "$HOST" "$STATUS" "$TARGET_LABEL" "${#CANDIDATES[@]}" "${#KILLED[@]}" "${#FAILED[@]}" "$DRY_RUN" "$AGE_MINUTES" "$CPU_PERCENT" >> "$LOG_FILE" 2>/dev/null; then
  printf 'WARN: process-watchdog: failed to append log line to %s\n' "$LOG_FILE" >&2
fi

notify_kills

if [ "${#FAILED[@]}" -gt 0 ]; then
  exit 1
fi
