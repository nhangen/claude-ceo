#!/bin/bash
# Self-contained test harness for ceo-value-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER="$SCRIPT_DIR/ceo-value-tracker.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  
  mkdir -p "$TEST_HOME/.bun/bin"
  
  # Stub bun
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
echo "bun-stub: $*"
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  # Stub cli.ts so file exists check passes
  mkdir -p "$REPO_ROOT/lib/value-tracker/src"
  touch "$REPO_ROOT/lib/value-tracker/src/cli.ts"

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

test_appends_inbox_line_and_invokes_bun() {
  local output
  output=$(bash "$TRACKER" 2>&1)
  
  local today inbox count
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  
  assert_file_exists "$inbox" "per-host inbox shadow file must be created"
  count=$(grep -c -F "[[Projects/Development/nhangen/claude-ceo/value-tracker/$today]]" "$inbox" || true)
  assert_eq "$count" "1" "per-host inbox must contain wikilink"
  
  assert_contains "$output" "bun-stub:" "script must invoke bun"
  assert_contains "$output" "--obsidian-vault $CEO_VAULT" "bun invocation must pass obsidian-vault"
}

test_idempotent_inbox_append() {
  bash "$TRACKER" >/dev/null 2>&1
  bash "$TRACKER" >/dev/null 2>&1
  
  local today inbox count
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  
  count=$(grep -c -F "[[Projects/Development/nhangen/claude-ceo/value-tracker/$today]]" "$inbox" || true)
  assert_eq "$count" "1" "two runs must leave exactly one inbox line"
}

test_exits_nonzero_when_bun_fails() {
  cat > "$TEST_HOME/.bun/bin/bun" << 'STUB'
#!/bin/bash
exit 7
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"
  
  local rc=0
  bash "$TRACKER" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero when bun exits non-zero\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  
  local inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  if [ -f "$inbox" ] && grep -qF "[[Projects/Development/nhangen/claude-ceo/value-tracker/" "$inbox"; then
    printf '  FAIL [%s] inbox must NOT have a line when bun failed\n' "$CURRENT_TEST"
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
