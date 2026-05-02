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
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR/reports/token"

  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/rtk" << 'STUB'
#!/bin/bash
echo "rtk-stub: $*"
STUB
  cat > "$TEST_HOME/.bun/bin/token-scope" << 'STUB'
#!/bin/bash
echo "token-scope-stub: $*"
STUB
  chmod +x "$TEST_HOME/.bun/bin/rtk" "$TEST_HOME/.bun/bin/token-scope"

  # Stage a getent stub so ceo_pin_home_or_warn (via ceo_resolve_real_home)
  # resolves to $TEST_HOME instead of the developer's real ~/. Without this,
  # the script's HOME re-export would point PATH augmentation at the user's
  # actual ~/.bun/bin and bypass the test stubs above.
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
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_creates_host_suffixed_report_and_appends_per_host_inbox_line() {
  bash "$INTAKE" >/dev/null 2>&1
  local today report inbox
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  assert_file_exists "$report" "report path must include hostname suffix"
  assert_file_exists "$inbox" "per-host inbox shadow file must be created"
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "per-host inbox must contain wikilink to host-suffixed report"
}

test_does_not_write_to_shared_inbox_md() {
  bash "$INTAKE" >/dev/null 2>&1
  if [ -f "$CEO_DIR/inbox.md" ] && [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] writer must not touch shared CEO/inbox.md\n    contents: %q\n' \
      "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox.md")"
    FAILS=$((FAILS + 1))
  fi
}

test_idempotent_same_day() {
  bash "$INTAKE" >/dev/null 2>&1
  bash "$INTAKE" >/dev/null 2>&1
  local today inbox count
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "two runs must leave exactly one inbox line"
}

test_does_not_re_append_after_inbox_checkoff() {
  bash "$INTAKE" >/dev/null 2>&1
  local today inbox
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  sed -i.bak "s|^- \[ \]|- [x]|" "$inbox"
  rm -f "$inbox.bak"

  bash "$INTAKE" >/dev/null 2>&1
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "checked-off line must not trigger re-append"
}

test_two_hosts_write_disjoint_files() {
  CEO_HOSTNAME="alpha" bash "$INTAKE" >/dev/null 2>&1
  CEO_HOSTNAME="beta"  bash "$INTAKE" >/dev/null 2>&1
  local today
  today=$(date +%Y-%m-%d)
  assert_file_exists "$CEO_DIR/reports/token/$today-alpha.md" "alpha report"
  assert_file_exists "$CEO_DIR/reports/token/$today-beta.md"  "beta report"
  assert_file_exists "$CEO_DIR/inbox/alpha.md" "alpha inbox shadow"
  assert_file_exists "$CEO_DIR/inbox/beta.md"  "beta inbox shadow"
  if [ -f "$CEO_DIR/inbox/beta.md" ] && grep -qF "alpha" "$CEO_DIR/inbox/beta.md"; then
    printf '  FAIL [%s] beta inbox shadow must not reference alpha\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_invokes_ceo_augment_path() {
  # Keep the getent stub on PATH so ceo_pin_home_or_warn resolves to
  # $TEST_HOME instead of the developer's real ~/. Without it, dscl on Mac
  # would return the real user's home and PATH augmentation would prefer the
  # real ~/.bun/bin/rtk over the test stub.
  PATH="$TEST_HOME/stubs:/usr/bin:/bin" bash "$INTAKE" >/dev/null 2>&1
  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  assert_file_exists "$report" "report file must exist"
  body=$(cat "$report")
  assert_contains "$body" "rtk-stub:" "report must contain stub rtk output (proves ceo_augment_path resolved \$HOME/.bun/bin)"
}

test_pins_home_to_resolved_user_home_before_capture() {
  local pinned="$TEST_HOME/pinned-home"
  mkdir -p "$pinned/.bun/bin"
  cat > "$pinned/.bun/bin/rtk" << 'STUB'
#!/bin/bash
echo "rtk-saw-HOME=$HOME"
STUB
  chmod +x "$pinned/.bun/bin/rtk"
  cp "$TEST_HOME/.bun/bin/token-scope" "$pinned/.bun/bin/token-scope"

  local stub_dir="$TEST_HOME/stubs" user
  mkdir -p "$stub_dir"
  user=$(id -un)
  cat > "$stub_dir/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$pinned"
  exit 0
fi
exit 1
EOF
  chmod +x "$stub_dir/getent"

  local sandbox="$TEST_HOME/scrubbed"
  mkdir -p "$sandbox"
  HOME="$sandbox" PATH="$stub_dir:$TEST_HOME/.bun/bin:/usr/bin:/bin" \
    bash "$INTAKE" >/dev/null 2>&1

  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  if [ ! -f "$report" ]; then
    printf '  FAIL [%s] report missing at %q\n' "$CURRENT_TEST" "$report"
    FAILS=$((FAILS + 1)); return
  fi
  body=$(cat "$report")
  assert_contains "$body" "rtk-saw-HOME=$pinned" \
    "rtk must see HOME=$pinned (resolver target), not the sandbox HOME the caller passed"
}

test_aborts_on_unwritable_report_dir() {
  if [ "$(id -u)" = "0" ]; then
    return 0
  fi
  chmod 0500 "$CEO_DIR/reports/token"
  local rc=0
  bash "$INTAKE" >/dev/null 2>&1 || rc=$?
  chmod 0700 "$CEO_DIR/reports/token"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero on unwritable report dir (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$CEO_DIR/inbox/$CEO_HOSTNAME.md" ] && grep -qF "[[CEO/reports/token/" "$CEO_DIR/inbox/$CEO_HOSTNAME.md"; then
    printf '  FAIL [%s] per-host inbox must NOT have an inbox line when the report write failed\n' "$CURRENT_TEST"
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
