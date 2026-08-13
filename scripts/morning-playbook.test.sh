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
  # The ZenHub sprint signal is retired: the workspace and its credentials are
  # gone, so the gather helper degraded to `[]` and the injected line carried no
  # data. Matching the bare word, not `current_sprint`, because the residue this
  # caught was prose in Constraints ("Rank by sprint/Top-3 signal") rather than
  # the frontmatter key.
  assert_not_contains "$body" "sprint" "no retired sprint signal"
  assert_contains "$body" "CEO-PREDICTED-PRIORITIES" "emits predicted block contract"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
