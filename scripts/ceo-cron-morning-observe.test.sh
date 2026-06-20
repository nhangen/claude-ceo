#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d); export CEO_VAULT="$TMP/v"; mkdir -p "$CEO_VAULT/CEO/model"
  export TODAY="2026-06-20"
  ENTRY_OUT=$'**Status:** ok\n<!-- CEO-PREDICTED-PRIORITIES\n- o/r#7: Ship\n-->'
  # Source the LIB (Task 0), not ceo-cron.sh.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-cron-lib.sh"
  export SCRIPT_DIR  # ceo_morning_observe_hook resolves ceo-observe.sh via it
}
teardown() { rm -rf "$TMP"; unset CEO_VAULT TODAY; }

test_morning_hook_writes_ledger_entry() {
  setup
  ceo_morning_observe_hook "morning" "$ENTRY_OUT"
  assert_file_exists "$CEO_VAULT/CEO/model/2026-06.md" "ledger month file created"
  assert_contains "$(cat "$CEO_VAULT/CEO/model/2026-06.md")" "2026-06-20" "dated entry written"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_non_morning_trigger_is_noop() {
  setup
  ceo_morning_observe_hook "morning-brief" "$ENTRY_OUT"
  assert_fails "no ledger write for non-morning trigger" test -f "$CEO_VAULT/CEO/model/2026-06.md"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
