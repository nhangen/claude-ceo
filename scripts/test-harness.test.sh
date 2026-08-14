#!/bin/bash
# Tests for scripts/test-harness.sh — the harness every other suite runs on.
#
# Each case writes a small suite to a temp file, runs it as a child process, and
# asserts on that child's exit code and output. It has to be a child: the property
# under test is what run_tests does across its per-test subshell boundary, and
# calling run_tests from inside a run_tests test body would nest the very boundary
# being measured.
#
# The property: a failure recorded inside a test body must reach the run's exit
# code. It did not for hand-rolled checks — a test body runs in a subshell, so
# `FAILS=$((FAILS + 1))` there was discarded on exit and the run printed FAIL and
# then "All tests passed", exit 0 (#310). 73 test bodies were masked that way.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/test-harness.sh"

# shellcheck source=scripts/test-harness.sh
source "$HARNESS"

TMP=""
setup() { TMP=$(mktemp -d); }
teardown() { [ -n "$TMP" ] && rm -rf "$TMP"; }

# Runs a child suite; sets CHILD_OUT and CHILD_RC.
_run_child() {
  local body="$1"
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "source '$HARNESS'"
    echo "$body"
    echo 'run_tests'
  } > "$TMP/child.sh"
  CHILD_OUT=$(bash "$TMP/child.sh" 2>&1)
  CHILD_RC=$?
}

test_fail_test_reaches_the_exit_code() {
  _run_child '
test_x() {
  assert_eq a a "a passing assertion, so the no-assertions guard stays quiet"
  fail_test "hand-rolled check failed"
}'
  assert_eq "$CHILD_RC" "1" "a fail_test failure fails the run"
  assert_contains "$CHILD_OUT" "FAILED: 1" "the run reports the failure count"
  assert_not_contains "$CHILD_OUT" "All tests passed" \
    "the run must not also claim success"
}

# A bare increment one level deeper than the test body — a nested subshell, or a
# helper called in a command substitution — is still lost. The delta is measured in
# the body's scope, so nothing below it is visible. No current site is in that shape
# (all 140 checked), and fail_test does survive there, which is what makes it the
# recommendation rather than a bare increment. Pinning both halves so that is a tested
# claim rather than a comment: #317.
test_fail_test_survives_a_nested_subshell() {
  _run_child '
test_x() {
  assert_eq a a "a passing assertion, so the no-assertions guard stays quiet"
  ( fail_test "failed inside a nested subshell" )
}'
  assert_eq "$CHILD_RC" "1" "fail_test reaches the exit code from a nested subshell"
  assert_contains "$CHILD_OUT" "FAILED: 1" "counted once"
}

# --- Scope attribution (#317) ---
#
# `setup` and `teardown` run in the caller's shell, not in the per-test subshell, so
# _record_assertion_fail's in-process FAILS bump is already durable there. It also
# appended a line to the shared failure file, and the caller folded that file into
# FAILS — counting the same failure twice. Each scope's record is now kept in exactly
# one place: the subshell body reports through its own file, the parent-shell scopes
# through FAILS directly.
#
# The counts below were measured against the pre-fix harness, not derived from the
# ticket. #317 described this as skewing low and never inventing a failure; that is
# wrong in the setup case, which invents one per failure. Three of the surrounding
# cases pass on the broken harness because the double-count cancels a separately
# lost increment, so any test here has to name the number it expects and why.

test_one_setup_failure_is_counted_once() {
  _run_child '
setup() { fail_test "the setup failure"; }
test_x() { assert_eq a a "the body itself passes"; }'
  # Pre-fix: FAILED: 2. One failure, counted by the in-process bump and again when
  # the caller folded setup's line out of the shared file.
  assert_contains "$CHILD_OUT" "FAILED: 1" "one setup failure is one failure"
  assert_not_contains "$CHILD_OUT" "FAILED: 2" "not doubled"
  assert_eq "$CHILD_RC" "1" "and the run still fails"
}

test_setup_failures_are_not_doubled_at_scale() {
  _run_child '
setup() { fail_test "s1"; fail_test "s2"; }
test_x() { assert_eq a a "the body itself passes"; }'
  # Pre-fix: FAILED: 4. Proves the ×2 relationship rather than a one-off off-by-one,
  # which a single-failure case alone cannot distinguish.
  assert_contains "$CHILD_OUT" "FAILED: 2" "two setup failures are two, not four"
}

test_a_setup_assert_failure_is_also_counted_once() {
  _run_child '
setup() { assert_eq got want "setup assertion"; }
test_x() { assert_eq a a "the body itself passes"; }'
  # Same defect through assert_* rather than fail_test — both route to
  # _record_assertion_fail, so a fix that only touched fail_test would miss this.
  assert_contains "$CHILD_OUT" "FAILED: 1" "a setup assert failure counts once"
  assert_contains "$CHILD_OUT" "setup assertion" "and its message is printed"
}

test_a_setup_failure_and_a_body_increment_are_both_counted() {
  _run_child '
setup() { fail_test "the setup failure"; }
test_x() {
  assert_eq a a "a passing assertion, so the no-assertions guard stays quiet"
  FAILS=$((FAILS + 1))
}'
  # Pre-fix this already reported 2 — the right number for the wrong reason: setup's
  # line was double-counted while it simultaneously absorbed the body's increment via
  # the sweep's subtraction. Kept so the fix cannot restore the balance by
  # reintroducing either half.
  assert_contains "$CHILD_OUT" "FAILED: 2" \
    "a setup failure plus a body increment is two, each counted once"
}

test_a_teardown_failure_is_counted_once_on_the_last_test() {
  _run_child '
teardown() { fail_test "the teardown failure"; }
test_x() { assert_eq a a "the body itself passes"; }'
  # Pre-fix this was correct by accident: teardown ran after the caller truncated,
  # and the loop deleted the file before folding it, so only the in-process bump
  # survived. Now it is correct by construction.
  assert_eq "$CHILD_RC" "1" "a failure recorded in teardown fails the run"
  assert_contains "$CHILD_OUT" "FAILED: 1" "counted once"
  assert_not_contains "$CHILD_OUT" "All tests passed" "never reported as success"
}

test_a_teardown_failure_does_not_absorb_the_next_tests_increment() {
  _run_child '
teardown() { fail_test "teardown failure"; }
test_a() { assert_eq a a "passes"; }
test_b() {
  assert_eq a a "passes"
  FAILS=$((FAILS + 1))
}'
  # Two teardown failures plus test_b's bare increment. Pre-fix also 3, again by
  # cancellation: teardown_a's leftover line was re-folded as a second failure while
  # absorbing test_b's increment.
  assert_contains "$CHILD_OUT" "FAILED: 3" \
    "two teardown failures plus one body increment, each counted once"
}

# The parent scopes get a file of their own rather than no file. An earlier cut of
# this fix just unset TEST_FAILS_TMP while setup/teardown ran, on the reasoning that
# their in-process FAILS bump is already durable. True at that shell's depth, false
# one level down — and unsetting removed the file channel that was carrying it, so a
# failure below the parent scope reached neither. `main` reported it; that cut printed
# FAIL and exited 0. Same shape as #310, in a scope the fix hadn't considered.

test_a_setup_failure_below_the_parent_shell_still_fails_the_run() {
  _run_child '
setup() { ( fail_test "a setup failure one level down" ); }
test_x() { assert_eq a a "the body itself passes"; }'
  assert_eq "$CHILD_RC" "1" "a setup failure below the parent shell must fail the run"
  assert_contains "$CHILD_OUT" "FAILED: 1" "and is counted exactly once"
  assert_not_contains "$CHILD_OUT" "All tests passed" "never reported as success"
}

test_a_teardown_failure_below_the_parent_shell_still_fails_the_run() {
  _run_child '
teardown() { x=$(fail_test "a teardown failure one level down"); }
test_x() { assert_eq a a "the body itself passes"; }'
  # This half was never a regression — `main` loses it too — so it is a fix, not a
  # restoration. Pinned alongside its sibling because the harness comments name both
  # scopes and a reader has no way to tell which one was ever covered.
  assert_eq "$CHILD_RC" "1" "a teardown failure below the parent shell must fail the run"
  assert_contains "$CHILD_OUT" "FAILED: 1" "and is counted exactly once"
}

test_a_parent_scope_failure_at_both_depths_is_counted_once_each() {
  _run_child '
setup() { fail_test "at parent depth"; ( fail_test "one level down" ); }
test_x() { assert_eq a a "the body itself passes"; }'
  # The two channels must not overlap: the parent-depth failure is carried by its
  # in-process bump and the nested one by its file line. Counting the file wholesale
  # would double the first; ignoring it would drop the second.
  assert_contains "$CHILD_OUT" "FAILED: 2" \
    "one failure at parent depth plus one below it is two, not one and not three"
}

test_a_bare_parent_increment_beside_a_nested_failure_counts_both() {
  _run_child '
setup() { FAILS=$((FAILS + 1)); ( fail_test "one level down" ); }
test_x() { assert_eq a a "the body itself passes"; }'
  # The second cut of this fix folded `lines - (FAILS - before)`, reading the two
  # channels against each other. A bare parent-depth increment (delta, no line) and a
  # nested recorded failure (line, no delta) cancelled exactly, so this reported 1 —
  # under-counting where even `main` reported 2. Suppressing the in-process bump inside
  # a parent scope makes the file the whole record and removes the ambiguity, but the
  # arithmetic version looked right, so it gets a trip-wire.
  assert_contains "$CHILD_OUT" "FAILED: 2" \
    "a bare parent-depth increment and a nested recorded failure are two failures"
}

test_a_bare_increment_in_a_nested_subshell_is_known_to_be_lost() {
  _run_child '
test_x() {
  assert_eq a a "a passing assertion, so the no-assertions guard stays quiet"
  ( FAILS=$((FAILS + 1)) )
}'
  # Asserting the limitation, not endorsing it. If a later change makes this work,
  # this test fails and should be deleted along with the caveat it documents — that
  # is the intended way to find out the gap closed.
  assert_eq "$CHILD_RC" "0" \
    "documents the known gap: a bare increment below the body's scope is invisible (#317)"
}

# The #310 regression itself, in the shape the 126 existing sites are written in:
# a bare FAILS increment, no helper. This is why the propagation is gated in
# run_tests rather than left to callers adopting fail_test — a suite cannot opt out
# of it, including the suites nobody edited.
test_a_bare_fails_increment_reaches_the_exit_code() {
  _run_child '
test_x() {
  assert_eq a a "a passing assertion, so the no-assertions guard stays quiet"
  printf "  FAIL [%s] hand-rolled check failed\n" "$CURRENT_TEST"
  FAILS=$((FAILS + 1))
}'
  assert_eq "$CHILD_RC" "1" "a bare FAILS increment inside a test body fails the run"
  assert_contains "$CHILD_OUT" "FAILED: 1" "and is counted once"
  assert_not_contains "$CHILD_OUT" "All tests passed" "not reported as success"
}

test_several_bare_increments_in_one_body_are_all_counted() {
  _run_child '
test_x() {
  assert_eq a a "keeps the no-assertions guard quiet"
  FAILS=$((FAILS + 1))
  FAILS=$((FAILS + 1))
  FAILS=$((FAILS + 1))
}'
  assert_contains "$CHILD_OUT" "FAILED: 3" "each increment carries out of the subshell"
}

# An assert_* failure is already durable and already bumps FAILS, so the
# hand-rolled sweep must subtract it. Counting the raw delta would report one
# failure as two, which inflates every existing suite's count the moment a real
# assertion fails.
test_assert_failures_are_not_double_counted() {
  _run_child '
test_x() { assert_eq got want "differs"; }'
  assert_contains "$CHILD_OUT" "FAILED: 1" "one assert failure counts once"
  assert_not_contains "$CHILD_OUT" "FAILED: 2" "not twice"
}

test_mixed_assert_and_bare_failures_are_counted_exactly_once_each() {
  _run_child '
test_x() {
  assert_eq got want "the assert failure"
  FAILS=$((FAILS + 1))
}'
  assert_contains "$CHILD_OUT" "FAILED: 2" \
    "one assert failure plus one bare increment is two, not three or one"
}

test_fail_test_prints_detail_lines() {
  _run_child '
test_x() { fail_test "mismatch" "got:  x" "want: y"; }'
  assert_contains "$CHILD_OUT" "got:  x" "detail lines are printed"
  assert_contains "$CHILD_OUT" "want: y" "every detail line is printed"
}

# fail_test has to register an assertion. If it did not, a test whose only check is
# a hand-rolled one would fail for the wrong reason — "NO ASSERTIONS RAN" instead
# of the failure it hit — and the reason is what someone reads first.
test_fail_test_counts_as_an_assertion() {
  _run_child '
test_x() { fail_test "the only check in this body"; }'
  assert_eq "$CHILD_RC" "1" "still fails"
  assert_contains "$CHILD_OUT" "the only check in this body" "the real reason is printed"
  assert_not_contains "$CHILD_OUT" "NO ASSERTIONS RAN" \
    "and it is not misreported as an empty test body"
}

test_assert_failures_still_reach_the_exit_code() {
  _run_child '
test_x() { assert_eq "got" "want" "values differ"; }'
  assert_eq "$CHILD_RC" "1" "an assert_eq failure fails the run"
  assert_contains "$CHILD_OUT" "values differ" "with its message"
}

# The guard that caught the 26 non-masked cases must keep working: a body that
# exits before asserting anything is a failure, not a pass.
test_empty_test_body_is_a_failure() {
  _run_child '
test_x() { return 0; }'
  assert_eq "$CHILD_RC" "1" "a body with no assertions fails"
  assert_contains "$CHILD_OUT" "NO ASSERTIONS RAN" "and says why"
}

test_aborting_test_body_is_a_failure() {
  _run_child '
test_x() {
  assert_eq a a "one passing assertion before the abort"
  exit 3
}'
  assert_eq "$CHILD_RC" "1" "a body that exits non-zero fails the run"
  assert_contains "$CHILD_OUT" "aborted" "and is reported as an abort"
}

test_a_wholly_passing_run_still_passes() {
  _run_child '
test_x() { assert_eq a a "ok"; }
test_y() { assert_contains "haystack" "hay" "ok"; }'
  assert_eq "$CHILD_RC" "0" "no false positives — a clean suite passes"
  assert_contains "$CHILD_OUT" "All tests passed" "and says so"
  assert_contains "$CHILD_OUT" "(2 tests)" "counting every test it ran"
}

# Not every suite runs through run_tests — count-blessings.test.sh drives its test
# functions from a top-level loop and checks FAILS itself. There is no subshell
# there, so the propagation gate never fires and fail_test's own FAILS bump is the
# only thing carrying the failure. Both callers have to work, or a helper that is
# correct in one suite silently reports nothing in the other.
test_fail_test_works_without_run_tests() {
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "source '$HARNESS'"
    # run_tests exports TEST_FAILS_TMP, and this driver deliberately does not call
    # run_tests to reassign it — so without the unset, the child's fail_test appends
    # to *this* suite's failure file and fails the parent run with no printed
    # message. Any child process that sources the harness and skips run_tests has
    # the same trap.
    echo 'unset TEST_FAILS_TMP'
    echo 'CURRENT_TEST=inline'
    echo 'fail_test "hand-rolled check failed outside run_tests"'
    echo '[ "$FAILS" -gt 0 ] || { echo "FAILS did not move"; exit 9; }'
    echo 'exit 1'
  } > "$TMP/driver.sh"
  local out rc
  out=$(bash "$TMP/driver.sh" 2>&1); rc=$?
  assert_eq "$rc" "1" "the driver sees FAILS move (rc=9 would mean it did not)"
  assert_contains "$out" "hand-rolled check failed outside run_tests" \
    "and the message is printed"
}

# Failures from separate test bodies must accumulate rather than the last one
# overwriting the tally — TEST_FAILS_TMP is truncated per test, so the count has
# to be folded into FAILS before that happens.
test_failures_from_several_tests_accumulate() {
  _run_child '
test_a() { fail_test "first"; }
test_b() { fail_test "second"; }
test_c() { assert_eq a a "passes"; }'
  assert_eq "$CHILD_RC" "1" "the run fails"
  assert_contains "$CHILD_OUT" "FAILED: 2" "both failures are counted, not just one"
}

run_tests
