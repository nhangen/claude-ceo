#!/bin/bash
# Self-contained test harness for `ceo status` and `ceo playbook next-runs` (#237).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$CEO_DIR/log" "$HOME/.ceo"

  # Create fixture registry
  cat > "$HOME/.ceo/registry.json" << 'JSON'
{
  "schema_version": 3,
  "generated": "2026-06-07T00:00:00Z",
  "playbooks": [
    {
      "name": "morning-scan",
      "description": "morning inbox scan",
      "schedule": "0 9 * * *",
      "status": "active",
      "trigger": "cron",
      "scope": "single"
    },
    {
      "name": "pr-review",
      "description": "review PRs",
      "schedule": "*/30 * * * *",
      "status": "active",
      "trigger": "cron",
      "scope": "each"
    }
  ]
}
JSON

  # Enabled and swarm
  echo '["pr-review"]' > "$HOME/.ceo/enabled.json"
  echo '{"hosts":["testhost"],"owners":{"morning-scan":"testhost"}}' > "$CEO_DIR/swarm.json"

  # Heartbeat (fresh)
  local now_ms=$(( $(date +%s) * 1000 ))
  mkdir -p "$HOME/.ceo/schedulerd"
  printf '{"ts":%s,"host":"testhost","dispatched_minute":{},"last_fired":{}}\n' "$now_ms" \
    > "$HOME/.ceo/schedulerd/heartbeat.json"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_status_outputs_table() {
  local out rc=0
  out=$(bash "$CEO_CLI" status 2>&1) || rc=$?
  assert_eq "$rc" "0" "ceo status must exit 0"
  assert_contains "$out" "host=testhost" "status must report host"
  assert_contains "$out" "morning-scan" "status must include morning-scan"
  assert_contains "$out" "pr-review" "status must include pr-review"
  assert_contains "$out" "NEXT FIRE" "status must include NEXT FIRE column"
  assert_contains "$out" "HEALTH" "status must include HEALTH column"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_json_outputs_json() {
  local out rc=0
  out=$(bash "$CEO_CLI" status --json 2>&1) || rc=$?
  assert_eq "$rc" "0" "ceo status --json must exit 0"
  local host
  host=$(echo "$out" | jq -r '.host' 2>/dev/null)
  assert_eq "$host" "testhost" "status JSON must parse and report host"
  local job_count
  job_count=$(echo "$out" | jq '.jobs | length' 2>/dev/null)
  assert_eq "$job_count" "2" "status JSON must have 2 jobs"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_next_runs_outputs_table() {
  local out rc=0
  out=$(bash "$CEO_CLI" playbook next-runs 2>&1) || rc=$?
  assert_eq "$rc" "0" "ceo playbook next-runs must exit 0"
  assert_contains "$out" "NAME" "next-runs must include header"
  assert_contains "$out" "NEXT FIRE" "next-runs must include NEXT FIRE header"
  assert_contains "$out" "IN" "next-runs must include IN header"
  assert_contains "$out" "pr-review" "next-runs must include runnable job"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_next_runs_json_outputs_json() {
  local out rc=0
  out=$(bash "$CEO_CLI" playbook next-runs --json 2>&1) || rc=$?
  assert_eq "$rc" "0" "ceo playbook next-runs --json must exit 0"
  local count
  count=$(echo "$out" | jq '.nextRuns | length' 2>/dev/null)
  assert_eq "$count" "2" "next-runs JSON must report upcoming runs"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_next_runs_filters_by_within() {
  # pr-review fires */30 (within 30m), morning-scan fires 0 9 * * * (within 24h)
  local out rc=0
  out=$(bash "$CEO_CLI" playbook next-runs --within 31m 2>&1) || rc=$?
  assert_eq "$rc" "0" "ceo playbook next-runs --within must exit 0"
  assert_contains "$out" "pr-review" "pr-review must be in next-runs (cadence <= 30m)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_exits_69_on_stale_heartbeat() {
  # Write a heartbeat older than 600s
  local old_ms=$(( ($(date +%s) - 900) * 1000 ))
  printf '{"ts":%s,"host":"testhost","dispatched_minute":{},"last_fired":{}}\n' "$old_ms" \
    > "$HOME/.ceo/schedulerd/heartbeat.json"

  local out rc=0
  out=$(bash "$CEO_CLI" status 2>&1) || rc=$?
  assert_eq "$rc" "69" "ceo status on stale daemon must exit 69 (STALE_EXIT_CODE)"
  assert_contains "$out" "ALERT: daemon heartbeat stale" "must print stale daemon alert to stderr"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_fails_gracefully_when_bun_missing() {
  local out rc=0
  out=$(PATH="/usr/bin:/bin" bash "$CEO_CLI" status 2>&1) || rc=$?
  assert_eq "$rc" "1" "status must exit 1 when bun is missing"
  assert_contains "$out" "bun is required" "must report bun is required"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_next_runs_fails_gracefully_when_bun_missing() {
  local out rc=0
  out=$(PATH="/usr/bin:/bin" bash "$CEO_CLI" playbook next-runs 2>&1) || rc=$?
  assert_eq "$rc" "1" "next-runs must exit 1 when bun is missing"
  assert_contains "$out" "bun is required" "must report bun is required"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
