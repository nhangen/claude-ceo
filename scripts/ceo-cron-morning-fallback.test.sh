#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

test_raw_digest_helper_emits_signals_when_synthesis_empty() {
  # Source the LIB (Task 0), not ceo-cron.sh.
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-cron-lib.sh"
  CURRENT_SPRINT_ITEMS='[{"number":7,"repo":"o/r","title":"Sprint Y"}]'
  PR_REVIEW_REQUESTED='[]'; DAILY_NOTE_TOP3="Write spec"
  out=$(ceo_morning_raw_digest)
  assert_contains "$out" "Sprint Y" "digest includes sprint item"
  assert_contains "$out" "Write spec" "digest includes Top 3"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
