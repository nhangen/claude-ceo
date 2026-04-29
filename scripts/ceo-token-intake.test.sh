#!/bin/bash
# Self-contained test harness for ceo-token-intake.sh — verifies the report
# write, idempotency, and write-failure invariants the script claims.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTAKE="$SCRIPT_DIR/ceo-token-intake.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [[ ! -f "$path" ]]; then
    printf '  FAIL [%s] %s\n    expected file: %q\n' "$CURRENT_TEST" "$msg" "$path"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR/reports/token"
  : > "$CEO_DIR/inbox.md"

  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/rtk" << 'STUB'
#!/bin/bash
echo "rtk-stub: $*"
STUB
  cat > "$TEST_HOME/bin/token-scope" << 'STUB'
#!/bin/bash
echo "token-scope-stub: $*"
STUB
  chmod +x "$TEST_HOME/bin/rtk" "$TEST_HOME/bin/token-scope"
  export PATH="$TEST_HOME/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_creates_report_and_appends_inbox_line() {
  bash "$INTAKE" >/dev/null 2>&1
  local today report
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today.md"
  assert_file_exists "$report" "report file must exist after intake"
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today]]" "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "inbox must contain exactly one wikilink to today's report"
}

test_idempotent_same_day() {
  bash "$INTAKE" >/dev/null 2>&1
  bash "$INTAKE" >/dev/null 2>&1
  local today count
  today=$(date +%Y-%m-%d)
  count=$(grep -c -F "[[CEO/reports/token/$today]]" "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "two runs must leave exactly one inbox line"
}

test_does_not_re_append_after_inbox_checkoff() {
  bash "$INTAKE" >/dev/null 2>&1
  local today
  today=$(date +%Y-%m-%d)
  sed -i.bak "s|- \[ \] Review daily token report \[\[CEO/reports/token/$today\]\]|- [x] Review daily token report [[CEO/reports/token/$today]]|" "$CEO_DIR/inbox.md"
  rm -f "$CEO_DIR/inbox.md.bak"

  bash "$INTAKE" >/dev/null 2>&1
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today]]" "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "checked-off line must not trigger re-append"
}

test_aborts_on_unwritable_report_dir() {
  if [ "$(id -u)" = "0" ]; then
    return 0  # chmod doesn't apply to root
  fi
  chmod 0500 "$CEO_DIR/reports/token"
  local rc=0
  bash "$INTAKE" >/dev/null 2>&1 || rc=$?
  chmod 0700 "$CEO_DIR/reports/token"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero on unwritable report dir (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  local inbox
  inbox=$(cat "$CEO_DIR/inbox.md")
  if [[ "$inbox" == *"[[CEO/reports/token/"* ]]; then
    printf '  FAIL [%s] inbox must NOT have an inbox line when the report write failed\n    inbox: %q\n' \
      "$CURRENT_TEST" "$inbox"
    FAILS=$((FAILS + 1))
  fi
}

run_tests() {
  local count=0
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST="$fn"
    setup
    "$fn"
    teardown
    count=$((count + 1))
  done
  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}

run_tests
