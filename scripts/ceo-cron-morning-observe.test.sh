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

# Round-trip test: predicted block placed AFTER END_LOG_ENTRY (realistic model output).
# Reproduces the production risky case — the block lives outside the log fence.
# Proves the raw-output call site is what makes the ledger capture it.
test_post_fence_predicted_block_captured() {
  setup
  # Raw model output: fenced briefing followed by the predicted block after END_LOG_ENTRY
  local raw_with_post_fence=$'LOG_ENTRY:\n**Status:** ok\n**Summary:** things happened\nEND_LOG_ENTRY\n<!-- CEO-PREDICTED-PRIORITIES\n- o/r#7: Ship\n-->'
  ceo_morning_observe_hook "morning" "$raw_with_post_fence"
  local ledger_content
  ledger_content=$(cat "$CEO_VAULT/CEO/model/2026-06.md" 2>/dev/null || true)
  assert_contains "$ledger_content" "o/r#7" "post-fence predicted item captured in ledger"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# Mutation check: passing only the fenced log_entry (block stripped) yields no predicted bullet.
# This confirms the fix is load-bearing — stripped input fails to populate the ledger.
test_stripped_input_yields_no_predicted_bullet() {
  setup
  # Simulate the old broken behavior: only the log_entry text (block stripped by sed)
  local fenced_only=$'**Status:** ok\n**Summary:** things happened'
  ceo_morning_observe_hook "morning" "$fenced_only"
  local ledger_content
  ledger_content=$(cat "$CEO_VAULT/CEO/model/2026-06.md" 2>/dev/null || true)
  assert_not_contains "$ledger_content" "o/r#7" "stripped input produces no predicted bullet"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# Call-site assertion: ceo_morning_observe_hook in ceo-cron.sh must pass the raw output var.
test_call_site_passes_raw_output() {
  local call_line
  call_line=$(grep 'ceo_morning_observe_hook' "$SCRIPT_DIR/ceo-cron.sh" | grep -v '^#')
  assert_not_contains "$call_line" '"$log_entry"' "call site passes raw output, not log_entry"
  assert_contains "$call_line" '"$output"' "call site passes \$output variable"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
