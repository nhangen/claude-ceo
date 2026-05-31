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

_record_test_abort() {
  local test_name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    printf '  FAIL [%s] test body aborted or exited with non-zero code (%d)\n' "$test_name" "$rc"
    echo 1 >> "$TEST_FAILS_TMP"
  fi
}

run_tests() {
  local count=0
  export TEST_FAILS_TMP
  TEST_FAILS_TMP=$(mktemp)
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if [ -n "${TEST_FILTER:-}" ] && [[ "$fn" != *"$TEST_FILTER"* ]]; then
      continue
    fi
    CURRENT_TEST="$fn"
    
    if type setup >/dev/null 2>&1; then
      setup
    fi
    
    local assertions_before=$ASSERTION_COUNT
    
    (
      trap 'rc=$?; [ $rc -ne 0 ] && _record_test_abort "$CURRENT_TEST" $rc' EXIT
      "$fn"
      echo "$ASSERTION_COUNT" > "${TEST_FAILS_TMP}.assertions"
    )
    
    if [ -s "$TEST_FAILS_TMP" ]; then
      FAILS=$((FAILS + $(wc -l < "$TEST_FAILS_TMP")))
      true > "$TEST_FAILS_TMP"
    fi
    
    if [ -f "${TEST_FAILS_TMP}.assertions" ]; then
      ASSERTION_COUNT=$(cat "${TEST_FAILS_TMP}.assertions")
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
  rm -f "$TEST_FAILS_TMP" "${TEST_FAILS_TMP}.assertions"
  
  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}
