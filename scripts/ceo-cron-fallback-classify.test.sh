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

# The fixture is load-bearing: below the pipe buffer the pre-fix form works fine
# and the test would pass against broken code. Assert the old
# `printf … | grep -q` really does report failure on this exact body — AND that it
# succeeds on a small body carrying the same banner. Both halves are needed: a bare
# "non-zero" check is also satisfied by grep's rc=1 no-match, which would let a
# banner that stopped matching masquerade as a working canary. The pair proves the
# failure is size-dependent, i.e. SIGPIPE.
#
# Deliberately NOT asserting rc==141: the signature is platform-dependent. BSD grep
# and GNU grep on WSL give 141; GNU grep on GitHub's ubuntu runner gives 2 ("write
# error: Broken pipe"). Pinning 141 cost a CI cycle in #294.
_pipe_form_rc() {
  local raw="$1" pattern="$2" rc=0
  ( set -o pipefail; printf '%s' "$raw" | grep -qEi "$pattern" ) || rc=$?
  echo "$rc"
}

_assert_pipe_form_breaks() {
  local raw="$1" pattern="$2" banner="$3" big_rc small_rc
  big_rc=$(_pipe_form_rc "$raw" "$pattern")
  small_rc=$(_pipe_form_rc "$banner" "$pattern")
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$big_rc" -eq 0 ]; then
    printf '  FAIL [%s] fixture no longer breaks the pre-fix `printf | grep -q` form (rc=0), so it proves nothing — it must exceed the pipe buffer\n' "$CURRENT_TEST"
    _record_assertion_fail
  elif [ "$small_rc" -ne 0 ]; then
    printf '  FAIL [%s] canary is passing for the wrong reason: the pre-fix form also fails on a SMALL body (rc=%s), so the pattern simply is not matching — not SIGPIPE\n' "$CURRENT_TEST" "$small_rc"
    _record_assertion_fail
  fi
}

test_oversized_ratelimit_body_is_still_transient() {
  local banner='Claude API session limit reached. Please try again later.' raw
  raw=$(_oversized_body "$banner")
  _assert_pipe_form_breaks "$raw" 'session limit' "$banner"
  assert_eq "$(_classify_claude_failure 1 "$raw")" "transient" \
    "rate-limit banner in a 200KB body → transient (fallback stays armed)"
}

test_oversized_auth_body_is_still_auth() {
  local banner='Error: authentication_failed. Please run /login.' raw
  raw=$(_oversized_body "$banner")
  _assert_pipe_form_breaks "$raw" 'authentication_failed' "$banner"
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
  # 200KB. So there is no canary here, unlike the two tests above. What it does pin
  # deterministically is the classification, and after the fix there is no pipe left
  # at all, so clean stderr is structural rather than lucky.
  local raw errfile out
  raw=$(_oversized_body 'some unexpected error we have no pattern for')
  errfile=$(mktemp)
  out=$(_classify_claude_failure 1 "$raw" 2>"$errfile")
  assert_eq "$out" "terminal" "unknown oversized body → terminal (fail-safe)"
  assert_eq "$(cat "$errfile")" "" "no broken-pipe noise leaks to stderr"
  rm -f "$errfile"
}

run_tests
