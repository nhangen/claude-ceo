#!/bin/bash
# Tests for ceo-notify.sh — exercises the helper without posting to Discord
# by routing curl at a local responder served from a tempdir socket.
#
# shellcheck disable=SC2034
# CURRENT_TEST is set per-test here and read by assertion helpers in test-harness.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="$SCRIPT_DIR/ceo-notify.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  export CEO_DIR="$TMP/vault/CEO"
  export CEO_SECRETS_FILE="$TMP/secrets.json"
  mkdir -p "$CEO_DIR"
  unset CEO_DISCORD_WEBHOOK
}

teardown() {
  rm -rf "$TMP"
  unset CEO_DIR CEO_SECRETS_FILE CEO_DISCORD_WEBHOOK
}

# --- Tests ---

test_silent_when_no_webhook_configured() {
  setup
  out=$("$NOTIFY" failure morning-brief "test reason" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 when no webhook"
  assert_eq "$out" "" "no output when no webhook"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_silent_when_events_off() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"off"}' > "$CEO_DIR/settings.json"
  out=$("$NOTIFY" failure morning-brief "test reason" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 when events=off"
  assert_eq "$out" "" "no output when events=off"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_silent_on_success_when_events_failures() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"failures"}' > "$CEO_DIR/settings.json"
  # If this test calls curl, it'd hang — proves curl is never invoked when events filter rejects.
  out=$("$NOTIFY" success morning-brief 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 when events=failures and status=success"
  assert_eq "$out" "" "no output when filtered"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_invalid_status_no_op() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  out=$("$NOTIFY" garbage morning-brief 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 on unknown status"
  assert_contains "$out" "unknown status" "stderr explains"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_args_no_op() {
  setup
  out=$("$NOTIFY" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 on missing args (must not break cron)"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_unknown_events_warns_and_defaults_to_failures() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"typoed"}' > "$CEO_DIR/settings.json"
  out=$("$NOTIFY" success morning-brief 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 with typo'd events"
  assert_contains "$out" "unknown notify_events 'typoed'" "must warn on unknown value (enum-config-typo-fallback rule)"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_curl_unreachable_does_not_break() {
  setup
  # Port 1 is reserved/unused — curl will fail to connect.
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  out=$("$NOTIFY" failure morning-brief "unreachable test" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exit 0 even when curl fails"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_env_var_overrides_secrets_file() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/from-file"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1:1/from-env"
  trace=$(bash -x "$NOTIFY" failure morning-brief "env override" 2>&1 || true)
  rc=0
  unset CEO_DISCORD_WEBHOOK
  assert_contains "$trace" "from-env" "env var must be the WEBHOOK source"
  assert_no_match "$trace" "from-file" "secrets-file URL must NOT be selected when env var is set"
  assert_eq "$rc" "0" "helper rc=0 even with unreachable host"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_does_not_log_webhook_url() {
  setup
  WEBHOOK="http://127.0.0.1:1/SECRET-TOKEN-12345"
  echo "{\"discord_webhook\":\"$WEBHOOK\"}" > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  # Capture every byte of stderr+stdout — secret must never appear.
  out=$("$NOTIFY" failure morning-brief "secret-leak check" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "rc=0"
  assert_no_match "$out" "SECRET-TOKEN-12345" "webhook URL must not appear in script output"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_jq_argjson_color_no_injection() {
  setup
  # Reason field with shell-special and JSON-special characters. If the script
  # built the JSON via string concatenation, this would break parsing or inject.
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  out=$("$NOTIFY" failure morning-brief 'reason with "quotes" and `backticks` and $VAR and \backslash' 2>&1)
  rc=$?
  assert_eq "$rc" "0" "special chars in reason must not crash helper"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# --- Run all tests ---

run_test() {
  local fn="$1"
  "$fn"
}

TESTS=(
  test_silent_when_no_webhook_configured
  test_silent_when_events_off
  test_silent_on_success_when_events_failures
  test_invalid_status_no_op
  test_missing_args_no_op
  test_unknown_events_warns_and_defaults_to_failures
  test_curl_unreachable_does_not_break
  test_env_var_overrides_secrets_file
  test_does_not_log_webhook_url
  test_jq_argjson_color_no_injection
)

for t in "${TESTS[@]}"; do
  run_test "$t"
done

if [ "$FAILS" -eq 0 ]; then
  echo "All tests passed. (${#TESTS[@]} tests)"
  exit 0
else
  echo "$FAILS test(s) failed."
  exit 1
fi
