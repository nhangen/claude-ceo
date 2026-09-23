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

# The two shapes observed on ML-1 2026-08-13, verbatim from cron-raw.log. Both
# were classified `terminal`, so no re-auth escalation fired and cronbird retried
# three times per playbook — the exact outcome ff05940's fatal-on-auth signal
# exists to prevent.

test_oauth_expired_envelope_is_auth() {
  # The single-call envelope names auth in `.result` and nowhere else:
  # api_error_status is null, and subtype is the string "success" even though
  # is_error is true. Reading only the status/subtype keys yields terminal.
  local raw='{"is_error":true,"stop_reason":"stop_sequence","total_cost_usd":0,"terminal_reason":"api_error","api_error_status":null,"subtype":"success","result":"Failed to authenticate: OAuth session expired and could not be refreshed","type":"result"}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" \
    "OAuth-expired envelope → auth (auth text lives in .result)"
}

test_oauth_expired_plaintext_is_auth() {
  # Plan/exec phases emit this bare, with no envelope. The pre-fix banner regex
  # matched `authentication_failed|not authenticated|logged out|invalid api key|
  # please run /login` — none of which appear in what Claude Code actually prints.
  local raw='Failed to authenticate: OAuth session expired and could not be refreshed'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" \
    "OAuth-expired plain text → auth"
}

test_envelope_subtype_success_with_error_still_not_ok() {
  # Guard the trap that made the envelope look healthy: subtype "success" beside
  # is_error true must never read as ok, whatever .result says.
  local raw='{"is_error":true,"subtype":"success","api_error_status":null,"result":"something else entirely"}'
  assert_eq "$(_classify_claude_failure 1 "$raw")" "terminal" \
    "is_error true with subtype success → terminal, never ok"
}

test_result_text_does_not_hijack_a_successful_envelope() {
  # A *successful* run whose report happens to discuss authentication must stay
  # ok — the new .result read must not outrank is_error:false.
  local raw='{"is_error":false,"subtype":"success","result":"Reviewed the OAuth session expired handling in ceo-cron-lib.sh"}'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "ok" \
    "is_error false wins over auth-shaped .result text"
}

test_envelope_without_is_error_key_does_not_become_auth() {
  # jq gives "null" for a missing is_error, so a check written as "not false" would
  # accept this and exit 78 on a phase that succeeded. The .result read requires
  # is_error to be literally true for that reason.
  local raw='{"result":"the OAuth session expired handling was refactored"}'
  assert_eq "$(_classify_claude_failure 0 "$raw")" "ok" \
    "an exit-0 envelope with no is_error key must not classify as auth on .result prose"
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

# --- Oversized bodies: the banner match must survive a body past the pipe buffer ---

# A body large enough that the producer is still writing when `grep -q` exits on
# its first match — the only condition under which SIGPIPE fires. The banner sits
# on line 1 so grep short-circuits immediately. ~200KB against a 64KB pipe buffer.
_oversized_body() {
  local banner="$1" pad i=0
  printf '%s\n' "$banner"
  pad=$(printf 'x%.0s' {1..200})
  while [ "$i" -lt 1000 ]; do printf '%s\n' "$pad"; i=$((i + 1)); done
}

test_oversized_ratelimit_body_is_still_transient() {
  local banner='Claude API session limit reached. Please try again later.' raw
  raw=$(_oversized_body "$banner")
  assert_exceeds_sigpipe_threshold "$raw" "the oversized body"
  assert_eq "$(_classify_claude_failure 1 "$raw")" "transient" \
    "rate-limit banner in a 200KB body → transient (fallback stays armed)"
}

test_oversized_auth_body_is_still_auth() {
  local banner='Error: authentication_failed. Please run /login.' raw
  raw=$(_oversized_body "$banner")
  assert_exceeds_sigpipe_threshold "$raw" "the oversized body"
  assert_eq "$(_classify_claude_failure 1 "$raw")" "auth" \
    "auth banner in a 200KB body → auth, not terminal"
}

test_oversized_plaintext_body_emits_no_stderr_noise() {
  # The envelope probes ran `printf … | jq`; when jq bails on non-JSON before
  # draining stdin, the shell writes four "printf: write error: Broken pipe" lines
  # into the cron log. Classification was correct; the log was not.
  #
  # HONEST LIMIT: this test does NOT reliably fail when that fix is reverted. Whether
  # jq exits before printf finishes writing is a scheduling race — observed firing
  # repeatedly in one run of this suite and 0/6 times in a direct probe at the same
  # 200KB. The size guard the two tests above use cannot help here: it proves the pipe
  # would overflow, not that jq bails early. What this pins deterministically is the
  # classification, and after the fix there is no pipe left at all, so clean stderr
  # is structural rather than lucky.
  local raw errfile out
  raw=$(_oversized_body 'some unexpected error we have no pattern for')
  errfile=$(mktemp)
  out=$(_classify_claude_failure 1 "$raw" 2>"$errfile")
  assert_eq "$out" "terminal" "unknown oversized body → terminal (fail-safe)"
  assert_eq "$(cat "$errfile")" "" "no broken-pipe noise leaks to stderr"
  rm -f "$errfile"
}

run_tests
