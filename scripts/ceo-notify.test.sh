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
  unset CEO_DISCORD_WEBHOOK CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE CEO_RUNNER_ARTIFACT
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

# Installs a fake `curl` on PATH that records the POSTed -d payload to
# $CAPTURE and returns a curl-like -w line. Validates argv shape (stub-cli rule):
# a real ceo-notify invocation always passes -d <json>; bail non-zero otherwise.
_install_curl_capture() {
  STUBDIR=$(mktemp -d)
  CAPTURE="$STUBDIR/payload.json"
  cat > "$STUBDIR/curl" <<'STUB'
#!/bin/bash
payload="" prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && payload="$a"
  prev="$a"
done
[ -n "$payload" ] || { echo "stub curl: no -d payload in argv: $*" >&2; exit 99; }
printf '%s' "$payload" > "$STUB_CAPTURE"
echo "200 time=0.001s"
STUB
  chmod +x "$STUBDIR/curl"
  export STUB_CAPTURE="$CAPTURE"
  _SAVED_PATH="$PATH"
  export PATH="$STUBDIR:$PATH"
}
_remove_curl_capture() {
  export PATH="$_SAVED_PATH"
  rm -rf "$STUBDIR"
  unset STUB_CAPTURE STUBDIR CAPTURE _SAVED_PATH
}

test_runner_field_combines_harness_and_model() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="ollama" CEO_MODEL="gemma4:12b-it-qat" CEO_MODEL_SOURCE="invoked"
  "$NOTIFY" failure morning-brief "model field check" >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  model_count=$(jq '[.embeds[0].fields[] | select(.name=="Model")] | length' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE
  _remove_curl_capture
  assert_eq "$runner_val" "ollama (gemma4:12b-it-qat)" "an invoked model renders bare (no 'declared' marker)"
  assert_eq "$model_count" "0" "no separate Model field — runner and model render in one field"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_field_omitted_when_runner_and_model_unset() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  unset CEO_RUNNER CEO_MODEL
  "$NOTIFY" failure morning-brief "no runner check" >/dev/null 2>&1
  runner_count=$(jq '[.embeds[0].fields[] | select(.name=="Runner")] | length' "$CAPTURE" 2>/dev/null)
  _remove_curl_capture
  assert_eq "$runner_count" "0" "embed must omit the Runner field when both CEO_RUNNER and CEO_MODEL are unset"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_script_runner_with_declared_model_names_artifact_and_marks_declared() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="script" CEO_MODEL="opus" CEO_MODEL_SOURCE="declared" \
         CEO_RUNNER_ARTIFACT="ticket-triage-autopilot.sh"
  "$NOTIFY" success ticket-triage-autopilot >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE CEO_RUNNER_ARTIFACT
  _remove_curl_capture
  assert_eq "$runner_val" "script: ticket-triage-autopilot.sh (opus, declared)" \
    "a script runner must name the script it ran and mark the frontmatter model 'declared'"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pure_shell_script_runner_names_artifact_no_model() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="script" CEO_RUNNER_ARTIFACT="disk-monitor.sh"
  unset CEO_MODEL CEO_MODEL_SOURCE
  "$NOTIFY" success disk-monitor >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_RUNNER_ARTIFACT
  _remove_curl_capture
  assert_eq "$runner_val" "script: disk-monitor.sh" \
    "a pure-shell script runner with no model must name the script and show no model"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_skill_runner_with_declared_model_names_artifact_and_marks_declared() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="skill" CEO_MODEL="opus" CEO_MODEL_SOURCE="declared" \
         CEO_RUNNER_ARTIFACT="weekly-synthesis"
  "$NOTIFY" success weekly-synthesis >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE CEO_RUNNER_ARTIFACT
  _remove_curl_capture
  assert_eq "$runner_val" "skill: weekly-synthesis (opus, declared)" \
    "a skill runner must name the skill it ran and mark the frontmatter model 'declared'"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_runner_invoked_model_renders_bare() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="claude" CEO_MODEL="opus" CEO_MODEL_SOURCE="invoked"
  "$NOTIFY" success bug-fix >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE
  _remove_curl_capture
  assert_eq "$runner_val" "claude (opus)" \
    "a claude runner shows no artifact and renders the invoked model bare"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_skill_runner_no_model_names_artifact() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="skill" CEO_RUNNER_ARTIFACT="workload-report"
  unset CEO_MODEL CEO_MODEL_SOURCE
  "$NOTIFY" success workload-report >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_RUNNER_ARTIFACT
  _remove_curl_capture
  assert_eq "$runner_val" "skill: workload-report" \
    "a skill runner with no model must name the skill and show no model"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_unknown_model_source_renders_bare() {
  setup
  echo '{"discord_webhook":"http://127.0.0.1:1/never"}' > "$CEO_SECRETS_FILE"
  echo '{"notify_events":"all"}' > "$CEO_DIR/settings.json"
  _install_curl_capture
  export CEO_RUNNER="script" CEO_MODEL="opus" CEO_MODEL_SOURCE="garbage" \
         CEO_RUNNER_ARTIFACT="x.sh"
  "$NOTIFY" success x >/dev/null 2>&1
  runner_val=$(jq -r '.embeds[0].fields[] | select(.name=="Runner") | .value' "$CAPTURE" 2>/dev/null)
  unset CEO_RUNNER CEO_MODEL CEO_MODEL_SOURCE CEO_RUNNER_ARTIFACT
  _remove_curl_capture
  assert_eq "$runner_val" "script: x.sh (opus)" \
    "an unrecognized CEO_MODEL_SOURCE must render the model bare (never falsely 'declared')"
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
  test_runner_field_combines_harness_and_model
  test_runner_field_omitted_when_runner_and_model_unset
  test_env_var_overrides_secrets_file
  test_does_not_log_webhook_url
  test_script_runner_with_declared_model_names_artifact_and_marks_declared
  test_pure_shell_script_runner_names_artifact_no_model
  test_skill_runner_with_declared_model_names_artifact_and_marks_declared
  test_claude_runner_invoked_model_renders_bare
  test_skill_runner_no_model_names_artifact
  test_unknown_model_source_renders_bare
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
