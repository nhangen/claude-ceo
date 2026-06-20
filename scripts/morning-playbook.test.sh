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
  assert_contains "$body" "sprint" "ranking references sprint"
  assert_contains "$body" "older non-sprint" "states sprint-beats-age rule"
  assert_contains "$body" "CEO-PREDICTED-PRIORITIES" "emits predicted block contract"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
