#!/bin/bash
# Self-contained test harness. Runs every function named test_*.

set -uo pipefail  # note: no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/count-blessings.sh"
LIB="$SCRIPT_DIR/blessings-lib.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
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

assert_fails() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL [%s] %s (expected non-zero exit)\n' "$CURRENT_TEST" "$msg"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR/cache"
}

teardown() {
  rm -rf "$TEST_HOME"
  unset CEO_VAULT CEO_DIR TEST_HOME
}

test_harness_works() {
  assert_eq "1" "1" "arithmetic still works"
}

# --- runner ---
tests=$(declare -F | awk '{print $3}' | grep '^test_' || true)
for t in $tests; do
  CURRENT_TEST="$t"
  printf 'RUN %s\n' "$t"
  setup
  "$t"
  teardown
done

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%d FAILURE(S)\n' "$FAILS"
  exit 1
fi
printf '\nALL PASS\n'
