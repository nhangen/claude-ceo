#!/bin/bash
# test-harness.sh
# Shared test harness for all claude-ceo test suites.

FAILS=0
CURRENT_TEST=""
ASSERTION_COUNT=0

# Each assert_* failure must propagate through TEST_FAILS_TMP because the
# per-test subshell in run_tests discards local FAILS increments. Bumping
# FAILS in-process is kept for the case where assert_* is called outside
# the subshell (e.g. directly from a helper) but the durable signal is the
# tmp file.
_record_assertion_fail() {
  FAILS=$((FAILS + 1))
  [ -n "${TEST_FAILS_TMP:-}" ] && echo 1 >> "$TEST_FAILS_TMP"
}

# fail_test <msg> [detail...] — record a failure from a hand-rolled check, i.e.
# one whose condition no assert_* expresses. Use this instead of printing FAIL and
# bumping FAILS: a test body runs in run_tests' subshell, so an in-process FAILS
# increment is discarded when that subshell exits and the run reports success
# while printing FAIL. It counts as an assertion too, or a test whose only check
# is hand-rolled would be reported as "NO ASSERTIONS RAN" rather than as the
# failure it actually hit.
fail_test() {
  local msg="$1"; shift
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  printf '  FAIL [%s] %s\n' "$CURRENT_TEST" "$msg"
  local detail
  for detail in "$@"; do
    printf '    %s\n' "$detail"
  done
  _record_assertion_fail
}

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    _record_assertion_fail
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [[ ! -f "$path" ]]; then
    printf '  FAIL [%s] %s\n    expected file: %q\n' "$CURRENT_TEST" "$msg" "$path"
    _record_assertion_fail
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    _record_assertion_fail
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    forbidden: %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    _record_assertion_fail
  fi
}

# Alias for backwards compatibility
assert_no_match() {
  assert_not_contains "$@"
}

assert_fails() {
  local msg="$1"; shift
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL [%s] %s (expected non-zero exit)\n' "$CURRENT_TEST" "$msg"
    _record_assertion_fail
  fi
}

# _record_hand_rolled_fails <fails_at_test_start> — called at the end of a test
# body, inside run_tests' subshell, to carry out any FAILS increments the body made
# directly rather than through an assert_* helper.
#
# Already-durable failures are subtracted rather than assumed absent:
# _record_assertion_fail bumps FAILS *and* appends a line, so counting the whole
# delta would report every assert_* failure twice.
#
# The subtraction is exact, because TEST_FAILS_TMP holds this body's lines and
# nothing else: run_tests truncates it before the subshell and leaves it unset while
# `setup` and `teardown` run (#317). It was not exact before — those two scopes
# appended to the same file, so a failure from either was read as one the body had
# already recorded.
#
# One case is still outside it. A bare increment in a *nested* subshell or a command
# substitution never reaches the body's FAILS, so the delta cannot see it and it is
# lost. fail_test works there; no site in these suites is in that shape, and
# test-harness.test.sh pins both halves.
_record_hand_rolled_fails() {
  local fails_before="$1" recorded=0
  [ -f "${TEST_FAILS_TMP:-}" ] && recorded=$(wc -l < "$TEST_FAILS_TMP")
  local hand_rolled=$(( (FAILS - fails_before) - recorded ))
  while [ "$hand_rolled" -gt 0 ]; do
    echo 1 >> "$TEST_FAILS_TMP"
    hand_rolled=$((hand_rolled - 1))
  done
}

_record_test_abort() {
  local test_name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    printf '  FAIL [%s] test body aborted or exited with non-zero code (%d)\n' "$test_name" "$rc"
    echo 1 >> "$TEST_FAILS_TMP"
  fi
}

run_tests() {
  local count=0
  local body_fails assertions_file
  body_fails=$(mktemp)
  assertions_file="${body_fails}.assertions"
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if [ -n "${TEST_FILTER:-}" ] && [[ "$fn" != *"$TEST_FILTER"* ]]; then
      continue
    fi
    CURRENT_TEST="$fn"

    # TEST_FAILS_TMP is the subshell's channel and nothing else's. `setup` and
    # `teardown` run right here in this shell, so _record_assertion_fail's in-process
    # FAILS bump is already durable for them — leaving the file set as well made each
    # of their failures land twice, once as the bump and once when the caller folded
    # the file in. A setup failure was reported as two, and two as four (#317).
    unset TEST_FAILS_TMP

    if type setup >/dev/null 2>&1; then
      setup
    fi

    local assertions_before=$ASSERTION_COUNT
    local fails_before=$FAILS

    # FAILS is compared inside the subshell, not outside it: a test body that
    # bumps FAILS directly — 126 hand-rolled checks across these suites do — has
    # its increment discarded when the subshell exits, so the run printed FAIL and
    # then "All tests passed", exit 0 (#310). The comparison has to happen where
    # the increment is still visible, and its result travels out through
    # TEST_FAILS_TMP like every other durable failure. Gating it here means the 126
    # existing sites are covered without being edited.
    #
    # It covers the body's own scope, not everything beneath it: a bare increment
    # inside a nested subshell or a command substitution is measured nowhere and is
    # still lost (#317). fail_test survives there; no current site is in that shape.
    TEST_FAILS_TMP="$body_fails"
    export TEST_FAILS_TMP
    true > "$TEST_FAILS_TMP"

    (
      trap 'rc=$?; [ $rc -ne 0 ] && _record_test_abort "$CURRENT_TEST" $rc' EXIT
      "$fn"
      _record_hand_rolled_fails "$fails_before"
      echo "$ASSERTION_COUNT" > "$assertions_file"
    )

    if [ -s "$TEST_FAILS_TMP" ]; then
      FAILS=$((FAILS + $(wc -l < "$TEST_FAILS_TMP")))
      true > "$TEST_FAILS_TMP"
    fi

    unset TEST_FAILS_TMP

    if [ -f "$assertions_file" ]; then
      ASSERTION_COUNT=$(cat "$assertions_file")
      rm -f "$assertions_file"
    fi

    if [ "$ASSERTION_COUNT" -eq "$assertions_before" ]; then
      printf '  FAIL [%s] NO ASSERTIONS RAN (test body exited early or had no assertions)\n' "$CURRENT_TEST"
      FAILS=$((FAILS + 1))
    fi
    
    if type teardown >/dev/null 2>&1; then
      teardown
    fi
    count=$((count + 1))
  done
  rm -f "$body_fails" "$assertions_file"

  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}
