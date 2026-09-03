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
# Inside a parent-shell scope (`setup`/`teardown`) the file is the only channel used,
# and the in-process bump is deliberately suppressed. Using both there is what made a
# setup failure count twice (#317), and reading the two against each other could not
# tell a bare parent-depth increment from a nested recorded failure — they cancel, and
# two genuine failures reported as one. One channel per scope removes the ambiguity
# instead of estimating around it. Exported, so a nested subshell inherits it.
_record_assertion_fail() {
  if [ "${HARNESS_PARENT_SCOPE:-0}" = 1 ] && [ -n "${TEST_FAILS_TMP:-}" ]; then
    echo 1 >> "$TEST_FAILS_TMP"
    return 0
  fi
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
# The lines are this body's and nothing else's — run_tests truncates the file before
# the subshell, and `setup`/`teardown` write their own (#317). Before that they shared
# this one, so a failure from either was read as one the body had already recorded.
#
# The subtraction still is not exact, in both directions, and both come from the same
# cause: a nested subshell or command substitution's FAILS bump never reaches the
# body's, so the delta and the file disagree about what happened down there.
#
#   - A bare increment nested: no line, no delta. Lost outright.
#   - An assert_* or fail_test failure nested: a line with no matching delta, so
#     `recorded` outruns the delta and this sweep absorbs a real main-scope increment
#     instead. Two genuine failures report as one.
#
# The second is the worse of the two and is the case an earlier version of this
# comment claimed had been fixed. It has not been. `while [ "$hand_rolled" -gt 0 ]`
# floors the negative at zero, which is what makes the absorption silent.
#
# So fail_test always reports its own failure at either depth, but in *this* scope it
# cannot repair a bare main-scope increment sitting beside it — that is the absorption
# above. The parent scopes have no such caveat: there the file is the only channel
# (see _record_assertion_fail), so nothing cancels. No site in these suites is in
# either shape, and test-harness.test.sh pins the bare-increment half only.
_record_hand_rolled_fails() {
  local fails_before="$1" recorded=0
  [ -f "${TEST_FAILS_TMP:-}" ] && recorded=$(wc -l < "$TEST_FAILS_TMP")
  local hand_rolled=$(( (FAILS - fails_before) - recorded ))
  while [ "$hand_rolled" -gt 0 ]; do
    echo 1 >> "$TEST_FAILS_TMP"
    hand_rolled=$((hand_rolled - 1))
  done
}

# _fold_parent_scope <file> — fold a parent-shell scope's recorded failures (setup,
# teardown) into FAILS. Every line is added, with no arithmetic against FAILS, because
# HARNESS_PARENT_SCOPE suppressed the in-process bump for exactly these lines — so the
# file is the whole record and cannot double-count. It works at any depth: a nested
# subshell inherits the exported flag and appends to the same file.
#
# A bare `FAILS=$((FAILS + 1))` at parent depth is untouched by all of this and stays
# durable on its own, since setup/teardown run in this shell. One nested a level down
# is still lost — no line, no bump — the same residual hole the body scope has.
#
# Two earlier cuts of #317 got this wrong and both failed quietly, which is why this
# one carries no estimate. Unsetting the file removed the channel entirely: a nested
# failure reached neither, so the run printed FAIL and exited 0. Folding
# `lines - (FAILS - before)` then read the two channels against each other and could
# not tell a bare parent increment from a nested recorded failure — they cancelled, and
# two genuine failures reported as one where main reported two.
_fold_parent_scope() {
  local file="$1"
  [ -f "$file" ] || return 0
  if [ -s "$file" ]; then
    FAILS=$((FAILS + $(wc -l < "$file")))
  fi
  true > "$file"
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
  local body_fails_tmp assertions_tmp parent_fails_tmp
  body_fails_tmp=$(mktemp)
  parent_fails_tmp=$(mktemp)
  assertions_tmp="${body_fails_tmp}.assertions"
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if [ -n "${TEST_FILTER:-}" ] && [[ "$fn" != *"$TEST_FILTER"* ]]; then
      continue
    fi
    CURRENT_TEST="$fn"

    # Each scope gets its own file, and inside a parent scope the file is the only
    # channel — HARNESS_PARENT_SCOPE suppresses the in-process bump. Sharing the body's
    # file *and* keeping the bump is what made each setup failure land twice, once as
    # each: a setup failure was reported as two, and two as four (#317). One channel
    # per scope means a failure below these scopes is still recorded, without the
    # caller having to guess which channel carried it.
    if type setup >/dev/null 2>&1; then
      TEST_FAILS_TMP="$parent_fails_tmp"
      HARNESS_PARENT_SCOPE=1
      export TEST_FAILS_TMP HARNESS_PARENT_SCOPE
      true > "$TEST_FAILS_TMP"
      setup
      HARNESS_PARENT_SCOPE=0
      _fold_parent_scope "$parent_fails_tmp"
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
    TEST_FAILS_TMP="$body_fails_tmp"
    export TEST_FAILS_TMP
    true > "$TEST_FAILS_TMP"

    # Backgrounded, then reaped with an explicit `wait … || true`, rather than
    # `( … ) || true` directly: bash suppresses errexit for the *left operand of
    # `||` itself*, and that suppression reaches inside the subshell — an inner
    # `false` there would fall through instead of tripping the EXIT trap, which
    # silently disarms every hand-rolled `set -e`-reliant body (#349). A
    # backgrounded subshell keeps its own inherited errexit live; only the
    # outer `wait`'s exit status (which mirrors the job's) needs shielding from
    # run_tests' own `set -e`, and `|| true` on `wait` does exactly that without
    # touching the subshell's semantics.
    #
    # The sweep and the assertion-count write live in the trap itself, not as
    # statements after "$fn" — statements after "$fn" never run when the body
    # aborts via `exit N`, so a bare `FAILS=$((FAILS + 1))` before the abort was
    # discarded and a real assertion that ran was reported as
    # "NO ASSERTIONS RAN" (#322). The trap fires on every exit path, abort or
    # clean, so both run either way. `rc` is captured before either call so
    # their own exit statuses (a `wc -l` of an empty count, echo's own status)
    # can't overwrite the code the abort check needs.
    #
    # The trailing `exit $rc` is trap hygiene, not a guard, and no arm pins it:
    # `wait "$!" || true` discards the subshell's status, and an abort travels
    # to the loop as a line in $TEST_FAILS_TMP rather than as an exit code, so
    # removing it changes nothing observable. It stays because a status that
    # says what happened is worth more than one that is always 1 on a pass, but
    # do not read it as protected.
    (
      trap '
        rc=$?
        _record_hand_rolled_fails "$fails_before"
        echo "$ASSERTION_COUNT" > "$assertions_tmp"
        [ $rc -ne 0 ] && _record_test_abort "$CURRENT_TEST" $rc
        exit $rc
      ' EXIT
      "$fn"
    ) &
    wait "$!" || true

    if [ -s "$TEST_FAILS_TMP" ]; then
      FAILS=$((FAILS + $(wc -l < "$TEST_FAILS_TMP")))
      true > "$TEST_FAILS_TMP"
    fi

    unset TEST_FAILS_TMP

    if [ -f "$assertions_tmp" ]; then
      ASSERTION_COUNT=$(cat "$assertions_tmp")
      rm -f "$assertions_tmp"
    fi

    if [ "$ASSERTION_COUNT" -eq "$assertions_before" ]; then
      printf '  FAIL [%s] NO ASSERTIONS RAN (test body exited early or had no assertions)\n' "$CURRENT_TEST"
      FAILS=$((FAILS + 1))
    fi
    
    if type teardown >/dev/null 2>&1; then
      TEST_FAILS_TMP="$parent_fails_tmp"
      HARNESS_PARENT_SCOPE=1
      export TEST_FAILS_TMP HARNESS_PARENT_SCOPE
      true > "$TEST_FAILS_TMP"
      teardown
      HARNESS_PARENT_SCOPE=0
      _fold_parent_scope "$parent_fails_tmp"
      unset TEST_FAILS_TMP
    fi
    count=$((count + 1))
  done
  rm -f "$body_fails_tmp" "$assertions_tmp" "$parent_fails_tmp"

  if [ "$count" -eq 0 ]; then
    echo "FAILED: no tests discovered"
    exit 1
  fi

  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}
