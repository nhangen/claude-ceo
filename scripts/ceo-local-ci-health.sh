#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path
ceo_resolve_timeout_bin

CEO_DIR="$CEO_VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

STATUS_URL="${CEO_LOCAL_CI_STATUS_URL:-http://100.102.197.40:8876/api/status}"
SUSTAINED_SECONDS="${CEO_LOCAL_CI_SUSTAINED_SECONDS:-300}"
MAX_STATUS_AGE_SECONDS="${CEO_LOCAL_CI_MAX_STATUS_AGE_SECONDS:-120}"
PROBE_TIMEOUT_SECONDS="${CEO_LOCAL_CI_PROBE_TIMEOUT_SECONDS:-20}"
DOCKER_BIN="${CEO_LOCAL_CI_DOCKER_BIN:-docker}"
SYSTEMCTL_BIN="${CEO_LOCAL_CI_SYSTEMCTL_BIN:-systemctl}"
CURL_BIN="${CEO_LOCAL_CI_CURL_BIN:-curl}"
PYTHON_BIN="${CEO_LOCAL_CI_PYTHON_BIN:-python3}"
TIMEOUT_BIN="${CEO_LOCAL_CI_TIMEOUT_BIN:-${CEO_TIMEOUT_BIN:-}}"
ALERTS_DIR="$CEO_DIR/alerts"
LOG_DIR="$CEO_DIR/log/local-ci-health"
INBOX_DIR="$CEO_DIR/inbox"
STATE_FILE="$ALERTS_DIR/local-ci-health-$HOST.md"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).md"
INBOX_FILE="$INBOX_DIR/$HOST.md"
NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

mkdir -p "$ALERTS_DIR" "$LOG_DIR" "$INBOX_DIR"

PRIOR_STATUS=""
PRIOR_SINCE=""
_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *)
        printf 'WARN: ceo-local-ci-health: unrecognized prior status %q; refusing inbox mutation\n' "$PRIOR_STATUS" >&2
        PRIOR_STATUS="unknown"
        ;;
    esac
    ;;
  1) PRIOR_STATUS="unknown" ;;
  2) PRIOR_STATUS="clear" ;;
esac
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since) || PRIOR_SINCE=""

REASONS=()
OBSERVATION_FAILED=0
DOCKER_STATE="unknown"
SERVICE_STATE="unknown"
API_STATE="unknown"
TOTAL="?"
ONLINE="?"
BUSY="?"
ATTENTION="?"
REPO_ROWS=""

if [ -z "$TIMEOUT_BIN" ] || ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
  OBSERVATION_FAILED=1
  REASONS+=("timeout command is unavailable")
elif command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  if "$TIMEOUT_BIN" "$PROBE_TIMEOUT_SECONDS" "$DOCKER_BIN" info >/dev/null 2>&1; then
    DOCKER_STATE="ok"
  else
    DOCKER_STATE="failed"
    REASONS+=("Docker API is unavailable through the current socket")
  fi
else
  OBSERVATION_FAILED=1
  REASONS+=("docker command is unavailable")
fi

if [ -n "$TIMEOUT_BIN" ] && command -v "$TIMEOUT_BIN" >/dev/null 2>&1 && command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
  if "$TIMEOUT_BIN" "$PROBE_TIMEOUT_SECONDS" "$SYSTEMCTL_BIN" --user is-active --quiet local-ci-status.service; then
    SERVICE_STATE="active"
  else
    SERVICE_STATE="inactive"
    REASONS+=("local-ci-status.service is not active")
  fi
else
  OBSERVATION_FAILED=1
  REASONS+=("systemctl command is unavailable")
fi

if command -v "$CURL_BIN" >/dev/null 2>&1 && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  _api_body=""
  if _api_body=$("$CURL_BIN" -fsS --max-time 20 "$STATUS_URL"); then
    _parsed=""
    if _parsed=$(printf '%s' "$_api_body" | "$PYTHON_BIN" -c '
import datetime as dt
import json, sys
d = json.load(sys.stdin)
s = d["summary"]
repos = d["repos"]
if not isinstance(repos, list) or not repos:
    raise ValueError("repos must be a non-empty list")
max_age = int(sys.argv[1])
generated = dt.datetime.fromisoformat(d["generated_at"].replace("Z", "+00:00"))
age = (dt.datetime.now(dt.timezone.utc) - generated).total_seconds()
if generated.tzinfo is None or age < -60 or age > max_age:
    raise ValueError("stale generated_at")
for key in ("total", "online", "busy", "attention"):
    if isinstance(s.get(key), bool) or not isinstance(s.get(key), int) or s[key] < 0:
        raise ValueError("invalid summary count")
if s["total"] != len(repos) or s["online"] + s["busy"] + s["attention"] != s["total"]:
    raise ValueError("summary does not match repos")
problems = 0
rows = []
names = set()
for repo in repos:
    name = repo.get("repo")
    if not isinstance(name, str) or not name or name in names:
        raise ValueError("invalid or duplicate repo identity")
    names.add(name)
    status = str(repo.get("status", "attention"))
    phase = str(repo.get("phase", "unknown"))
    host = repo.get("host") if isinstance(repo.get("host"), dict) else {}
    runner = repo.get("runner") if isinstance(repo.get("runner"), dict) else {}
    running = host.get("running") is True
    runner_status = str(runner.get("status", "unknown"))
    busy = runner.get("busy") is True
    healthy = phase == "active" and running and runner_status == "online" and status in {"online", "busy"}
    problems += 0 if healthy else 1
    rows.append("| {} | {} | {} | {} | {} |".format(name, status, phase, "yes" if running else "no", runner_status))
print("{}\t{}\t{}\t{}\t{}".format(s["total"], s["online"], s["busy"], s["attention"], problems))
print("\n".join(rows))
' "$MAX_STATUS_AGE_SECONDS"); then
      _summary=$(printf '%s\n' "$_parsed" | head -n 1)
      IFS=$'\t' read -r TOTAL ONLINE BUSY ATTENTION _problem_count <<< "$_summary"
      REPO_ROWS=$(printf '%s\n' "$_parsed" | tail -n +2)
      API_STATE="ok"
      if [ "$ATTENTION" -gt 0 ] || [ "$_problem_count" -gt 0 ]; then
        REASONS+=("$ATTENTION fleet entries need attention; $_problem_count runner records are unhealthy")
      fi
    else
      API_STATE="invalid"
      REASONS+=("local CI status API returned invalid data")
    fi
  else
    API_STATE="unreachable"
    REASONS+=("local CI status API is unreachable")
  fi
else
  OBSERVATION_FAILED=1
  REASONS+=("curl or python3 is unavailable")
fi

if [ "${#REASONS[@]}" -gt 0 ]; then
  CURRENT_STATUS="firing"
elif [ "$OBSERVATION_FAILED" -eq 1 ]; then
  case "$PRIOR_STATUS" in
    firing|clear) CURRENT_STATUS="$PRIOR_STATUS" ;;
    *) CURRENT_STATUS="unknown" ;;
  esac
else
  CURRENT_STATUS="clear"
fi

if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
fi

STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || exit 1
trap 'rm -f "$STATE_TMP"' EXIT
if ! {
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field observation_failed="$OBSERVATION_FAILED" \
    --field docker="$DOCKER_STATE" \
    --field status_service="$SERVICE_STATE" \
    --field status_api="$API_STATE" \
    --field total="$TOTAL" \
    --field attention="$ATTENTION"
  printf '\n# Local CI Health - %s\n\n' "$HOST"
  if [ "$CURRENT_STATUS" = "firing" ]; then
    printf 'Firing since %s.\n\n## Reasons\n\n' "$SINCE"
    for reason in "${REASONS[@]}"; do printf -- '- %s\n' "$reason"; done
  elif [ "$CURRENT_STATUS" = "clear" ]; then
    printf 'Docker, status collection, and all configured runners are healthy.\n'
  else
    printf 'Health is unknown because the monitor could not complete its observations.\n'
  fi
  printf '\n## Fleet\n\n- Docker: %s\n- Status service: %s\n- Status API: %s\n- Repositories: %s total, %s online, %s busy, %s attention\n' \
    "$DOCKER_STATE" "$SERVICE_STATE" "$API_STATE" "$TOTAL" "$ONLINE" "$BUSY" "$ATTENTION"
  if [ -n "$REPO_ROWS" ]; then
    printf '\n| Repository | Status | Phase | Container running | Runner |\n'
    printf '|---|---|---|---|---|\n%s\n' "$REPO_ROWS"
  fi
} > "$STATE_TMP"; then
  echo "ERROR: ceo-local-ci-health: failed to render state" >&2
  exit 1
fi
mv "$STATE_TMP" "$STATE_FILE"
trap - EXIT

printf '%s status=%s docker=%s service=%s api=%s total=%s attention=%s observation_failed=%s\n' \
  "$NOW" "$CURRENT_STATUS" "$DOCKER_STATE" "$SERVICE_STATE" "$API_STATE" "$TOTAL" "$ATTENTION" "$OBSERVATION_FAILED" >> "$LOG_FILE"

TASK_MARKER="<!-- local-ci-health:$HOST -->"
TASK_LINE="- [ ] Restore local CI health on $HOST - see [[CEO/alerts/local-ci-health-$HOST]] $TASK_MARKER"
touch "$INBOX_FILE"

active_task_present() {
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

if [ "$PRIOR_STATUS" != "unknown" ] && [ "$CURRENT_STATUS" != "unknown" ]; then
  if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
    _since_epoch=$(date -d "$PRIOR_SINCE" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$PRIOR_SINCE" +%s 2>/dev/null || echo 0)
    _now_epoch=$(date +%s)
    if [ "$_since_epoch" -gt 0 ] && [ $((_now_epoch - _since_epoch)) -ge "$SUSTAINED_SECONDS" ]; then
      active_task_present || printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
    fi
  elif [ "$OBSERVATION_FAILED" -eq 0 ] && [ "$CURRENT_STATUS" = "clear" ] && active_task_present; then
    _tmpfile=$(mktemp) || exit 1
    trap 'rm -f "$_tmpfile"' EXIT
    _replacement="- [done] Local CI health restored on $HOST $(date +%Y-%m-%d) $TASK_MARKER"
    awk -v m="$TASK_MARKER" -v r="$_replacement" '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$_tmpfile"
    mv "$_tmpfile" "$INBOX_FILE"
    trap - EXIT
  fi
fi

exit 0
