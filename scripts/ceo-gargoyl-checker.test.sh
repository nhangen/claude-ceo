#!/bin/bash
# Self-contained test harness for ceo-gargoyl-checker.sh (#653).
# Verifies the calibrated probes, the transition-only Discord/alert semantics,
# the dispatcher outcome contract, and that no webhook URL reaches any log,
# note, or captured output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/ceo-gargoyl-checker.sh"
source "$SCRIPT_DIR/test-harness.sh"

gen_report() {
  # $1 = age of the newest snapshot in seconds
  python3 - "$1" > "$REPORT_STUB_FILE" <<'PY'
import datetime as dt, json, sys
age = int(sys.argv[1])
stamp = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"snapshots": [{"collected_at": stamp}]}, sys.stdout)
PY
}

setup() {
  TEST_HOME=$(mktemp -d)
  export TEST_HOME
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME/home"
  mkdir -p "$HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR"
  touch "$CEO_DIR/inbox.md"
  export CEO_HOSTNAME="checker-test"
  # Never let a test reach the real secrets file.
  export CEO_SECRETS_FILE="$TEST_HOME/secrets.json"
  export CEO_RUNNER_OUTCOME_FILE="$TEST_HOME/outcome"
  export GARGOYL_CHECKER_LOG_DIR="$TEST_HOME/checker-logs"
  export GARGOYL_MONITOR_LOG_DIR="$TEST_HOME/monitor-logs"
  export GARGOYL_FLEET_JSON="$TEST_HOME/fleet.json"
  export GARGOYL_DASHBOARD_URL="http://127.0.0.1:8766"
  export GARGOYL_NOTIFY_DEBUG_LOG="$TEST_HOME/notify.log"
  export WEBHOOK_URL="https://discord.example.invalid/api/webhooks/0/stub"
  export GARGOYL_DISCORD_WEBHOOK_URL="$WEBHOOK_URL"
  export REPORT_STUB_FILE="$TEST_HOME/report.json"
  mkdir -p "$GARGOYL_MONITOR_LOG_DIR" "$TEST_HOME/stubs"

  cat > "$TEST_HOME/stubs/curl" <<STUB
#!/bin/bash
# Validates argv shape (stub-cli-argv-validation): every invocation must carry
# --max-time and end in a URL the checker can produce.
found_max_time=0
for a in "\$@"; do
  [ "\$a" = "--max-time" ] && found_max_time=1
done
[ "\$found_max_time" = "1" ] || exit 64
url=""
for a in "\$@"; do url="\$a"; done
case "\$url" in
  "\$WEBHOOK_URL")
    payload=""
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-d" ]; then payload="\$a"; fi
      prev="\$a"
    done
    printf 'POST %s\n' "\$payload" >> "\$TEST_HOME/discord-posts"
    if [ -n "\${GARGOYL_CURL_DISCORD_HTTP:-}" ]; then
      printf '%s\n' "\$GARGOYL_CURL_DISCORD_HTTP"
    else
      printf '204\n'
    fi
    exit 0
    ;;
  "\$GARGOYL_DASHBOARD_URL/report.json")
    [ -n "\${GARGOYL_CURL_REPORT_FAIL:-}" ] && exit 22
    cat "\$REPORT_STUB_FILE"
    exit 0
    ;;
  "\$GARGOYL_DASHBOARD_URL/"|\$GARGOYL_DASHBOARD_URL"/status")
    [ -n "\${GARGOYL_CURL_DASHBOARD_FAIL:-}" ] && exit 22
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
STUB
  cat > "$TEST_HOME/stubs/launchctl" <<'STUB'
#!/bin/bash
[ "$1" = "list" ] || exit 64
[ -n "${LAUNCHCTL_STUB_ABSENT:-}" ] && exit 0
row="${LAUNCHCTL_STUB_ROW:-$(printf '\t0\tdev.gargoyl.monitor')}"
printf '%s\n' "$row"
STUB
  cat > "$TEST_HOME/stubs/pgrep" <<'STUB'
#!/bin/bash
[ "$1" = "-f" ] || exit 64
exit "${PGREP_STUB_RC:-0}"
STUB
  chmod +x "$TEST_HOME/stubs/curl" "$TEST_HOME/stubs/launchctl" "$TEST_HOME/stubs/pgrep"
  export PATH="$TEST_HOME/stubs:$PATH"

  # Green fixtures by default: stderr log present, fleet.json parses, fresh
  # collector snapshot, launchd row clean, monitor process alive.
  printf 'monitor stderr baseline\n' > "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log"
  printf '%s\n' '{"connection":"online"}' > "$GARGOYL_FLEET_JSON"
  gen_report 60
  unset GARGOYL_CURL_DASHBOARD_FAIL GARGOYL_CURL_REPORT_FAIL GARGOYL_CURL_DISCORD_HTTP \
    LAUNCHCTL_STUB_ROW LAUNCHCTL_STUB_ABSENT PGREP_STUB_RC
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset TEST_HOME HOME_BACKUP PATH_BACKUP
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME CEO_SECRETS_FILE CEO_RUNNER_OUTCOME_FILE
  unset GARGOYL_CHECKER_LOG_DIR GARGOYL_MONITOR_LOG_DIR GARGOYL_FLEET_JSON
  unset GARGOYL_DASHBOARD_URL GARGOYL_NOTIFY_DEBUG_LOG WEBHOOK_URL GARGOYL_DISCORD_WEBHOOK_URL
  unset REPORT_STUB_FILE
  unset GARGOYL_CURL_DASHBOARD_FAIL GARGOYL_CURL_REPORT_FAIL GARGOYL_CURL_DISCORD_HTTP
  unset LAUNCHCTL_STUB_ROW LAUNCHCTL_STUB_ABSENT PGREP_STUB_RC
}

alert_file() {
  printf '%s/CEO/alerts/gargoyl-checker-%s.md' "$CEO_VAULT" "$CEO_HOSTNAME"
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" "$(alert_file)"
}

run_checker() {
  # Captures stdout/stderr to files and stores the exit code in
  # RUN_CHECKER_RC so call sites do not leak it to test stdout.
  RUN_CHECKER_RC=0
  bash "$CHECKER" > "$TEST_HOME/stdout" 2> "$TEST_HOME/stderr" || RUN_CHECKER_RC=$?
}

checker_stdout() {
  cat "$TEST_HOME/stdout" 2>/dev/null
}

checker_stderr() {
  cat "$TEST_HOME/stderr" 2>/dev/null
}

checker_log() {
  cat "$GARGOYL_CHECKER_LOG_DIR/checker.log" 2>/dev/null
}

discord_posts() {
  cat "$TEST_HOME/discord-posts" 2>/dev/null
}

discord_count() {
  # Payloads are pretty-printed multi-line JSON; count messages, not lines.
  if [ -f "$TEST_HOME/discord-posts" ]; then
    grep -c '^POST ' "$TEST_HOME/discord-posts" || true
  else
    printf '0'
  fi
}

outcome() {
  cat "$CEO_RUNNER_OUTCOME_FILE" 2>/dev/null
}

assert_no_webhook_leak() {
  local where="$1" body="$2"
  assert_not_contains "$body" "$WEBHOOK_URL" "$where must not contain the webhook URL"
}

test_green_run_is_silent() {
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a healthy monitor must exit 0"
  assert_not_contains "$(checker_stdout)" "FAILED" "green run must not report a failure"
  assert_eq "$(discord_count)" "0" "green run must not post to Discord"
  assert_eq "$(outcome)" "noop" "green run must report noop to the dispatcher"
  [ -f "$(alert_file)" ] && fail_test "green run must not write an alerts note (transition-only)"
  return 0
}

test_green_run_logs_informational_notes() {
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "green run must exit 0"
  assert_contains "$(checker_stdout)" "informational only" "stderr staleness note must appear"
  assert_contains "$(checker_stdout)" "connection=online" "fleet.json connection note must appear"
  assert_contains "$(checker_stdout)" "collector newest" "collector cadence note must appear"
}

test_stale_stderr_is_not_a_failure() {
  # Calibrated 2026-11-05: the monitor is event-driven and legitimately silent.
  python3 - "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log" <<'PY'
import os, sys, time
old = time.time() - 7 * 86400
os.utime(sys.argv[1], (old, old))
PY
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a days-old stderr log must stay green"
  assert_contains "$(checker_stdout)" "informational only" "staleness must be logged as informational"
}

test_first_failure_notifies_exactly_once() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a failing probe is recorded and notified, so the run exits 0"
  assert_eq "$(state_field status)" "firing" "first failure must record firing"
  assert_eq "$(state_field reason)" "monitor dashboard on http://127.0.0.1:8766 did not answer a loopback GET within 5s (process present but wedged)" \
    "the alert must carry the probe reason"
  assert_eq "$(discord_count)" "1" "healthy->failed must produce exactly one Discord message"
  assert_contains "$(discord_posts)" "FAILED" "the Discord message must report the failure"
  assert_contains "$(discord_posts)" "did not answer a loopback GET" "the Discord message must carry the reason"
  assert_eq "$(outcome)" "noop" "a delivered failure notice leaves the dispatcher quiet"
  assert_eq "$(state_field notified)" "true" "a delivered notice must be recorded as notified"
  assert_contains "$(checker_log)" "transition: NEW FAILURE" "the checker log must record the transition"
}

test_steady_failure_does_not_spam() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  local first_since
  first_since=$(state_field since)
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$(discord_count)" "1" "a repeat failure must not post a second Discord message"
  assert_contains "$(checker_log)" "still failing" "repeat failure must be logged without a notify"
  assert_eq "$(state_field since)" "$first_since" "since must be preserved across repeat failures"
}

test_recovery_notifies_once() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "recovery must exit 0"
  assert_eq "$(state_field status)" "clear" "recovery must record clear"
  assert_eq "$(discord_count)" "2" "failed->recovered must post exactly one more message"
  assert_contains "$(discord_posts)" "recovered" "the recovery message must say recovered"
  assert_contains "$(discord_posts)" "green again" "the recovery message must say green again"
  assert_eq "$(outcome)" "noop" "recovery already posted its own notice; dispatcher stays quiet"
  assert_contains "$(checker_log)" "transition: RECOVERED" "the checker log must record the recovery"
}

test_steady_recovery_is_silent() {
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "first green run must exit 0"
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "second green run must exit 0"
  assert_eq "$(discord_count)" "0" "steady green must not post"
}

test_launchd_job_absent_fails() {
  LAUNCHCTL_STUB_ABSENT=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "the launchd failure is recorded and notified, so the run exits 0"
  assert_eq "$(state_field status)" "firing" "an unloaded daemon must fire"
  assert_contains "$(state_field reason)" "launchd has no job named dev.gargoyl.monitor" "reason must name the missing launchd job"
  assert_eq "$(discord_count)" "1" "the launchd failure is a transition and must notify"
}

test_bad_launchd_exit_status_fails() {
  LAUNCHCTL_STUB_ROW="$(printf '\t5\tdev.gargoyl.monitor')" run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a bad launchd exit status is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "last exit status is 5" "reason must carry the launchd exit status"
  assert_eq "$(outcome)" "noop" "a recorded, notified failure must report noop"
}

test_monitor_process_gone_fails() {
  PGREP_STUB_RC=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a missing monitor process is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "no running gargoyl monitor process found" "reason must name the dead process"
  assert_eq "$(outcome)" "noop" "a recorded, notified failure must report noop"
}

test_report_json_unreachable_fails() {
  GARGOYL_CURL_REPORT_FAIL=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a wedged dashboard is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "/report.json did not answer a loopback GET" "reason must name the wedged report endpoint"
  assert_eq "$(outcome)" "noop" "a recorded, notified failure must report noop"
}

test_stale_collector_fails() {
  gen_report 3600
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a stale collector is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "collection loop appears wedged" "a stale snapshot must fire the wedge probe"
}

test_report_without_snapshots_fails() {
  printf '%s\n' '{"snapshots":[]}' > "$REPORT_STUB_FILE"
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a snapshot-less report is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "returned no snapshots" "an empty report must fire"
}

test_fleet_json_unreadable_fails() {
  printf 'not json at all\n' > "$GARGOYL_FLEET_JSON"
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "an unreadable fleet.json is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "fleet.json exists but does not parse as JSON" "a parse failure must be a finding"
}

test_stderr_traceback_fails() {
  printf 'Traceback (most recent call last):\n  File "monitor.py"\n' >> "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log"
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a fresh traceback is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "Traceback" "fresh traceback shapes must fire"
}

test_missing_monitor_logs_fail() {
  rm -f "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log"
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "missing monitor logs is recorded and notified, so the run exits 0"
  assert_contains "$(state_field reason)" "no monitor logs exist" "missing logs must fire"
}

test_notify_events_off_suppresses_discord_but_not_the_note() {
  printf '%s\n' '{"notify_events":"off"}' > "$CEO_DIR/settings.json"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$(state_field status)" "firing" "the alert note still records the failure"
  assert_eq "$(discord_count)" "0" "notify_events=off must suppress the Discord post"
}

test_webhook_never_reaches_logs_notes_or_output() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_no_webhook_leak "checker log" "$(checker_log)"
  assert_no_webhook_leak "notify log" "$(cat "$GARGOYL_NOTIFY_DEBUG_LOG" 2>/dev/null)"
  assert_no_webhook_leak "stdout" "$(checker_stdout)"
  assert_no_webhook_leak "stderr" "$(checker_stderr)"
  assert_no_webhook_leak "alert note" "$(cat "$(alert_file)")"
  assert_no_webhook_leak "discord payload" "$(discord_posts)"
}

test_discord_delivery_failure_is_logged_not_swallowed() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 GARGOYL_CURL_DISCORD_HTTP=500 run_checker
  assert_eq "$RUN_CHECKER_RC" "1" "an undelivered failure notice must exit 1 so the dispatcher escalates"
  assert_contains "$(checker_stderr)" "Discord failed notice failed (HTTP 500)" "a failed delivery must be reported on stderr with the code"
  assert_contains "$(cat "$GARGOYL_NOTIFY_DEBUG_LOG" 2>/dev/null)" "Discord delivery for failed failed (HTTP 500)" "a failed delivery must be logged with the code"
}

test_corrupt_prior_state_suppresses_transition_notice() {
  # A note whose status field is missing is corruption: the checker cannot tell
  # fresh failure from repeat, so it records state without notifying.
  mkdir -p "$CEO_DIR/alerts"
  printf -- '---\nhost: %s\n---\n\nstale body\n' "$CEO_HOSTNAME" > "$(alert_file)"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$(discord_count)" "0" "unknown prior state must not notify"
  assert_eq "$(state_field status)" "firing" "the state must be repaired to firing"
  assert_contains "$(checker_log)" "prior state unknown" "the suppression must be logged"
}

test_undelivered_failure_notice_escalates_and_retries() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 GARGOYL_CURL_DISCORD_HTTP=500 run_checker
  assert_eq "$RUN_CHECKER_RC" "1" "an undelivered notice must exit 1"
  assert_eq "$(outcome)" "" "an undelivered notice must not claim failure-notified or noop"
  assert_eq "$(state_field status)" "firing" "the failure is still recorded"
  assert_eq "$(state_field notified)" "false" "the undelivered notice must be recorded for retry"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "the retried notice landed, so the run exits 0"
  assert_eq "$(discord_count)" "2" "the next run must retry the undelivered notice"
  assert_eq "$(state_field notified)" "true" "the retry must be recorded as delivered"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$(discord_count)" "2" "once delivered, repeat failures stay silent"
}

test_missing_webhook_escalates() {
  unset GARGOYL_DISCORD_WEBHOOK_URL
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "1" "no webhook means the notice did not land"
  assert_eq "$(outcome)" "" "no webhook must not suppress the dispatcher"
}

test_undelivered_recovery_notice_retries() {
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  GARGOYL_CURL_DISCORD_HTTP=500 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a green run exits 0 even when its recovery notice failed"
  assert_eq "$(state_field status)" "clear" "recovery is recorded"
  assert_eq "$(state_field notified)" "false" "the undelivered recovery notice is recorded for retry"
  run_checker
  assert_eq "$(discord_count)" "3" "the next green run must retry the recovery notice"
  assert_eq "$(state_field notified)" "true" "the retried recovery notice is recorded"
  run_checker
  assert_eq "$(discord_count)" "3" "steady green after delivery stays silent"
}

test_notify_events_off_counts_as_delivered() {
  printf '%s\n' '{"notify_events":"off"}' > "$CEO_DIR/settings.json"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a deliberately silenced notice is not a delivery failure"
  assert_eq "$(outcome)" "noop" "silenced runs report noop"
}

test_unwritable_alerts_dir_skips_discord_and_escalates() {
  mkdir -p "$CEO_DIR/alerts"
  chmod 555 "$CEO_DIR/alerts"
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  GARGOYL_CURL_DASHBOARD_FAIL=1 run_checker
  chmod 755 "$CEO_DIR/alerts"
  assert_eq "$RUN_CHECKER_RC" "1" "an unrecordable state is a checker fault"
  assert_eq "$(outcome)" "" "a checker fault must leave the dispatcher in charge"
  assert_eq "$(discord_count)" "0" "without persisted state the checker must not post (it would repeat every run)"
}

test_old_traceback_in_quiet_log_does_not_fire() {
  # A crash launchd already recovered must not keep the watch red for days
  # while the event-driven monitor stays quiet.
  printf 'Traceback (most recent call last):\n  File "monitor.py"\n' >> "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log"
  python3 - "$GARGOYL_MONITOR_LOG_DIR/monitor.stderr.log" <<'PY2'
import os, sys, time
old = time.time() - 5 * 86400
os.utime(sys.argv[1], (old, old))
PY2
  run_checker
  assert_eq "$RUN_CHECKER_RC" "0" "a five-day-old traceback must not fire"
  [ -f "$(alert_file)" ] && fail_test "an old traceback must not record a failure"
  return 0
}

test_playbook_scan_registers_gargoyl_checker() {
  local ceo_cli="$SCRIPT_DIR/ceo"
  mkdir -p "$CEO_DIR/playbooks"
  cp "$SCRIPT_DIR/../docs/playbooks/gargoyl-checker.md" "$CEO_DIR/playbooks/gargoyl-checker.md"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"

  bash "$ceo_cli" playbook scan >/dev/null 2>&1
  local reg="$HOME/.ceo/registry.json"
  assert_file_exists "$reg" "registry must exist after scan"
  local sel='.playbooks[] | select(.name=="gargoyl-checker")'
  assert_eq "$(jq -r "$sel | .status" "$reg")" "active" "status is active"
  assert_eq "$(jq -r "$sel | .runner" "$reg")" "script" "runner is script"
  assert_eq "$(jq -r "$sel | .script" "$reg")" "ceo-gargoyl-checker.sh" "script is ceo-gargoyl-checker.sh"
  assert_eq "$(jq -r "$sel | .scope" "$reg")" "each" "scope is each"
  assert_eq "$(jq -r "$sel | .schedule" "$reg")" "*/5 * * * *" "schedule is every five minutes"
}

run_tests "$@"
