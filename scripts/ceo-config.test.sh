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

test_require_vault_exits_when_unresolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "ceo_require_vault must exit 1 when no source resolves CEO_VAULT"
}

test_require_vault_returns_zero_when_resolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" CEO_VAULT="$TEST_HOME/explicit" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo_require_vault must return 0 when CEO_VAULT resolves"
}

test_ceo_report_fails_loud_on_unresolved_vault() {
  local rc=0 out
  out=$(env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash "$SCRIPT_DIR/ceo-report.sh" intake test-trigger "content" 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo-report.sh must exit 1 when no vault resolves"
  case "$out" in
    *FATAL*) ;;
    *) printf '  FAIL [%s] stderr missing FATAL\n    got: %q\n' "$CURRENT_TEST" "$out"; FAILS=$((FAILS + 1)) ;;
  esac
  if [ -d "$TEST_HOME/empty/Documents/Obsidian/CEO" ]; then
    printf '  FAIL [%s] silent provision under default path\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_ceo_help_works_on_fresh_host() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash "$SCRIPT_DIR/ceo" help >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo help must exit 0 on a host with no CEO_VAULT"
}

test_registry_validate_accepts_integer_current_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":2,"playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "integer schema_version at current version must validate"
}

test_registry_validate_rejects_non_integer_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":1.5,"playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "float schema_version must reject instead of falling through"
}

test_registry_validate_rejects_string_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":"2","playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "string schema_version must reject instead of coercing"
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
