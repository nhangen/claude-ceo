#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
PB="$SCRIPT_DIR/../docs/playbooks/morning.md"

test_frontmatter_and_contract_present() {
  body=$(cat "$PB")
  assert_contains "$body" "name: morning" "name set"
  assert_contains "$body" "tier: read" "read tier"
  assert_contains "$body" "Daily note Top 3\` as the primary key" "ranking keys on Top 3"
  assert_contains "$body" "Never rank by age alone" "states not-by-age rule"
  # The retired ZenHub sprint signal must not come back: `current_sprint` was
  # never in ceo-cron.sh's injection vocabulary, so ranking on it silently
  # never worked. Asserted absent so a re-add fails here, not in production.
  assert_not_contains "$body" "current_sprint" "no retired sprint input"
  assert_contains "$body" "CEO-PREDICTED-PRIORITIES" "emits predicted block contract"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
