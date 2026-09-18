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

ps_input() {
  if [ -n "${CEO_PROCESS_WATCHDOG_PS_FILE:-}" ]; then
    cat "$CEO_PROCESS_WATCHDOG_PS_FILE"
  else
    ps -axo pid=,ppid=,etime=,pcpu=,command=
  fi
}

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

find_candidates() {
  ps_input | filter_candidates
}

pid_still_matches() {
  local pid="$1"
  [ -z "${CEO_PROCESS_WATCHDOG_PS_FILE:-}" ] || return 0
  local line
  line=$(ps -p "$pid" -o pid=,ppid=,etime=,pcpu=,command= 2>/dev/null || true)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | filter_candidates | awk -F '\t' -v pid="$pid" '$1 == pid { found=1 } END { exit !found }'
}

terminate_pid() {
  local pid="$1"
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if [ -n "${CEO_PROCESS_WATCHDOG_KILL_LOG:-}" ]; then
    printf 'TERM %s\n' "$pid" >> "$CEO_PROCESS_WATCHDOG_KILL_LOG"
    [ "$KILL_AFTER_TERM" = "1" ] && printf 'KILL %s\n' "$pid" >> "$CEO_PROCESS_WATCHDOG_KILL_LOG"
    return 0
  fi
  pid_still_matches "$pid" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  sleep "$TERM_GRACE_SECONDS"
  if kill -0 "$pid" 2>/dev/null && [ "$KILL_AFTER_TERM" = "1" ]; then
    pid_still_matches "$pid" || return 1
    kill -KILL "$pid" 2>/dev/null || return 1
  fi
  return 0
}

notify_kills() {
  [ "$DRY_RUN" = "0" ] || return 0
  [ "${#KILLED[@]}" -gt 0 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local settings_file="$CEO_DIR/settings.json"
  local events="failures"
  if [ -f "$settings_file" ]; then
    events=$(jq -r '.notify_events // "failures"' "$settings_file" 2>/dev/null || echo "failures")
  fi
  [ "$events" != "off" ] || return 0

  local secrets_file="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"
  local webhook="${CEO_DISCORD_WEBHOOK:-}"
  if [ -z "$webhook" ] && [ -f "$secrets_file" ]; then
    webhook=$(jq -r '.discord_webhook // ""' "$secrets_file" 2>/dev/null || echo "")
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
  curl -sS -o /dev/null -X POST -H "Content-Type: application/json" --max-time 10 \
    -d "$payload" "$webhook" >/dev/null 2>&1 || \
    printf '%s host=%s killed=%s post_failed=1\n' "$NOW" "$HOST" "${#KILLED[@]}" >> "$debug_log" 2>/dev/null || true
}

# macOS still ships Bash 3.2, where an empty array expanded under `set -u`
# aborts. Keep nounset for config parsing above, then relax it only around the
# array bookkeeping that naturally has an empty state.
set +u
CANDIDATES=()
while IFS=$'\t' read -r pid etime age cpu; do
  [ -n "$pid" ] || continue
  CANDIDATES+=("$pid|$etime|$age|$cpu")
done < <(find_candidates)

KILLED=()
FAILED=()
for row in "${CANDIDATES[@]}"; do
  IFS='|' read -r pid etime age cpu <<< "$row"
  if terminate_pid "$pid"; then
    KILLED+=("$pid|$etime|$age|$cpu")
  else
    FAILED+=("$pid|$etime|$age|$cpu")
  fi
done

STATUS="clear"
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  STATUS="firing"
fi

STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  printf 'ERROR: process-watchdog: mktemp failed for %s\n' "$STATE_FILE" >&2
  exit 1
}
trap 'rm -f "$STATE_TMP"' EXIT

{
  ceo_write_alert_frontmatter \
    --status="$STATUS" \
    --since="$NOW" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field target="$TARGET_LABEL" \
    --field match="$TARGET_MATCH" \
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
    for row in "${KILLED[@]}"; do
      IFS='|' read -r pid etime age cpu <<< "$row"
      if [ "$DRY_RUN" = "1" ]; then result="would-kill"; else result="killed"; fi
      printf '| %s | %s | %s | %s | %s |\n' "$pid" "$etime" "$age" "$cpu" "$result"
    done
    for row in "${FAILED[@]}"; do
      IFS='|' read -r pid etime age cpu <<< "$row"
      printf '| %s | %s | %s | %s | failed-or-raced |\n' "$pid" "$etime" "$age" "$cpu"
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
