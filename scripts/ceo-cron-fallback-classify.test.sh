#!/usr/bin/env bash
# Unit tests for _classify_claude_failure (ceo-cron-lib.sh).
# Pure function: given (exit_code, raw_stdout) it prints one of
# transient|auth|terminal|ok. No CLI, no I/O — crafted envelopes only.
#
# Each test must fail if the classifier is reverted to the old stdout
# substring grep (`session limit|hit your limit`).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ceo-cron-lib.sh"

# --- Primary signal: the --output-format json envelope (single-call path) ---

test_transient_5xx_envelope_no_ratelimit_text() {
  # 503, is_error true, and NO "session limit" text — the old grep classified
  # this as ok (no match) and never fell back. New code reads api_error_status.
  local raw='{"type":"result","is_error":true,"subtype":"error_during_execution","api_error_status":503}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "transient" "503 envelope → transient"
}

test_transient_429_envelope() {
  local raw='{"is_error":true,"api_error_status":429}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "transient" "429 → transient"
}

test_auth_401_envelope() {
  local raw='{"is_error":true,"subtype":"error","api_error_status":401}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" "401 → auth"
}

test_auth_403_envelope() {
  local raw='{"is_error":true,"api_error_status":403}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" "403 → auth"
}

test_other_4xx_envelope_is_terminal() {
  local raw='{"is_error":true,"api_error_status":400}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "terminal" "400 → terminal"
}

test_success_envelope_is_ok() {
  local raw='{"type":"result","is_error":false,"subtype":"success","stop_reason":"end_turn","result":"done"}'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "ok" "success envelope → ok"
}

test_truncated_output_exit0_is_not_ok() {
  # is_error false but stop_reason max_tokens → degraded, must not pass as ok.
  local raw='{"is_error":false,"subtype":"success","stop_reason":"max_tokens","result":"partial"}'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "terminal" "truncated (max_tokens) → terminal, not ok"
}

test_success_result_mentions_session_limit_is_still_ok() {
  # The self-referential false positive the old grep had: the model's OUTPUT
  # discusses "session limit" but the run succeeded. Must be ok, not transient.
  local raw='{"is_error":false,"subtype":"success","stop_reason":"end_turn","result":"The session limit banner means you hit your limit."}'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "ok" "success mentioning 'session limit' → ok"
}

# --- Fallback tier: non-JSON banners (plan/exec plain-text phases) ---

test_ratelimit_banner_non_json_is_transient() {
  # Regression guard: the one case the old code got right must still work.
  local raw='Claude API session limit reached. Please try again later.'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "transient" "rate-limit banner → transient"
}

test_auth_banner_non_json_is_auth() {
  local raw='Error: authentication_failed. Please run /login.'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" "auth banner → auth"
}

test_plaintext_plan_success_is_ok() {
  # Plan/exec phases emit plain text (no --output-format json); exit 0 = success.
  local raw='ACTION: 1 | read | check inbox | n/a'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "ok" "plain-text plan success → ok"
}

# --- Fail-safe: unknown failures default to terminal, never fall open ---

test_unknown_nonzero_exit_defaults_terminal() {
  local raw='some unexpected error we have no pattern for'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "terminal" "unknown failure → terminal (fail-safe)"
}

test_badflag_empty_stdout_is_terminal() {
  # Bad flag: exit 1, stderr carries the message, stdout empty.
  assert_eq "$(_classify_claude_failure 1 "")" "terminal" "empty stdout + non-zero → terminal"
}

run_tests
