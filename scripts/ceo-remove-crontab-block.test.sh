#!/bin/bash
# Tests for _remove_crontab_block in scripts/ceo.
#
# Verifies the migration-leftover removal strips the CEO-installed block and any
# stray CEO cron lines (anchored on the `# ceo:<name>` marker the installer
# emits) while PRESERVING unrelated user lines that merely mention ceo-cron.sh.
# Regression guard for the unanchored `grep -v ceo-cron.sh` that clobbered any
# user line containing that substring (anchored-regex-for-identifier-allowlists).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}

# crontab stub: `-l` prints $CRONTAB_BODY; a write (stdin/`-`) records the
# installed payload to $INSTALLED so a test can assert the resulting crontab.
# Any other argv shape exits non-zero per stub-cli-argv-validation.
_write_crontab_stub() {
  export CEO_CRONTAB_BIN="$TMP/stub-crontab"
  export INSTALLED="$TMP/installed.txt"
  : > "$INSTALLED"
  cat > "$CEO_CRONTAB_BIN" <<'STUB'
#!/bin/bash
case "$1" in
  -l) printf '%s\n' "$CRONTAB_BODY" ;;
  -|"") cat > "$INSTALLED" ;;
  *) echo "stub-crontab: unexpected argv: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$CEO_CRONTAB_BIN"
}

setup() {
  TMP=$(mktemp -d)
  export CEO_SCHEDULER=crontab
  _write_crontab_stub
  _load_ceo_helpers
}

teardown() {
  rm -rf "$TMP"
  unset CRONTAB_BODY
}

test_removes_block_and_preserves_user_line_mentioning_ceo_cron() {
  export CRONTAB_BODY="# my own wrapper around ceo-cron.sh — keep this
0 3 * * * /home/me/run-backup.sh
# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
0 9 * * * /p/ceo-cron.sh standup  # ceo:standup
# CEO Agent END"

  _remove_crontab_block

  local result; result=$(cat "$INSTALLED")
  assert_contains "$result" "wrapper around ceo-cron.sh" \
    "a user comment mentioning ceo-cron.sh must be PRESERVED, not clobbered"
  assert_contains "$result" "/home/me/run-backup.sh" \
    "the user's own cron line must be preserved"
  assert_not_contains "$result" "# ceo:morning" \
    "the CEO-installed morning line must be removed"
  assert_not_contains "$result" "CEO Agent START" \
    "the CEO block markers must be removed"
}

# A stray CEO line outside the START/END block (carrying the `# ceo:` marker) is
# still a CEO-installed line and must be stripped.
test_removes_stray_ceo_line_outside_block() {
  export CRONTAB_BODY="0 0 * * * /usr/bin/true
*/10 * * * * /p/ceo-cron.sh orphan  # ceo:orphan"

  _remove_crontab_block

  local result; result=$(cat "$INSTALLED")
  assert_not_contains "$result" "# ceo:orphan" \
    "a stray CEO-installed line (with the # ceo: marker) must be removed"
  assert_contains "$result" "/usr/bin/true" \
    "the unrelated user line must be preserved"
}

# No CEO content at all → no install attempt (no-op success).
test_noop_when_no_ceo_content() {
  export CRONTAB_BODY="0 0 * * * /usr/bin/true
0 6 * * * /home/me/ceo-cron.sh-lookalike.sh run"

  _remove_crontab_block
  local rc=$?

  assert_eq "$rc" "0" "a crontab with no CEO block is a no-op success"
  # No write should have happened (INSTALLED stays empty).
  local result; result=$(cat "$INSTALLED")
  assert_eq "$result" "" "no crontab write when there is no CEO content to remove"
}

# Regression guard for #467: on the daemon backend (or macOS default),
# _remove_crontab_block must still read and purge leftover crontab blocks.
test_removes_block_on_daemon_backend() {
  export CEO_SCHEDULER=daemon
  export CRONTAB_BODY="# user job
0 2 * * * /usr/bin/backup
# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
# CEO Agent END"

  local rc=0
  _remove_crontab_block || rc=$?

  assert_eq "$rc" "0" "_remove_crontab_block must succeed on daemon backend"
  local result; result=$(cat "$INSTALLED")
  assert_contains "$result" "/usr/bin/backup" \
    "unrelated user lines must be preserved on daemon backend"
  assert_not_contains "$result" "# ceo:morning" \
    "CEO block lines must be purged on daemon backend"
  assert_not_contains "$result" "CEO Agent START" \
    "CEO markers must be purged on daemon backend"
}

# When crontab contains only CEO block lines, removing it installs an empty crontab.
test_removes_block_when_only_ceo_lines_present() {
  export CRONTAB_BODY="# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
# CEO Agent END"

  rm -f "$INSTALLED"
  local rc=0
  _remove_crontab_block || rc=$?

  assert_eq "$rc" "0" "purging only-CEO crontab must succeed"
  assert_file_exists "$INSTALLED" "crontab must be updated (installed)"
  local result; result=$(cat "$INSTALLED")
  assert_eq "$result" "" "crontab payload must be empty"
}

# When crontab write fails, the error is reported on stderr and non-zero rc returned.
test_failure_installing_cleaned_crontab_exits_nonzero() {
  export CEO_CRONTAB_BIN="$TMP/stub-crontab-failing"
  cat > "$CEO_CRONTAB_BIN" <<'STUB'
#!/bin/bash
case "$1" in
  -l) printf '%s\n' "$CRONTAB_BODY" ;;
  -|"") echo "crontab: write error (simulated)" >&2; exit 2 ;;
  *) echo "stub-crontab: unexpected argv: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$CEO_CRONTAB_BIN"

  export CRONTAB_BODY="# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
# CEO Agent END"

  local out rc=0
  out=$(_remove_crontab_block 2>&1) || rc=$?

  if [ "$rc" -eq 0 ]; then
    fail_test "write failure must return non-zero"
  fi
  assert_contains "$out" "crontab removal failed" "failure message must be surfaced on stderr"
  assert_contains "$out" "write error" "underlying crontab error message must be included"
}

# When crontab binary is missing, _remove_crontab_block is a clean no-op (rc=0).
test_missing_crontab_binary_returns_zero() {
  export CEO_CRONTAB_BIN="$TMP/nonexistent-crontab"
  local rc=0
  _remove_crontab_block || rc=$?
  assert_eq "$rc" "0" "missing crontab binary must return 0"
}

run_tests
