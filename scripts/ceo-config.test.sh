#!/bin/bash
# Self-contained test harness for ceo-config.sh.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/ceo-config.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_HOME"
  unset TEST_HOME
}

test_load_config_returns_nonzero_when_unresolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "ceo_load_config must return 1 when no source resolves CEO_VAULT"
}

test_load_config_honors_env_bypass() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" CEO_VAULT="$TEST_HOME/explicit" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
    [ \"\$CEO_VAULT\" = \"$TEST_HOME/explicit\" ]
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "explicit CEO_VAULT in env must short-circuit discovery"
}

test_load_config_finds_legacy_candidate() {
  local rc=0 vault_path
  mkdir -p "$TEST_HOME/Documents/Obsidian/CEO"
  vault_path=$(env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
    echo \"\$CEO_VAULT\"
  " 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "ceo_load_config must succeed when a candidate vault exists"
  assert_eq "$vault_path" "$TEST_HOME/Documents/Obsidian" "must export the discovered vault path"
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
