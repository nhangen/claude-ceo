#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
OBS="$SCRIPT_DIR/ceo-observe.sh"

setup() { TMP=$(mktemp -d); export CEO_VAULT="$TMP/v"; mkdir -p "$CEO_VAULT/CEO/model"; export TODAY="2026-06-20"; }
teardown() { rm -rf "$TMP"; unset CEO_VAULT TODAY; }

test_hit_rate_counts_only_matches() {
  setup
  # shellcheck source=/dev/null
  source "$OBS"
  pred='["o/r#7","o/r#8"]'; actual='[{"number":7,"repo":"o/r"}]'
  assert_eq "$(compute_hit_rate "$pred" "$actual")" "1/2" "1 of 2 predicted merged"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_hit_rate_normalizes_owner_prefix() {
  setup
  # shellcheck source=/dev/null
  source "$OBS"
  pred='["optin-monster-app#42"]'
  actual='[{"number":42,"repo":"awesomemotive/optin-monster-app"}]'
  assert_eq "$(compute_hit_rate "$pred" "$actual")" "1/1" "owner prefix stripped before comparison"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_no_deprioritized_inference() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- o/r#9: Thing\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "deprioritized" "never writes deprioritized/absence inference"
  assert_contains "$entry" "2026-06-20" "dated entry appended"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_discretion_scrub_drops_employer_specifics() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- altamira/secret-contract#1: ACME deal terms\n-->\n' | \
    YESTERDAY_MERGED='[]' CEO_DISCRETION_DENY='ACME' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "ACME" "employer-specific term scrubbed"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
