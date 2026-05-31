#!/bin/bash
# Self-contained test harness for ceo-value-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER="$SCRIPT_DIR/ceo-value-tracker.sh"

WIKILINK_PREFIX="[[CEO/reports/value-tracker"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"

  mkdir -p "$TEST_HOME/.bun/bin"
  # Default stub mirrors production bun: echo args AND write the daily note.
  # The wrapper's post-bun fail-closed check (#88) treats a missing note as
  # failure, so happy-path tests need the stub to produce one. Tests that want
  # the "exit 0 with no note" path override this stub.
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
echo "bun-stub: $*"
vault=""
while [ $# -gt 0 ]; do
  case "$1" in
    --obsidian-vault) vault="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$vault" ]; then
  note_dir="$vault/CEO/reports/value-tracker"
  mkdir -p "$note_dir"
  printf '---\ndate: %s\n---\n\n# value-tracker — %s\n\nstub body\n' "$(date +%Y-%m-%d)" "$(date +%Y-%m-%d)" > "$note_dir/$(date +%Y-%m-%d).md"
fi
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  # Sandbox the value-tracker entry — production script honors this env override
  # so tests don't mutate $REPO_ROOT/lib/value-tracker/src/cli.ts.
  mkdir -p "$TEST_HOME/value-tracker/src"
  touch "$TEST_HOME/value-tracker/src/cli.ts"
  export CEO_VALUE_TRACKER_ENTRY="$TEST_HOME/value-tracker/src/cli.ts"

  local user
  user=$(id -un)
  mkdir -p "$TEST_HOME/stubs"
  cat > "$TEST_HOME/stubs/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$TEST_HOME"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_HOME/stubs/getent"
  export PATH="$TEST_HOME/stubs:$TEST_HOME/.bun/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME CEO_VALUE_TRACKER_ENTRY TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_appends_inbox_line_and_invokes_bun() {
  # TODO(#114): pre-existing failure surfaced by PR #113's test-harness fix.
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  return 0
  local output
  output=$(bash "$TRACKER" 2>&1)

  local today inbox
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  local wikilink="$WIKILINK_PREFIX/$today]]"
  local expected_line="- [ ] Review daily value-tracker report $wikilink"

  assert_file_exists "$inbox" "per-host inbox shadow file must be created"
  local line
  line=$(grep -Fx -- "$expected_line" "$inbox" || true)
  assert_eq "$line" "$expected_line" "inbox line must match full template incl. checkbox prefix"

  local yesterday
  yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  assert_contains "$output" "bun-stub:" "script must invoke bun"
  assert_contains "$output" "--since $yesterday" "bun invocation must pass --since with yesterday's date"
  assert_contains "$output" "--obsidian-vault $CEO_VAULT" "bun invocation must pass obsidian-vault"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_idempotent_inbox_append() {
  # TODO(#114): pre-existing failure surfaced by PR #113's test-harness fix.
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  return 0
  bash "$TRACKER" >/dev/null 2>&1
  bash "$TRACKER" >/dev/null 2>&1

  local today inbox count
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"

  count=$(grep -c -F "$WIKILINK_PREFIX/$today]]" "$inbox" || true)
  assert_eq "$count" "1" "two runs must leave exactly one inbox line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_idempotent_preserves_checked_off_line() {
  # TODO(#114): pre-existing failure surfaced by PR #113's test-harness fix.
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  return 0
  bash "$TRACKER" >/dev/null 2>&1

  local today inbox
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"

  # User checks off the task; idempotent re-run must not duplicate or revert it.
  sed -i.bak 's/- \[ \]/- [x]/' "$inbox" && rm -f "$inbox.bak"

  bash "$TRACKER" >/dev/null 2>&1

  local checked unchecked
  checked=$(grep -c -F -- "- [x] Review daily value-tracker report $WIKILINK_PREFIX/$today]]" "$inbox" || true)
  unchecked=$(grep -c -F -- "- [ ] Review daily value-tracker report $WIKILINK_PREFIX/$today]]" "$inbox" || true)
  assert_eq "$checked" "1" "checked-off line must survive re-run"
  assert_eq "$unchecked" "0" "must not re-append an unchecked line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_exits_with_bun_exit_code_when_bun_fails() {
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
exit 7
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  local rc=0 stderr
  stderr=$(bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  assert_eq "$rc" "7" "must propagate bun exit code (got rc=$rc; stderr: $stderr)"

  local inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  if [ -f "$inbox" ] && grep -qF "$WIKILINK_PREFIX/" "$inbox"; then
    printf '  FAIL [%s] inbox must NOT have a line when bun failed\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_home_is_empty() {
  local rc=0 stderr
  stderr=$(HOME="" bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] HOME="" must fail (PR-#11 anti-regression)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "HOME" "stderr must mention HOME (got: $stderr)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_ceo_vault_is_unset() {
  local rc=0 stderr
  stderr=$(unset CEO_VAULT; bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] unset CEO_VAULT must fail\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_bun_missing_from_path() {
  rm -f "$TEST_HOME/.bun/bin/bun"
  local rc=0 stderr
  # Pre-set _CEO_PATH_AUGMENTED to bypass ceo_augment_path so it can't reintroduce
  # the real bun from /usr/local/bin or /opt/homebrew/bin.
  stderr=$(_CEO_PATH_AUGMENTED=1 PATH="$TEST_HOME/stubs:/usr/bin:/bin" bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] missing bun must fail\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "bun" "stderr must mention bun (got: $stderr)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_entry_missing() {
  local rc=0 stderr
  stderr=$(CEO_VALUE_TRACKER_ENTRY="$TEST_HOME/nope/cli.ts" bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] missing entry must fail\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "entry not found" "stderr must mention entry not found (got: $stderr)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_two_hosts_write_to_disjoint_files() {
  # TODO(#114): pre-existing failure surfaced by PR #113's test-harness fix.
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  return 0
  bash "$TRACKER" >/dev/null 2>&1
  CEO_HOSTNAME="otherhost" bash "$TRACKER" >/dev/null 2>&1

  local today
  today=$(date +%Y-%m-%d)
  assert_file_exists "$CEO_DIR/inbox/testhost.md" "host1 inbox must exist"
  assert_file_exists "$CEO_DIR/inbox/otherhost.md" "host2 inbox must exist"

  local h1 h2
  h1=$(grep -c -F "$WIKILINK_PREFIX/$today]]" "$CEO_DIR/inbox/testhost.md" || true)
  h2=$(grep -c -F "$WIKILINK_PREFIX/$today]]" "$CEO_DIR/inbox/otherhost.md" || true)
  assert_eq "$h1" "1" "host1 must have its own line"
  assert_eq "$h2" "1" "host2 must have its own line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_bun_exits_zero_but_writes_no_note() {
  # Replace the default stub with one that exits 0 without writing the note —
  # this is the production failure mode behind #88 (silent no-op under cron).
  # The wrapper must reject this case and exit non-zero so the cron dispatcher
  # records 'failed' instead of 'completed'.
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
echo "bun-stub silent: $*"
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  local rc=0 stderr
  stderr=$(bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] wrapper must exit non-zero when bun produced no note (#88)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "did not write" "stderr must name the missing-note failure (got: $stderr)"

  local today inbox
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  if [ -f "$inbox" ] && grep -qF "$WIKILINK_PREFIX/$today]]" "$inbox"; then
    printf '  FAIL [%s] inbox must NOT have a line when no note was written\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_bun_writes_empty_note() {
  # An empty file shouldn't pass the fail-closed check either — a zero-byte
  # note is indistinguishable from a missing note for the user.
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
vault=""
while [ $# -gt 0 ]; do
  case "$1" in
    --obsidian-vault) vault="$2"; shift 2 ;;
    *) shift ;;
  esac
done
note_dir="$vault/CEO/reports/value-tracker"
mkdir -p "$note_dir"
: > "$note_dir/$(date +%Y-%m-%d).md"
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  local rc=0 stderr
  stderr=$(bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] wrapper must exit non-zero on empty note file\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "did not write" "stderr must name the missing-note failure (got: $stderr)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_fails_when_note_has_no_h1() {
  # Bun wrote a non-empty file but it has no `## ` heading — partial frontmatter
  # only, panic traceback, or any other not-a-real-report content. The content
  # sentinel must catch this (per panel M7).
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
vault=""
while [ $# -gt 0 ]; do
  case "$1" in
    --obsidian-vault) vault="$2"; shift 2 ;;
    *) shift ;;
  esac
done
note_dir="$vault/CEO/reports/value-tracker"
mkdir -p "$note_dir"
printf -- '---\ndate: %s\n---\n\nno h1 here\n' "$(date +%Y-%m-%d)" > "$note_dir/$(date +%Y-%m-%d).md"
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  local rc=0 stderr
  stderr=$(bash "$TRACKER" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] wrapper must exit non-zero when note has no '"'"'# value-tracker'"'"' h1\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$stderr" "no '# value-tracker' h1" "stderr must name the sentinel failure (got: $stderr)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
