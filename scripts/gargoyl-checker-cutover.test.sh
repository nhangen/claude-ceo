#!/bin/bash
# Tests for gargoyl-checker-cutover.sh (#653): the human-run cutover from the
# standalone launchd timer to the ceo-schedulerd/cronbird registry. Only the
# launchd-retirement step is exercised — with a stubbed launchctl and a fixture
# HOME — because the live steps (ceo playbook scan/enable) are real host
# mutations the suite must never perform (test-writes-stay-in-the-fixture).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUTOVER="$SCRIPT_DIR/gargoyl-checker-cutover.sh"
PLIST_LABEL="dev.nhangen.gargoyl.checker"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  export TEST_HOME
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME/home"
  mkdir -p "$HOME/Library/LaunchAgents" "$TEST_HOME/stubs"
  export PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

  cat > "$TEST_HOME/stubs/launchctl" <<STUB
#!/bin/bash
# argv validation (stub-cli-argv-validation): only the cutover's bootout shape
# is accepted, so a malformed call never reads as a successful retirement.
[ "\$1" = "bootout" ] || exit 64
case "\$2" in
  gui/*/"$PLIST_LABEL") ;;
  *) exit 64 ;;
esac
printf '%s\n' "\$*" >> "\$TEST_HOME/launchctl-calls"
[ -n "\${LAUNCHCTL_STUB_FAIL:-}" ] && exit 1
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/launchctl"
  export PATH="$TEST_HOME/stubs:$PATH"
  unset LAUNCHCTL_STUB_FAIL
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset TEST_HOME HOME_BACKUP PATH_BACKUP PLIST LAUNCHCTL_STUB_FAIL
}

run_cutover() {
  local rc=0
  bash "$CUTOVER" "$@" > "$TEST_HOME/stdout" 2> "$TEST_HOME/stderr" || rc=$?
  RUN_CUTOVER_RC=$rc
}

bootout_calls() {
  cat "$TEST_HOME/launchctl-calls" 2>/dev/null
}

test_retire_removes_plist_and_boots_out() {
  printf 'placeholder plist\n' > "$PLIST"
  run_cutover --retire-only
  assert_eq "$RUN_CUTOVER_RC" "0" "retire-only must succeed"
  assert_contains "$(bootout_calls)" "bootout gui/$(id -u)/$PLIST_LABEL" "the legacy job must be booted out of the gui domain"
  [ -f "$PLIST" ] && fail_test "the legacy plist must be removed"
  return 0
}

test_retire_survives_bootout_miss() {
  # bootout fails when the job is not loaded; removing the plist is what
  # stops it loading again, so the retirement must still complete.
  printf 'placeholder plist\n' > "$PLIST"
  LAUNCHCTL_STUB_FAIL=1 run_cutover --retire-only
  assert_eq "$RUN_CUTOVER_RC" "0" "a bootout miss must not abort the retirement"
  [ -f "$PLIST" ] && fail_test "the plist must still be removed when bootout misses"
  assert_not_contains "$(cat "$TEST_HOME/stdout")" "bootout done" "a failed bootout must not be reported as done"
  return 0
}

test_dry_run_touches_nothing() {
  printf 'placeholder plist\n' > "$PLIST"
  run_cutover --dry-run --retire-only
  assert_eq "$RUN_CUTOVER_RC" "0" "dry-run must succeed"
  assert_file_exists "$PLIST" "dry-run must not remove the plist"
  assert_eq "$(bootout_calls)" "" "dry-run must not call launchctl"
  assert_contains "$(cat "$TEST_HOME/stdout")" "would remove: $PLIST" "dry-run must name the plist it would remove"
}

test_absent_plist_is_a_clean_noop() {
  run_cutover --retire-only
  assert_eq "$RUN_CUTOVER_RC" "0" "an absent plist is not an error"
  assert_eq "$(bootout_calls)" "" "no plist means no bootout"
  assert_contains "$(cat "$TEST_HOME/stdout")" "nothing to retire" "the noop must be stated"
}

test_unknown_flag_is_rejected() {
  run_cutover --bogus
  assert_eq "$RUN_CUTOVER_RC" "2" "an unknown flag must exit 2, not fall through"
}

run_tests "$@"
