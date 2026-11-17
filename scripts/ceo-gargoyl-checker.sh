#!/bin/bash
# ceo-gargoyl-checker.sh — deterministic local watchdog for the dev.gargoyl.monitor
# LaunchAgent (origin: nhangen/llm-tools spec
# ~/.claude/specs/2026-11-05-gargoyl-monitor-checker.md, ticket
# nhangen/llm-tools#1144; hosted in claude-ceo and retired from llm-tools since
# nhangen/claude-ceo#653). Reads status only; never drives Darkbloom;
# parse-don't-execute.
#
# Calibrated 2026-11-05 against the live monitor (keep this calibration):
#   - stderr/stdout freshness is a logged NOTE, not a failure: the monitor is
#     event-driven and legitimately silent for days in steady state.
#   - fleet.json is a FETCH-TIME SNAPSHOT export; its connection value is
#     informational only. A parse failure is still a finding.
#   - Traffic counters may read equal across reads during idle demand; the
#     wedge signal is the collector's snapshot cadence, not equal counts.
#
# Runs as the gargoyl-checker playbook (runner: script, */5 * * * *). Declared
# outputs: the CEO/alerts note (on transitions only) and the Discord webhook
# (transitions only: healthy->failed and failed->recovered). Exits 0 when the
# run recorded its result and the transition notice landed (or was silenced by
# notify_events=off), green or firing alike: the state lives in the note, so
# ceo-cron.sh does not escalate a watch it has already been told about. Exits 1
# when a failure notice did not land (persisted notified=false, retried next
# run) or the checker could not record state, so the dispatcher's fallback and
# three-strike escalation take over. Never writes outside its own log dir, the
# Discord webhook, and the registered playbook outputs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

# Probe seams (tests stub these; production resolves through PATH).
LAUNCHCTL_BIN="${GARGOYL_LAUNCHCTL_BIN:-launchctl}"
PGREP_BIN="${GARGOYL_PGREP_BIN:-pgrep}"
CURL_BIN="${GARGOYL_CURL_BIN:-curl}"

# macOS-specific monitor paths; overridable so tests drive fixtures.
MONITOR_LOG_DIR="${GARGOYL_MONITOR_LOG_DIR:-$HOME/Library/Logs/Gargoyl}"
STDERR_LOG="$MONITOR_LOG_DIR/monitor.stderr.log"
STDOUT_LOG="$MONITOR_LOG_DIR/monitor.stdout.log"
FLEET_JSON="${GARGOYL_FLEET_JSON:-$HOME/Library/Application Support/Gargoyl/fleet.json}"
LABEL="dev.gargoyl.monitor"
DASHBOARD_URL="${GARGOYL_DASHBOARD_URL:-http://127.0.0.1:8766}"
MONITOR_PATTERN="${GARGOYL_MONITOR_PGREP_PATTERN:-ML-AI/gargoyl/.venv/bin/gargoyl monitor}"

TRACEBACK_WINDOW="${GARGOYL_TRACEBACK_WINDOW_SECONDS:-900}"
CHECKER_LOG_DIR="${GARGOYL_CHECKER_LOG_DIR:-$HOME/Library/Logs/Gargoyl/checker}"
NOTIFY_LOG="${GARGOYL_NOTIFY_DEBUG_LOG:-$CHECKER_LOG_DIR/notify.log}"

# Discord webhook resolution: explicit env override first (tests never touch
# the real secrets file), then the shared discord_webhook secret. The value
# is never printed or logged (no-secrets-in-logs).
DISCORD_WEBHOOK="${GARGOYL_DISCORD_WEBHOOK_URL:-${CEO_DISCORD_WEBHOOK:-}}"
SECRETS_FILE="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"
if [ -z "$DISCORD_WEBHOOK" ] && [ -f "$SECRETS_FILE" ]; then
  DISCORD_WEBHOOK=$(jq -r '.discord_webhook // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
fi

ALERT_FILE="$CEO_DIR/alerts/gargoyl-checker-$HOST.md"
mkdir -p "$CEO_DIR/alerts" "$CHECKER_LOG_DIR" 2>/dev/null || true
NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

_log() {
  printf '%s %s\n' "$(date +%FT%T)" "$*" >> "$CHECKER_LOG_DIR/checker.log" 2>/dev/null || true
}

# Discord delivery decisions get their own channel (GARGOYL_NOTIFY_DEBUG_LOG),
# separate from the checker log, so a silent webhook bailout is recoverable.
_nlog() {
  printf '%s %s\n' "$(date +%FT%T)" "$*" >> "$NOTIFY_LOG" 2>/dev/null || true
}

_set_outcome() {
  # CEO_RUNNER_OUTCOME_FILE (#173): only exit-0 runs write it, always "noop"
  # (the checker already delivered or deliberately skipped its own notice).
  # Exit-1 runs leave it unset so ceo-cron.sh posts its failure fallback.
  if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
    printf '%s' "$1" > "$CEO_RUNNER_OUTCOME_FILE" 2>/dev/null || \
      printf 'WARN: gargoyl-checker: cannot write outcome file %s\n' "$CEO_RUNNER_OUTCOME_FILE" >&2
  fi
}

# notify_discord <kind: failed|recovered> <reason>
# Returns 0 when the notice landed or notify_events=off silenced it, 1 when it
# did not land. Delivery failures are logged with the HTTP code only — never
# the URL or the body, which could echo the token.
notify_discord() {
  local kind="$1" reason="$2" title color
  if [ -z "$DISCORD_WEBHOOK" ]; then
    _nlog "ERROR: no Discord webhook configured; $kind notice not sent"
    printf 'WARN: gargoyl-checker: no Discord webhook configured; %s notice not sent\n' "$kind" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    _nlog "ERROR: jq or curl missing; $kind notice not sent"
    printf 'WARN: gargoyl-checker: jq or curl missing; Discord %s notice not sent\n' "$kind" >&2
    return 1
  fi
  local events="all"
  if [ -f "$CEO_DIR/settings.json" ]; then
    events=$(jq -r '.notify_events // "all"' "$CEO_DIR/settings.json" 2>/dev/null || echo "all")
  fi
  case "$events" in
    off)
      _nlog "note: notify_events=off; $kind notice not sent"
      return 0
      ;;
    failures|all) ;;
    *)
      _nlog "WARN: unknown notify_events '$events'; notifying"
      printf "WARN: gargoyl-checker: unknown notify_events '%s' in settings.json (want off|failures|all); notifying\n" "$events" >&2
      ;;
  esac
  local alert_rel="CEO/alerts/gargoyl-checker-$HOST.md"
  local payload
  if [ "$kind" = "failed" ]; then
    title="🔴 gargoyl-checker: $LABEL watch FAILED"
    color=15158332
  else
    title="🟢 gargoyl-checker: $LABEL watch recovered"
    color=3066993
  fi
  payload=$(jq -n \
    --arg title "$title" \
    --arg desc "$reason" \
    --arg host "$HOST" \
    --arg alert "$alert_rel" \
    --argjson color "$color" \
    '{
      username: "CEO Cron",
      embeds: [{
        title: $title,
        description: $desc,
        color: $color,
        fields: [
          {name: "Host", value: $host, inline: true},
          {name: "Alert", value: $alert, inline: false}
        ]
      }]
    }') || payload=""
  if [ -z "$payload" ]; then
    _nlog "ERROR: could not build $kind payload (jq failed); notice not sent"
    printf 'WARN: gargoyl-checker: jq could not build the %s payload\n' "$kind" >&2
    return 1
  fi
  local http_code
  http_code=$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --max-time 10 -d "$payload" "$DISCORD_WEBHOOK" 2>/dev/null) || http_code=000
  if ! [[ $http_code =~ ^2[0-9]{2}$ ]]; then
    _nlog "ERROR: Discord delivery for $kind failed (HTTP $http_code)"
    printf 'WARN: gargoyl-checker: Discord %s notice failed (HTTP %s)\n' "$kind" "$http_code" >&2
    return 1
  fi
  _nlog "notified: $kind (HTTP $http_code)"
}

# write_alert <status: clear|firing> <since> <reason-1line> <notified: true|false>
# Transition-only (per ticket #653): the note is current state, overwritten,
# with status/since/last_check frontmatter. last_check therefore records the
# last transition, not the last probe; per-run lines live in the checker log.
# notified=false marks a transition whose notice has not landed yet.
write_alert() {
  local status="$1" since="$2" reason="$3" notified="$4"
  # The frontmatter value is a plain YAML scalar: ": " and " #" would break
  # the synced note's YAML, so neutralize them there (the body keeps the text).
  local fm_reason="${reason//: / - }"
  fm_reason="${fm_reason// #/ }"
  local tmp
  tmp=$(mktemp "${ALERT_FILE}.XXXXXX") || {
    _log "ERROR: mktemp failed for $ALERT_FILE"
    printf 'ERROR: gargoyl-checker: mktemp failed for %s\n' "$ALERT_FILE" >&2
    return 1
  }
  local fm
  fm=$(ceo_write_alert_frontmatter \
      --status="$status" \
      --since="$since" \
      --last-check="$NOW" \
      --host="$HOST" \
      --field reason="$fm_reason" \
      --field notified="$notified") || {
    rm -f "$tmp"
    _log "ERROR: frontmatter rejected for $ALERT_FILE"
    printf 'ERROR: gargoyl-checker: frontmatter rejected for %s\n' "$ALERT_FILE" >&2
    return 1
  }
  if ! {
    printf '%s\n' "$fm"
    printf '\n# Gargoyl checker — %s\n\n' "$HOST"
    printf 'Watch: `%s` (dev.gargoyl.monitor LaunchAgent, dashboard %s).\n\n' "$LABEL" "$DASHBOARD_URL"
    if [ "$status" = "firing" ]; then
      printf '## Failed\n\nFailing since %s.\n\n' "$since"
      printf 'Reason: %s\n' "$reason"
    else
      printf '## Recovered\n\nWatch is green again at %s' "$NOW"
      if [ -n "$reason" ]; then
        printf ' (was failing: %s)' "$reason"
      fi
      printf '.\n'
    fi
  } > "$tmp"; then
    rm -f "$tmp"
    _log "ERROR: failed to render state for $ALERT_FILE"
    printf 'ERROR: gargoyl-checker: failed to render state for %s\n' "$ALERT_FILE" >&2
    return 1
  fi
  if ! mv "$tmp" "$ALERT_FILE"; then
    rm -f "$tmp"
    _log "ERROR: failed to replace $ALERT_FILE"
    printf 'ERROR: gargoyl-checker: failed to replace %s\n' "$ALERT_FILE" >&2
    return 1
  fi
}

# Prior state comes from the alerts note itself (the file is both state and
# report). Exit-code semantics of ceo_read_alert_field:
#   0 = field present, 1 = file exists but field absent (corruption),
#   2 = no file (first run) → "clear".
# An unreadable/unknown prior state must not fire a transition notice: we
# cannot tell a fresh failure from a repeat, and a duplicate Discord post is
# the spam this checker exists to avoid.
PRIOR_STATUS=""
PRIOR_SINCE=""
PRIOR_REASON=""
_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$ALERT_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *) PRIOR_STATUS="unknown" ;;
    esac
    ;;
  1)
    _log "WARN: alert file $ALERT_FILE present but missing status field; treating prior state as unknown"
    PRIOR_STATUS="unknown"
    ;;
  2) PRIOR_STATUS="clear" ;;
esac
PRIOR_SINCE=$(ceo_read_alert_field "$ALERT_FILE" since 2>/dev/null) || PRIOR_SINCE=""
PRIOR_REASON=$(ceo_read_alert_field "$ALERT_FILE" reason 2>/dev/null) || PRIOR_REASON=""
PRIOR_NOTIFIED=$(ceo_read_alert_field "$ALERT_FILE" notified 2>/dev/null) || PRIOR_NOTIFIED=""

# checker_fault <msg> — state could not be recorded. No Discord post (with no
# persisted state it would repeat every run); exit 1 without an outcome so
# ceo-cron.sh owns the fault.
checker_fault() {
  _log "ERROR: $*"
  printf 'ERROR: gargoyl-checker: %s\n' "$*" >&2
  exit 1
}

# deliver <status> <since> <reason> <kind> <message> — persist the transition
# as notified=false, post, then persist notified=true. Returns 1 when the
# notice did not land; the next run retries from notified=false.
deliver() {
  local status="$1" since="$2" reason="$3" kind="$4" message="$5"
  write_alert "$status" "$since" "$reason" false || \
    checker_fault "could not record $status state in $ALERT_FILE; $kind notice not sent"
  if ! notify_discord "$kind" "$message"; then
    _log "$kind notice not delivered; the next run retries it"
    return 1
  fi
  write_alert "$status" "$since" "$reason" true || \
    checker_fault "$kind notice sent but not recorded in $ALERT_FILE; the next run may re-send it"
}

# fail_now <reason...> — record the failure and notify on the clear->firing
# transition (or retry an undelivered one). Exits 0 once recorded and notified,
# 1 when the notice did not land.
fail_now() {
  local reason="$*"
  reason=$(printf '%s' "$reason" | tr '\n' ' ' | cut -c1-300)
  _log "FAILED: $reason"
  printf '%s FAILED: %s\n' "$NOW" "$reason" >&2
  case "$PRIOR_STATUS" in
    clear)
      _log "transition: NEW FAILURE (notifying)"
      printf '%s transition: NEW FAILURE (notifying)\n' "$NOW"
      deliver firing "$NOW" "$reason" failed "$reason" || exit 1
      ;;
    firing)
      local since="${PRIOR_SINCE:-$NOW}"
      if [ "$PRIOR_NOTIFIED" = "false" ]; then
        _log "still failing; retrying the undelivered failure notice"
        printf '%s still failing; retrying the undelivered failure notice\n' "$NOW"
        deliver firing "$since" "$reason" failed "$reason" || exit 1
      else
        _log "still failing: $reason (no repeat notification)"
        printf '%s still failing: %s (no repeat notification)\n' "$NOW" "$reason"
      fi
      ;;
    *)
      # Unknown prior (corrupt note): record the state so the next run can
      # classify, but do not notify — a duplicate post is the failure mode.
      _log "prior state unknown; recording firing without a transition notice"
      printf '%s prior state unknown; recording firing without a transition notice\n' "$NOW"
      write_alert firing "$NOW" "$reason" true || \
        checker_fault "could not record firing state in $ALERT_FILE"
      ;;
  esac
  _set_outcome "noop"
  exit 0
}

# recover — green exit. On a firing->clear transition (or an undelivered
# recovered notice), post and rewrite the note. A recovered notice that does
# not land is retried next run but does not fail the run: the watch is green.
recover() {
  case "$PRIOR_STATUS" in
    firing)
      _log "transition: RECOVERED (notifying)"
      printf '%s transition: RECOVERED (notifying)\n' "$NOW"
      deliver clear "$NOW" "$PRIOR_REASON" recovered \
        "Gargoyl monitor watch is green again (was failing since ${PRIOR_SINCE:-unknown})" || true
      ;;
    unknown)
      # Repair the note without a notice — the prior state was unreadable, so
      # a "recovered" post could duplicate one already sent.
      _log "prior state unknown; recording clear without a transition notice"
      write_alert clear "$NOW" "" true || checker_fault "could not record clear state in $ALERT_FILE"
      ;;
    clear)
      if [ "$PRIOR_NOTIFIED" = "false" ]; then
        _log "green; retrying the undelivered recovered notice"
        printf '%s green; retrying the undelivered recovered notice\n' "$NOW"
        deliver clear "${PRIOR_SINCE:-$NOW}" "$PRIOR_REASON" recovered \
          "Gargoyl monitor watch is green again (recovered at ${PRIOR_SINCE:-unknown})" || true
      else
        _log "green"
        printf '%s green\n' "$NOW"
      fi
      ;;
  esac
  _set_outcome "noop"
  exit 0
}

# --- Probe 1: monitor logs exist -------------------------------------------
[ -f "$STDERR_LOG" ] || [ -f "$STDOUT_LOG" ] || \
  fail_now "no monitor logs exist at $MONITOR_LOG_DIR (monitor never started or logs deleted)"

# --- Probe 2: launchd job registered and reporting clean --------------------
ROW="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -F'\t' -v label="$LABEL" '$NF == label {print $1 "\t" $2}')" || true
[ -n "$ROW" ] || fail_now "launchd has no job named $LABEL (KeepAlive daemon unloaded)"
ROW_PID="${ROW%%$'\t'*}"
ROW_EXIT="${ROW#*$'\t'}"
ROW_EXIT="${ROW_EXIT%%$'\t'*}"
case "$ROW_EXIT" in
  "-"|"0") : ;;
  *) fail_now "$LABEL last exit status is $ROW_EXIT (KeepAlive is not reporting a clean run)" ;;
esac
_log "note: launchd row pid=$ROW_PID last_exit=$ROW_EXIT"

# --- Probe 3: stderr freshness (informational) + traceback scan -------------
# stderr/stdout freshness is logged, not a failure: the monitor is event-driven
# and legitimately silent for days in steady state (calibrated 2026-11-05).
if [ -f "$STDERR_LOG" ]; then
  MTIME=$(python3 -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' "$STDERR_LOG" 2>/dev/null) || MTIME=""
  NOW_EPOCH=$(date +%s)
  if [ -n "$MTIME" ]; then
    _log "note: monitor.stderr.log age $((NOW_EPOCH - MTIME)) seconds (informational only)"
    printf '%s note: monitor.stderr.log age %s seconds (informational only)\n' "$NOW" "$((NOW_EPOCH - MTIME))"
  fi
  # "Fresh" means the log was written within the window: a traceback in a log
  # untouched since is a crash launchd already recovered. An unreadable mtime
  # scans anyway rather than skip the probe.
  STDERR_AGE=""
  [ -n "$MTIME" ] && STDERR_AGE=$((NOW_EPOCH - MTIME))
  if [ -n "$STDERR_AGE" ] && [ "$STDERR_AGE" -gt "$TRACEBACK_WINDOW" ]; then
    _log "note: monitor.stderr.log last written ${STDERR_AGE}s ago, outside the ${TRACEBACK_WINDOW}s traceback window; not scanned"
  elif tail -c 20000 "$STDERR_LOG" 2>/dev/null | grep -qE "Traceback|FATAL|fatal error|Uncaught"; then
    # Raw stderr lines can carry secrets; only the count and the matched shapes
    # leave the host (no-secrets-in-logs). The log itself has the detail.
    _matches=$(tail -c 20000 "$STDERR_LOG" 2>/dev/null | grep -oE "Traceback|FATAL|fatal error|Uncaught") || _matches=""
    _count=$(printf '%s\n' "$_matches" | grep -c . || true)
    _shapes=$(printf '%s\n' "$_matches" | grep . | sort -u | paste -sd, - | sed 's/,/, /g')
    fail_now "fresh error-shaped lines in monitor.stderr.log ($_count matching ${_shapes:-unknown}); see $STDERR_LOG"
  fi
fi

# --- Probe 4: monitor process alive -----------------------------------------
"$PGREP_BIN" -f "$MONITOR_PATTERN" >/dev/null 2>&1 || \
  fail_now "no running gargoyl monitor process found (daemon exited and launchd has not replaced it)"

# --- Probe 5: dashboard answers a loopback GET ------------------------------
"$CURL_BIN" -fsS --max-time 5 "$DASHBOARD_URL/" >/dev/null 2>&1 || \
  "$CURL_BIN" -fsS --max-time 5 "$DASHBOARD_URL/status" >/dev/null 2>&1 || \
  fail_now "monitor dashboard on $DASHBOARD_URL did not answer a loopback GET within 5s (process present but wedged)"

# --- Probe 6: fleet.json parses (connection value informational) ------------
# fleet.json is a FETCH-TIME SNAPSHOT export (written when an external fetch
# happens, not by the live monitor loop; calibrated 2026-11-05 against the
# dashboard's own /report.json counters). Parse failure is a finding; its
# connection value is informational only.
if [ -f "$FLEET_JSON" ]; then
  CONN=$(python3 - "$FLEET_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("connection", "unknown"))
except Exception:
    print("unreadable")
PY
) || fail_now "could not parse fleet.json (python3 parse run failed)"
  [ "$CONN" != "unreadable" ] || fail_now "fleet.json exists but does not parse as JSON"
  _log "note: fleet.json snapshot connection=$CONN (informational: snapshot artifact, not live health)"
  printf '%s note: fleet.json snapshot connection=%s (informational: snapshot artifact, not live health)\n' "$NOW" "$CONN"
fi

# --- Probe 7: collector cadence (the live wedge probe) ----------------------
# The collector's newest snapshot must be fresh. Traffic counters may equal
# across reads during idle demand (equal-count reads are NOT a failure signal,
# per the dashboard's own semantics); collection cadence is the wedge signal.
REPORT=$("$CURL_BIN" -fsS --max-time 5 "$DASHBOARD_URL/report.json" 2>/dev/null) || REPORT=""
[ -n "$REPORT" ] || fail_now "monitor dashboard /report.json did not answer a loopback GET (process present but wedged, or dashboard down)"
AGE=$(python3 - "$REPORT" <<'PY'
import datetime as dt
import json, sys
doc = json.loads(sys.argv[1])
newest = max((snap.get("collected_at", "") for snap in doc.get("snapshots", [])), default="")
if not newest:
    print("none")
else:
    stamp = newest.replace("Z", "+00:00")
    age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(stamp)).total_seconds()
    print(f"newest {newest} age {age:.0f}s")
PY
) || fail_now "could not parse collector cadence from /report.json"
case "$AGE" in
  newest*)
    _log "note: collector $AGE"
    printf '%s note: collector %s\n' "$NOW" "$AGE"
    AGE_SECONDS=$(printf '%s' "$AGE" | sed -E 's/.*age ([0-9]+)s/\1/')
    [ "${AGE_SECONDS:-9999}" -le 120 ] || fail_now "collector's newest snapshot is $AGE_SECONDS seconds old (collection loop appears wedged)" ;;
  none) fail_now "dashboard /report.json returned no snapshots (collector produced nothing; wedge)" ;;
  *) fail_now "could not parse collector cadence from /report.json ($AGE)" ;;
esac

recover
