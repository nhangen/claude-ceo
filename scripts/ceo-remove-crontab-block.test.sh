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

run_tests
