#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/ceo-local-ci-health.sh"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  export TEST_HOME
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_HOSTNAME="ml1-test"
  export CEO_LOCAL_CI_STATUS_URL="http://status.test/api/status"
  export CEO_LOCAL_CI_CONFIG="$TEST_HOME/config.toml"
  export CEO_LOCAL_CI_SUSTAINED_SECONDS=0
  export CEO_LOCAL_CI_MAX_STATUS_AGE_SECONDS=120
  export CEO_LOCAL_CI_PROBE_TIMEOUT_SECONDS=1
  export CEO_RUNNER_OUTCOME_FILE="$TEST_HOME/outcome"
  export CEO_LOCAL_CI_DOCKER_BIN="$TEST_HOME/stubs/docker"
  export CEO_LOCAL_CI_SYSTEMCTL_BIN="$TEST_HOME/stubs/systemctl"
  export CEO_LOCAL_CI_CURL_BIN="$TEST_HOME/stubs/curl"
  CEO_LOCAL_CI_TIMEOUT_BIN=$(command -v timeout)
  export CEO_LOCAL_CI_TIMEOUT_BIN
  mkdir -p "$CEO_VAULT/CEO" "$TEST_HOME/stubs"
  touch "$CEO_VAULT/CEO/inbox.md"
  write_config one two

  python3 - <<PY
import datetime as dt, json
data = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "summary":{"total":2,"online":1,"busy":1,"attention":0},"repos":[{"repo":"one","phase":"active","host":{"running":True},"runner":{"status":"online","busy":False},"status":"online"},{"repo":"two","phase":"active","host":{"running":True},"runner":{"status":"online","busy":True},"status":"busy"}]}
open("$TEST_HOME/healthy.json", "w").write(json.dumps(data))
PY
  export API_STUB_FILE="$TEST_HOME/healthy.json"

  cat > "$TEST_HOME/stubs/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_HOME/docker-calls"
[ -z "${DOCKER_STUB_FAIL:-}" ]
STUB
  cat > "$TEST_HOME/stubs/systemctl" <<'STUB'
#!/bin/bash
[ -z "${SERVICE_STUB_FAIL:-}" ]
STUB
  cat > "$TEST_HOME/stubs/curl" <<'STUB'
#!/bin/bash
[ -z "${CURL_STUB_FAIL:-}" ] || exit 7
cat "$API_STUB_FILE"
STUB
  chmod +x "$TEST_HOME/stubs/docker" "$TEST_HOME/stubs/systemctl" "$TEST_HOME/stubs/curl"
  export PATH="$TEST_HOME/stubs:$PATH"
  unset DOCKER_STUB_FAIL SERVICE_STUB_FAIL CURL_STUB_FAIL
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_HOSTNAME CEO_LOCAL_CI_STATUS_URL CEO_LOCAL_CI_SUSTAINED_SECONDS
  unset CEO_LOCAL_CI_CONFIG
  unset CEO_LOCAL_CI_MAX_STATUS_AGE_SECONDS CEO_LOCAL_CI_PROBE_TIMEOUT_SECONDS CEO_LOCAL_CI_TIMEOUT_BIN
  unset CEO_RUNNER_OUTCOME_FILE
  unset CEO_LOCAL_CI_DOCKER_BIN CEO_LOCAL_CI_SYSTEMCTL_BIN CEO_LOCAL_CI_CURL_BIN
  unset API_STUB_FILE TEST_HOME HOME_BACKUP PATH_BACKUP
  unset DOCKER_STUB_FAIL SERVICE_STUB_FAIL CURL_STUB_FAIL
}

run_monitor() {
  local rc=0
  bash "$MONITOR" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_test "monitor exited non-zero" "rc=$rc"
  fi
  return 0
}

run_monitor_raw() {
  bash "$MONITOR" >/dev/null 2>&1
}

write_config() {
  : > "$CEO_LOCAL_CI_CONFIG"
  local repo
  for repo in "$@"; do
    printf '[repos.%s]\n' "$repo" >> "$CEO_LOCAL_CI_CONFIG"
  done
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" "$CEO_VAULT/CEO/alerts/local-ci-health-$CEO_HOSTNAME.md" | tr -d '[:space:]'
}

outcome() {
  cat "$CEO_RUNNER_OUTCOME_FILE" 2>/dev/null
}

test_healthy_fleet_is_clear_and_dynamic() {
  run_monitor
  assert_eq "$(state_field status)" "clear" "healthy fleet should be clear"
  local body
  body=$(cat "$CEO_VAULT/CEO/alerts/local-ci-health-$CEO_HOSTNAME.md")
  assert_contains "$body" "| one | online |" "first configured repository should be reported"
  assert_contains "$body" "| two | busy |" "busy runner should remain healthy"
  assert_eq "$(outcome)" "noop" "healthy check should stay silent"
}

test_timeout_resolver_supports_normal_invocation() {
  unset CEO_LOCAL_CI_TIMEOUT_BIN
  run_monitor
  assert_eq "$(state_field status)" "clear" "normal invocation should resolve a timeout command"
  assert_eq "$(state_field docker)" "ok" "resolved timeout should run the Docker probe"
  assert_eq "$(state_field status_service)" "active" "resolved timeout should run the service probe"
}

test_docker_failure_fires_without_restarting() {
  DOCKER_STUB_FAIL=1 run_monitor
  assert_eq "$(state_field status)" "firing" "unusable Docker socket should fire"
  local calls
  calls=$(cat "$TEST_HOME/docker-calls")
  assert_eq "$calls" "info" "monitor must never restart Docker"
}

test_sustained_failure_escalates_once() {
  DOCKER_STUB_FAIL=1 run_monitor
  assert_eq "$(outcome)" "noop" "first failure should stay silent"
  if [ -s "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md" ]; then
    fail_test "first failure must not create an inbox task"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
  DOCKER_STUB_FAIL=1 run_monitor
  assert_eq "$(outcome)" "fired" "sustained escalation should notify"
  DOCKER_STUB_FAIL=1 run_monitor
  assert_eq "$(outcome)" "noop" "steady firing should stay silent"
  local count
  count=$(grep -c -F -- "- [ ] Restore local CI health" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "sustained failure should create one task"
}

test_checked_task_is_not_recreated_during_same_failure() {
  DOCKER_STUB_FAIL=1 run_monitor
  DOCKER_STUB_FAIL=1 run_monitor
  sed -i.bak 's/^- \[ \]/- [x]/' "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md"
  rm -f "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md.bak"
  DOCKER_STUB_FAIL=1 run_monitor
  local count
  count=$(grep -c -F -- "<!-- local-ci-health:$CEO_HOSTNAME:" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "same failure generation should keep one task marker"
  assert_eq "$(outcome)" "noop" "checked task should not re-notify during same failure"
}

test_recovery_closes_active_task() {
  DOCKER_STUB_FAIL=1 run_monitor
  DOCKER_STUB_FAIL=1 run_monitor
  run_monitor
  assert_eq "$(state_field status)" "clear" "recovery should clear alert"
  local inbox
  inbox=$(cat "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_contains "$inbox" "- [done] Local CI health restored" "recovery should close the task"
  assert_not_contains "$inbox" "- [ ] Restore local CI health" "no active task should remain"
  assert_eq "$(outcome)" "fired" "recovery should notify"
}

test_invalid_api_preserves_firing_and_escalates() {
  DOCKER_STUB_FAIL=1 run_monitor
  printf '{bad json' > "$API_STUB_FILE"
  run_monitor
  assert_eq "$(state_field status)" "firing" "failed observation must not clear a firing alert"
  assert_eq "$(state_field observation_failed)" "0" "invalid API data is a confirmed service failure"
  local count
  count=$(grep -c -F -- "- [ ] Restore local CI health" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "persistent invalid API data should create one task"
}

test_unreachable_api_escalates_when_sustained() {
  CURL_STUB_FAIL=1 run_monitor
  CURL_STUB_FAIL=1 run_monitor
  local count
  count=$(grep -c -F -- "- [ ] Restore local CI health" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "sustained API outage should create one task"
}

test_stale_snapshot_cannot_clear_active_alert() {
  DOCKER_STUB_FAIL=1 run_monitor
  DOCKER_STUB_FAIL=1 run_monitor
  python3 - <<PY
import json
p = "$API_STUB_FILE"
d = json.load(open(p))
d["generated_at"] = "2000-01-01T00:00:00+00:00"
open(p, "w").write(json.dumps(d))
PY
  run_monitor
  assert_eq "$(state_field status)" "firing" "stale status snapshot must not clear an alert"
  local inbox
  inbox=$(cat "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_contains "$inbox" "- [ ] Restore local CI health" "stale data must not close the active task"
}

test_error_shaped_repo_is_reported_as_unhealthy() {
  write_config broken
  python3 - <<PY
import datetime as dt, json
data = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "summary":{"total":1,"online":0,"busy":0,"attention":1},"repos":[{"repo":"broken","status":"attention","error":"host unavailable"}]}
open("$API_STUB_FILE", "w").write(json.dumps(data))
PY
  run_monitor
  assert_eq "$(state_field status)" "firing" "error-shaped API row should fire"
  assert_eq "$(state_field status_api)" "ok" "valid error-shaped API response should parse"
}

test_hung_docker_probe_is_bounded() {
  cat > "$CEO_LOCAL_CI_DOCKER_BIN" <<'STUB'
#!/bin/bash
sleep 5
STUB
  local start elapsed
  start=$(date +%s)
  run_monitor
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -ge 4 ]; then
    fail_test "Docker probe exceeded its one-second timeout" "elapsed=${elapsed}s"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
  assert_eq "$(state_field status)" "firing" "timed-out Docker probe should fire"
}

test_clear_retries_an_interrupted_inbox_recovery() {
  if [ "$(id -u)" = "0" ]; then
    skip_test "directory permissions do not block root"
    return 0
  fi
  DOCKER_STUB_FAIL=1 run_monitor
  DOCKER_STUB_FAIL=1 run_monitor
  chmod 0500 "$CEO_VAULT/CEO/inbox"
  run_monitor_raw || true
  chmod 0700 "$CEO_VAULT/CEO/inbox"
  assert_eq "$(state_field status)" "clear" "state should already record confirmed recovery"
  run_monitor
  local inbox
  inbox=$(cat "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_contains "$inbox" "- [done] Local CI health restored" "next clear run should retry inbox reconciliation"
  assert_not_contains "$inbox" "- [ ] Restore local CI health" "retried recovery should close the task"
}

test_log_append_failure_does_not_block_escalation() {
  if [ "$(id -u)" = "0" ]; then
    skip_test "file permissions do not block root"
    return 0
  fi
  run_monitor
  local log_file
  log_file="$CEO_VAULT/CEO/log/local-ci-health/$(date +%Y-%m).md"
  chmod 0400 "$log_file"
  DOCKER_STUB_FAIL=1 run_monitor
  DOCKER_STUB_FAIL=1 run_monitor
  chmod 0600 "$log_file"
  local count
  count=$(grep -c -F -- "- [ ] Restore local CI health" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "forensic log failure must not block escalation"
}

test_unhealthy_dynamic_runner_fires() {
  write_config offline-repo
  python3 - <<PY
import datetime as dt, json
data = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "summary":{"total":1,"online":0,"busy":0,"attention":1},"repos":[{"repo":"offline-repo","phase":"active","host":{"running":True},"runner":{"status":"offline","busy":False},"status":"attention"}]}
open("$API_STUB_FILE", "w").write(json.dumps(data))
PY
  run_monitor
  assert_eq "$(state_field status)" "firing" "offline configured runner should fire"
  local body
  body=$(cat "$CEO_VAULT/CEO/alerts/local-ci-health-$CEO_HOSTNAME.md")
  assert_contains "$body" "| offline-repo | attention |" "unhealthy repository should be named"
}

test_config_change_missing_from_live_snapshot_fires() {
  write_config one two three
  run_monitor
  assert_eq "$(state_field status)" "firing" "snapshot missing a configured repository should fire"
  assert_eq "$(state_field status_api)" "invalid" "config mismatch should invalidate the snapshot"
}

test_inactive_status_service_fires() {
  SERVICE_STUB_FAIL=1 run_monitor
  assert_eq "$(state_field status)" "firing" "inactive status service should fire"
}

test_missing_probe_tool_escalates_when_sustained() {
  CEO_LOCAL_CI_DOCKER_BIN="$TEST_HOME/stubs/missing-docker" run_monitor
  CEO_LOCAL_CI_DOCKER_BIN="$TEST_HOME/stubs/missing-docker" run_monitor
  assert_eq "$(state_field observation_failed)" "1" "missing probe tool should mark incomplete observation"
  local count
  count=$(grep -c -F -- "- [ ] Restore local CI health" "$CEO_VAULT/CEO/inbox/$CEO_HOSTNAME.md")
  assert_eq "$count" "1" "sustained monitor failure should create one task"
}

run_tests
