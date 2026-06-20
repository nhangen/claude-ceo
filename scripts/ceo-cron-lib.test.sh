#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ceo-cron-lib.sh"   # MUST be safe to source (no dispatch)

test_inputs_includes_reads_inputs_json() {
  INPUTS_JSON='["current_sprint","daily_note"]'
  _inputs_includes current_sprint && r1=0 || r1=1
  _inputs_includes nope && r2=0 || r2=1
  assert_eq "$r1" "0" "present key returns 0"
  assert_eq "$r2" "1" "absent key returns 1"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inputs_includes_defaults_all_when_null() {
  INPUTS_JSON="null"
  _inputs_includes anything && r=0 || r=1
  assert_eq "$r" "0" "null inputs → default-all (returns 0)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
