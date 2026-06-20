#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

test_pregathered_emits_new_signals_when_inputs_list_them() {
  # Source the LIB (Task 0), not ceo-cron.sh (which runs dispatch on source).
  # _inputs_includes reads the module-scope INPUTS_JSON; set it directly.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-cron-lib.sh"
  INPUTS_JSON='["current_sprint","yesterday_merged","ledger_recent"]'
  export CURRENT_SPRINT_ITEMS='[{"number":7,"repo":"o/r","title":"S"}]'
  export CURRENT_SPRINT_COUNT=1
  export YESTERDAY_MERGED='[{"number":7,"repo":"o/r"}]'
  export LEDGER_RECENT="predicted today: o/r#7"
  block=$(ceo_build_pregathered_extras)   # helper extracted for testability
  assert_contains "$block" "Current sprint" "sprint line emitted"
  assert_contains "$block" '"number":7' "sprint items present"
  assert_contains "$block" "Yesterday merged" "yesterday-merged line emitted"
  assert_contains "$block" "model ledger" "ledger line emitted"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
