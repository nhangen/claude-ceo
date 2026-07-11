#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-tier-lib.sh"

setup() {
  CEO_TIER_MAP="$(mktemp)"
  export CEO_TIER_MAP
  cat > "$CEO_TIER_MAP" <<'JSON'
{
  "shapes": [
    {"name": "read-only-lookup", "match_pattern": "^(find|locate)\\b", "allowed_subagent_types": ["general-purpose"], "tier": "haiku"}
  ]
}
JSON
}

teardown() {
  rm -f "$CEO_TIER_MAP"
}

test_match_returns_tier_and_shape() {
  local result
  result=$(ceo_tier_lookup "find the config file" "general-purpose")
  assert_eq "$result" "haiku|read-only-lookup" "matching label+subagent_type returns tier|shape"
}

test_no_match_on_unmatched_label() {
  local result
  result=$(ceo_tier_lookup "refactor the billing module" "general-purpose")
  assert_eq "$result" "" "unmatched label returns empty"
}

test_no_match_on_wrong_subagent_type() {
  local result
  result=$(ceo_tier_lookup "find the config file" "code-reviewer")
  assert_eq "$result" "" "subagent_type not in allowlist returns empty"
}

test_missing_map_file_fails_open() {
  CEO_TIER_MAP="/tmp/ceo-tier-map-does-not-exist-$$.json"
  local result
  result=$(ceo_tier_lookup "find the config file" "general-purpose")
  assert_eq "$result" "" "missing map file returns empty, not an error"
}

run_tests
