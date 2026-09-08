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
case "$*" in
  --run-once) ;;
  *) printf 'norx-runner stub: unexpected argv: %s\n' "$*" >&2; exit 64 ;;
esac
# The real runner writes its phase lines while it runs, so a fixture that only
# pre-seeds the log cannot exercise the wrapper's "is this log from this run?"
# check — it would be indistinguishable from yesterday's leftovers.
if [ -n "${NORX_TEST_RUNNER_LOG_LINES:-}" ] && [ -n "${NORX_TEST_RUNNER_LOG_DEST:-}" ]; then
  cat "$NORX_TEST_RUNNER_LOG_LINES" >> "$NORX_TEST_RUNNER_LOG_DEST"
fi
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
  unset NORX_TEST_RUNNER_LOG_LINES NORX_TEST_RUNNER_LOG_DEST
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
  # Redirected: the failure path is diagnostic-rich now, and an ERROR line in a
  # passing suite teaches the reader to skim past ERROR lines.
  bash "$TARGET" 2>/dev/null
  failed_rc=$?
  assert_eq "$failed_rc" "9" "playbook must preserve the bookkeeping failure code"
  assert_fails "failed bookkeeping must not write success marker" test -f "$NORX_BOOKKEEPING_STATE_DIR/ceo-last-success-date"
  export NORX_TEST_RUNNER_EXIT=0
  bash "$TARGET"
  assert_eq "$(run_count)" "2" "next hourly check must retry after a failure"
}

# A runner failure has to reach the operator with something they can act on. The
# runner writes its phase results to its own log and nothing to stderr, so an
# unguarded call left the dispatcher with nothing to capture and the recorded
# failure read "Script exited 1 for norx-bookkeeping" and stopped there.
# Measured 2026-09-08: ten failures over three hours, all of them
# `sync_all_sheets|remote_sheets_sync_failed`, with every import phase green.
# Seeds a log dir with lines from a *previous* run, aged so its mtime cannot be
# confused with this run's, and arms the stub to append this run's lines while it
# runs. Echoes the log dir.
seed_runner_log() {
  local logdir="$NORX_BOOKKEEPING_STATE_DIR/runner-logs"
  local logfile="$logdir/daily-bookkeeping-2026-09-08.log"
  mkdir -p "$logdir"
  printf '%s\n' "$@" > "$logfile"
  touch -t 202609070915 "$logfile"
  printf '%s' "$logdir"
}

test_a_runner_failure_names_the_log_and_the_failing_phases() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir
  logdir=$(seed_runner_log \
    '2026-09-08T09:15:55Z|run-0|sync_all_sheets|stale_prior_run_failure')
  printf '%s\n' \
    '2026-09-08T10:15:47Z|run-1|import_mercury_ledger|success' \
    '2026-09-08T10:15:55Z|run-1|sync_all_sheets|remote_sheets_sync_failed' \
    > "$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_LINES="$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_DEST="$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "the diagnostic must not change the exit code it explains"
  assert_contains "$err" "runner exited 9" "the failure names the runner's status"
  assert_contains "$err" "daily-bookkeeping-2026-09-08.log" "and points at the runner's own log"
  assert_contains "$err" "remote_sheets_sync_failed" "and quotes the phase that actually failed"
  assert_not_contains "$err" "import_mercury_ledger" \
    "successful phases are not quoted — they bury the one line that matters"
  # The runner appends every run of the UTC day to one file and this playbook
  # runs hourly, so an unscoped tail hands an operator an earlier run's cause.
  assert_not_contains "$err" "stale_prior_run_failure" \
    "an earlier run's failures are not this run's diagnosis"
}

# The runner has non-zero exits that write no log line at all — an unwritable log
# dir, a failed mktemp, and exit 75 when another copy holds the lock. In each the
# newest log belongs to a previous run, and quoting it names a cause that is not
# this failure's.
test_a_runner_failure_does_not_quote_a_log_written_before_this_run() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir
  logdir=$(seed_runner_log \
    '2026-09-08T09:15:55Z|run-0|reconcile_ledger|mercury_auth_expired')

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "a stale-log verdict must not change the exit code"
  assert_contains "$err" "predates this run" "the wrapper says the log is not this run's"
  assert_not_contains "$err" "mercury_auth_expired" \
    "a previous run's cause must never be presented as this one's"
}

# Exit 75 is the runner's "another copy holds my lock". The other copy is by
# definition writing the log right now, so the mtime check would call it fresh and
# quote a concurrent run's phases for a run that did no work.
test_a_lock_busy_exit_quotes_no_log_even_when_one_was_just_written() {
  export NORX_TEST_RUNNER_EXIT=75
  local logdir
  logdir=$(seed_runner_log '2026-09-08T09:00:00Z|run-0|lock|success')
  printf '%s\n' '2026-09-08T10:15:55Z|run-other|sync_all_sheets|other_copys_failure' \
    > "$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_LINES="$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_DEST="$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "75" "the lock-busy verdict must not change the exit code"
  assert_contains "$err" "holds its lock" "the wrapper says another copy is running"
  assert_not_contains "$err" "other_copys_failure" \
    "a concurrent run's phases are not this run's diagnosis"
}

# Newest by mtime, not by name. The date-derived filename this replaced called
# DATE_BIN with a second format and aborted the wrapper under `set -e`; sorting
# by name instead would pass every other arm while quoting the wrong file.
test_a_runner_failure_picks_the_newest_log_by_mtime_not_by_name() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir="$NORX_BOOKKEEPING_STATE_DIR/runner-logs"
  mkdir -p "$logdir"
  # Sorts *first*, so a plain `ls | head -n 1` picks it and a mtime sort does not.
  printf '%s\n' '2026-09-07T09:00:00Z|run-old|sync_all_sheets|sorts_first_but_older' \
    > "$logdir/daily-bookkeeping-2026-09-07.log"
  touch -t 202609070915 "$logdir/daily-bookkeeping-2026-09-07.log"
  : > "$logdir/daily-bookkeeping-2026-09-08.log"
  printf '%s\n' '2026-09-08T10:15:55Z|run-1|sync_all_sheets|written_by_this_run' \
    > "$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_LINES="$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_DEST="$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "log selection must not change the exit code"
  assert_contains "$err" "written_by_this_run" "the log this run wrote is the one quoted"
  assert_not_contains "$err" "sorts_first_but_older" \
    "an alphabetically earlier but older log is not the newest one"
}

# The oldest of four is dropped. With a single failing line the cap is
# indistinguishable from no cap at all.
test_a_runner_failure_quotes_at_most_the_last_three_phases() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir
  logdir=$(seed_runner_log '2026-09-08T09:00:00Z|run-0|lock|success')
  printf '%s\n' \
    '2026-09-08T10:15:51Z|run-1|phase_one|oldest_failure' \
    '2026-09-08T10:15:52Z|run-1|phase_two|second_failure' \
    '2026-09-08T10:15:53Z|run-1|phase_three|third_failure' \
    '2026-09-08T10:15:54Z|run-1|phase_four|newest_failure' \
    > "$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_LINES="$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_DEST="$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "the cap must not change the exit code"
  assert_contains "$err" "newest_failure" "the most recent failing phase is quoted"
  assert_not_contains "$err" "oldest_failure" "the fourth-from-last is dropped"
}

# An empty extraction has to say so. Printing a log path and nothing else leaves
# "no failures in that log" and "the extraction broke" looking identical.
test_a_runner_failure_with_an_all_success_log_says_there_are_no_phases() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir
  logdir=$(seed_runner_log '2026-09-08T09:00:00Z|run-0|lock|success')
  printf '%s\n' '2026-09-08T10:15:47Z|run-1|import_mercury_ledger|success' \
    > "$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_LINES="$TEST_ROOT/runner-log-lines"
  export NORX_TEST_RUNNER_LOG_DEST="$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "an empty extraction must not change the exit code"
  assert_contains "$err" "no non-success phase lines" "the wrapper says it found none"
}

# The `-r` half of the guard. The nonexistent-directory arm below only reaches
# the `-n` half, so an unreadable-but-present log had no coverage.
test_a_runner_failure_with_an_unreadable_log_still_preserves_the_code() {
  export NORX_TEST_RUNNER_EXIT=9
  local logdir
  logdir=$(seed_runner_log '2026-09-08T09:00:00Z|run-0|lock|success')
  chmod 000 "$logdir/daily-bookkeeping-2026-09-08.log"

  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$logdir" bash "$TARGET" 2>&1 >/dev/null) || rc=$?
  chmod 644 "$logdir/daily-bookkeeping-2026-09-08.log"

  assert_eq "$rc" "9" "an unreadable log must not change the exit code"
  assert_contains "$err" "no readable runner log" "and degrades to the not-found message"
}

# The diagnostic reads a directory it does not own, so it has to degrade rather
# than fail. An earlier version derived the log's filename from DATE_BIN, and a
# DATE_BIN that did not accept the second format aborted the wrapper under
# `set -e` with its own status — turning a runner exit of 9 into a 2.
test_a_runner_failure_with_a_missing_log_directory_still_preserves_the_code() {
  export NORX_TEST_RUNNER_EXIT=9
  local err rc=0
  err=$(NORX_BOOKKEEPING_LOG_DIR="$NORX_BOOKKEEPING_STATE_DIR/nonexistent" \
        bash "$TARGET" 2>&1 >/dev/null) || rc=$?

  assert_eq "$rc" "9" "a missing runner log must not change the exit code"
  assert_contains "$err" "runner exited 9" "the failure is still reported"
  assert_contains "$err" "no readable runner log" "and says the log could not be found"
  # Names the directory it actually looked in, not the compiled-in default —
  # without this the arm passes whether or not NORX_BOOKKEEPING_LOG_DIR is
  # honored, and the message would send an operator to the wrong path.
  assert_contains "$err" "$NORX_BOOKKEEPING_STATE_DIR/nonexistent" \
    "and names the directory it searched"
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
