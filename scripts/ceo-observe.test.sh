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

test_predicted_block_with_arrow_in_title_not_truncated() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- repo-a#1: Migrate A --> B\n- repo-b#2: Regular item\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_contains "$entry" "repo-a#1" "item with --> in title preserved"
  assert_contains "$entry" "repo-b#2" "subsequent item preserved"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_degraded_actuals_yields_na_hit_rate() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- o/r#7: thing\n-->\n' | \
    YESTERDAY_MERGED_DEGRADED=1 LEDGER_PREV_PREDICTED='["o/r#7"]' YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_contains "$entry" "n/a (actuals unavailable)" "degraded actuals yields n/a not 0/1"
  assert_no_match "$entry" "0/1" "no 0/1 on degraded actuals"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_empty_prev_predicted_yields_na_hit_rate() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- o/r#9: Thing\n-->\n' | \
    YESTERDAY_MERGED='[{"number":9,"repo":"o/r"}]' LEDGER_PREV_PREDICTED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_contains "$entry" "yesterday hit-rate: n/a" "empty prev-predicted yields n/a not 0/0"
  assert_no_match "$entry" "0/0" "no 0/0 on first run"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_denylist_metachar_is_matched_literally() {
  # The awk extractor strips ': description' leaving bare repo#num.
  # Denylist term with a regex metachar like 'a[cme/repo' must match literally
  # against 'a[cme/repo#1' without crashing grep or wiping all predictions.
  setup
  mkdir -p "$CEO_VAULT/Profile"
  printf 'a[cme/repo\n' > "$CEO_VAULT/Profile/discretion-denylist.txt"
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- a[cme/repo#1: sensitive item\n- legit/repo#2: regular item\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "a\[cme" "metachar term scrubbed"
  assert_contains "$entry" "legit/repo#2" "non-matching item preserved"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_denylist_file_scrubs_matching_term() {
  setup
  mkdir -p "$CEO_VAULT/Profile"
  printf 'SecretClient\n' > "$CEO_VAULT/Profile/discretion-denylist.txt"
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- altamira/repo#1: SecretClient#1: confidential\n- public/repo#2: visible work\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "SecretClient" "denylist file term scrubbed"
  assert_contains "$entry" "public/repo#2" "non-matching item preserved"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_non_matching_denylist_leaves_predictions_intact() {
  setup
  mkdir -p "$CEO_VAULT/Profile"
  printf 'NOMATCH_TERM\n' > "$CEO_VAULT/Profile/discretion-denylist.txt"
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- visible/repo#1: visible item 1\n- visible/repo#2: visible item 2\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_contains "$entry" "visible/repo#1" "first item preserved"
  assert_contains "$entry" "visible/repo#2" "second item preserved"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
