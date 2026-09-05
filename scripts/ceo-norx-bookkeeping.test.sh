#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/ceo-norx-bookkeeping.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_ROOT=$(mktemp -d)
  export HOME="$TEST_ROOT/home"
  export NORX_BOOKKEEPING_STATE_DIR="$TEST_ROOT/state"
  export NORX_BOOKKEEPING_RUNNER="$TEST_ROOT/norx-runner"
  export NORX_BOOKKEEPING_DATE_BIN="$TEST_ROOT/date"
  mkdir -p "$HOME"
  printf '2026-09-05\n375\n' > "$TEST_ROOT/clock"
  cat > "$NORX_BOOKKEEPING_DATE_BIN" <<'STUB'
#!/bin/bash
case "$1" in
  '+%F %H %M')
    day=$(sed -n '1p' "${NORX_TEST_CLOCK:?}")
    minutes=$(sed -n '2p' "${NORX_TEST_CLOCK:?}")
    printf '%s %02d %02d\n' "$day" "$((minutes / 60))" "$((minutes % 60))"
    ;;
  *) exit 2 ;;
esac
STUB
  cat > "$NORX_BOOKKEEPING_RUNNER" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${NORX_TEST_RUNS:?}"
exit "${NORX_TEST_RUNNER_EXIT:-0}"
STUB
  chmod +x "$NORX_BOOKKEEPING_DATE_BIN" "$NORX_BOOKKEEPING_RUNNER"
  export NORX_TEST_CLOCK="$TEST_ROOT/clock"
  export NORX_TEST_RUNS="$TEST_ROOT/runs"
  unset NORX_TEST_RUNNER_EXIT
}

teardown() {
  rm -rf "$TEST_ROOT"
  unset TEST_ROOT HOME NORX_BOOKKEEPING_STATE_DIR NORX_BOOKKEEPING_RUNNER
  unset NORX_BOOKKEEPING_DATE_BIN NORX_TEST_CLOCK NORX_TEST_RUNS NORX_TEST_RUNNER_EXIT
}

run_count() {
  if [ -f "$NORX_TEST_RUNS" ]; then
    wc -l < "$NORX_TEST_RUNS" | tr -d ' '
  else
    printf '0\n'
  fi
}

file_mode() {
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

test_before_daily_boundary_skips() {
  printf '2026-09-05\n374\n' > "$NORX_TEST_CLOCK"
  bash "$TARGET"
  assert_eq "$(run_count)" "0" "06:14 must not run bookkeeping"
}

test_boundary_runs_once_and_records_success() {
  local outcome="$TEST_ROOT/outcome"
  export CEO_RUNNER_OUTCOME_FILE="$outcome"
  bash "$TARGET"
  assert_eq "$(run_count)" "1" "06:15 must run bookkeeping"
  assert_eq "$(cat "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date")" "2026-09-05" "success marker must record the local date"
  assert_eq "$(cat "$NORX_TEST_RUNS")" "--run-once" "wrapper must invoke the production runner in run-once mode"
  assert_eq "$(file_mode "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date")" "600" "success marker must be private"
  assert_eq "$(cat "$outcome")" "noop" "routine success must remain silent"
  unset CEO_RUNNER_OUTCOME_FILE
}

test_same_day_replay_skips_runner() {
  bash "$TARGET"
  printf '2026-09-05\n900\n' > "$NORX_TEST_CLOCK"
  bash "$TARGET"
  assert_eq "$(run_count)" "1" "same-day hourly checks must not replay bookkeeping"
}

test_failure_does_not_advance_marker_and_next_check_retries() {
  export NORX_TEST_RUNNER_EXIT=9
  bash "$TARGET"
  failed_rc=$?
  assert_eq "$failed_rc" "9" "playbook must preserve the bookkeeping failure code"
  assert_fails "failed bookkeeping must not write success marker" test -f "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date"
  export NORX_TEST_RUNNER_EXIT=0
  bash "$TARGET"
  assert_eq "$(run_count)" "2" "next hourly check must retry after a failure"
}

test_next_day_runs_again() {
  bash "$TARGET"
  printf '2026-09-06\n375\n' > "$NORX_TEST_CLOCK"
  bash "$TARGET"
  assert_eq "$(run_count)" "2" "a new business day must run again"
  assert_eq "$(cat "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date")" "2026-09-06" "marker must advance after the new day's success"
}

test_missing_runner_fails_without_marker() {
  rm "$NORX_BOOKKEEPING_RUNNER"
  assert_fails "missing bookkeeping runner must fail closed" bash "$TARGET"
  assert_fails "missing runner must not create success marker" test -f "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date"
}

test_today_marker_is_noop_when_runner_is_unavailable() {
  mkdir -p "$NORX_BOOKKEEPING_STATE_DIR"
  printf '2026-09-05\n' > "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date"
  rm "$NORX_BOOKKEEPING_RUNNER"
  bash "$TARGET"
  assert_eq "$?" "0" "today's success must remain a no-op when the runtime moves"
  assert_eq "$(run_count)" "0" "today's success must not consult the runner"
}

test_stale_or_malformed_marker_remains_due() {
  mkdir -p "$NORX_BOOKKEEPING_STATE_DIR"
  printf 'not-a-date\n' > "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date"
  bash "$TARGET"
  assert_eq "$(run_count)" "1" "a malformed marker must not suppress bookkeeping"
  assert_eq "$(cat "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date")" "2026-09-05" "a successful retry must replace the malformed marker"
}

test_concurrent_check_is_a_quiet_noop() {
  cat > "$NORX_BOOKKEEPING_RUNNER" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${NORX_TEST_RUNS:?}"
printf 'started\n' > "${NORX_TEST_STARTED:?}"
sleep 1
STUB
  chmod +x "$NORX_BOOKKEEPING_RUNNER"
  export NORX_TEST_STARTED="$TEST_ROOT/started"
  bash "$TARGET" &
  first_pid=$!
  while [ ! -f "$NORX_TEST_STARTED" ]; do sleep 0.01; done
  bash "$TARGET"
  second_rc=$?
  wait "$first_pid"
  assert_eq "$second_rc" "0" "concurrent wrapper check must be a quiet no-op"
  assert_eq "$(run_count)" "1" "concurrent checks must invoke the runner only once"
  unset NORX_TEST_STARTED
}

test_stale_lock_is_recovered() {
  mkdir -p "$NORX_BOOKKEEPING_STATE_DIR/ceo-wrapper.lock"
  printf '99999999\n' > "$NORX_BOOKKEEPING_STATE_DIR/ceo-wrapper.lock/owner"
  bash "$TARGET"
  assert_eq "$(run_count)" "1" "a dead wrapper lock must be recovered"
  assert_fails "recovered lock must be removed after success" test -d "$NORX_BOOKKEEPING_STATE_DIR/ceo-wrapper.lock"
}

test_ownerless_lock_fails_closed() {
  mkdir -p "$NORX_BOOKKEEPING_STATE_DIR/ceo-wrapper.lock"
  assert_fails "an ownerless lock must not be removed as stale" bash "$TARGET"
  assert_eq "$(run_count)" "0" "an ownerless lock must block runner invocation"
  assert_fails "ownerless lock must remain for diagnosis" test ! -d "$NORX_BOOKKEEPING_STATE_DIR/ceo-wrapper.lock"
}

run_tests
