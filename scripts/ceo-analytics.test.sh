#!/bin/bash
# Tests for ceo-analytics.sh — the report logic, exercised through the real
# entry point with the Search Console call replaced by recorded fixtures.
#
# The fixture seam sits at _gsc_query, so ranking, delta detection, thresholds
# and rendering under test are the same code paths production runs. Nothing here
# stubs the logic it is checking.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANALYTICS="$SCRIPT_DIR/ceo-analytics.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_VAULT/CEO"
  touch "$CEO_VAULT/CEO/inbox.md"   # satisfies ceo_validate_vault

  export CEO_ANALYTICS_TODAY="2026-08-14"
  export CEO_ANALYTICS_SITES="https://shop.test/,https://blog.test/"
  export CEO_ANALYTICS_MONEY_SITE="https://shop.test/"
  export CEO_ANALYTICS_LAG_DAYS=3

  FIXTURES="$TEST_HOME/fixtures"
  mkdir -p "$FIXTURES"
  export CEO_ANALYTICS_FIXTURE_DIR="$FIXTURES"

  export CEO_ANALYTICS_RANK_FILE="$TEST_HOME/product-revenue.tsv"

  # Window starts the script will compute from CEO_ANALYTICS_TODAY is relative to
  # *now*, not to that variable, so resolve them the same way the script does and
  # name the fixtures accordingly.
  if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    CUR_START=$(date -v-9d +%Y-%m-%d);  PRIOR_START=$(date -v-16d +%Y-%m-%d)
  else
    CUR_START=$(date -d '9 days ago' +%Y-%m-%d); PRIOR_START=$(date -d '16 days ago' +%Y-%m-%d)
  fi
}

teardown() {
  export HOME="$HOME_BACKUP"
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
}

# _fixture <site-slug> <window: cur|prior> <dim> <rows...>
_fixture() {
  local slug="$1" window="$2" dim="$3"; shift 3
  local start; [ "$window" = cur ] && start="$CUR_START" || start="$PRIOR_START"
  printf '%s\n' "$@" > "$FIXTURES/$slug-$start-$dim.tsv"
}

_run() {
  OUT=$(bash "$ANALYTICS" --dry-run 2>/dev/null)
  RC=$?
}

# A query excluded from the CTR list still legitimately shows up under "new
# queries", so a whole-report assert_not_contains passes or fails for the wrong
# reason. Scope the negative to the section under test.
_ctr_section() {
  printf '%s\n' "$OUT" | sed -n '/Title\/meta opportunities/,/^###/p'
}

# Every site needs all four fixtures or the run reports on empty input, which
# would make an assertion about "none" pass for the wrong reason.
_empty_all() {
  local slug
  for slug in httpsshoptest httpsblogtest; do
    _fixture "$slug" cur page ""; _fixture "$slug" prior page ""
    _fixture "$slug" cur query ""; _fixture "$slug" prior query ""
  done
}

test_a_page_losing_clicks_is_reported_with_its_revenue_rank() {
  _empty_all
  printf 'https://shop.test/p/alpha\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7.1')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6.4')"
  _run
  assert_eq "$RC" "0" "dry run exits clean"
  assert_contains "$OUT" "https://shop.test/p/alpha — 40 clicks (was 100, -60)" \
    "the decline is reported with both windows and the delta"
  assert_contains "$OUT" "revenue rank 1" "and carries the page's revenue rank"
}

test_a_best_seller_outranks_an_unranked_page_in_the_decline_list() {
  _empty_all
  printf 'https://shop.test/p/best\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/never-sold\t1\t500\t0.002\t9')" \
    "$(printf 'https://shop.test/p/best\t50\t800\t0.06\t6')"
  _fixture httpsshoptest prior page \
    "$(printf 'https://shop.test/p/never-sold\t90\t520\t0.17\t8')" \
    "$(printf 'https://shop.test/p/best\t60\t810\t0.07\t6')"
  _run
  # The unranked page lost 89 clicks and the best seller only 10, so an
  # impressions- or delta-ordered list would invert this. Revenue rank wins.
  local best_pos unranked_pos
  best_pos=$(printf '%s\n' "$OUT" | grep -n 'p/best' | head -1 | cut -d: -f1)
  unranked_pos=$(printf '%s\n' "$OUT" | grep -n 'p/never-sold' | head -1 | cut -d: -f1)
  assert_eq "$([ "$best_pos" -lt "$unranked_pos" ] && echo yes || echo no)" "yes" \
    "the revenue-ranked page is listed before the unranked one despite a smaller drop"
}

test_a_page_new_this_week_is_not_counted_as_a_decline() {
  _empty_all
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/brand-new\t5\t100\t0.05\t12')"
  _fixture httpsshoptest prior page ""
  _run
  assert_not_contains "$OUT" "p/brand-new — 5 clicks" \
    "absent from the prior window means new, not a fall from zero"
}

test_a_missing_rank_file_is_disclosed_not_silently_ignored() {
  _empty_all
  rm -f "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_contains "$OUT" "unranked" \
    "an unranked run says so — it is otherwise indistinguishable from a ranked one"
}

test_a_ctr_opportunity_in_the_position_band_is_reported() {
  _empty_all
  _fixture httpsshoptest cur query "$(printf 'buy alpha peptide\t4\t2000\t0.002\t8.4')"
  _run
  assert_contains "$OUT" 'buy alpha peptide' "position 8 with 2000 impressions and 0.2% CTR qualifies"
  assert_contains "$OUT" "position 8.4" "and reports the position it sits at"
}

test_a_top_three_query_is_not_a_ctr_opportunity() {
  _empty_all
  _fixture httpsshoptest cur query "$(printf 'alpha peptide\t10\t3000\t0.003\t2.1')"
  _run
  assert_not_contains "$(_ctr_section)" 'alpha peptide' \
    "already in the top 3 — there is no ranking headroom to win"
}

test_a_query_past_position_twenty_is_not_a_ctr_opportunity() {
  _empty_all
  _fixture httpsshoptest cur query "$(printf 'obscure long tail\t0\t4000\t0.0\t44')"
  _run
  assert_not_contains "$(_ctr_section)" 'obscure long tail' "nobody scrolls to position 44"
}

test_a_zero_click_page_is_reported() {
  _empty_all
  _fixture httpsshoptest cur page "$(printf 'https://shop.test/p/ignored\t0\t800\t0.0\t11')"
  _run
  assert_contains "$OUT" "https://shop.test/p/ignored — 800 impressions, 0 clicks" \
    "seen and refused is a distinct finding from losing clicks"
}

test_a_new_query_is_reported_and_a_returning_one_is_not() {
  _empty_all
  _fixture httpsshoptest cur   query \
    "$(printf 'fresh demand\t2\t300\t0.006\t14')" \
    "$(printf 'old demand\t9\t400\t0.02\t9')"
  _fixture httpsshoptest prior query "$(printf 'old demand\t8\t380\t0.02\t9')"
  _run
  local newsec
  newsec=$(printf '%s\n' "$OUT" | sed -n '/New queries in the top 25/,/^## \|^### Pages/p')
  assert_contains "$newsec" 'fresh demand' "a query absent last week is new"
  assert_not_contains "$newsec" 'old demand' "one present last week is not"
}

test_the_non_commerce_site_is_reported_unweighted() {
  _empty_all
  _fixture httpsblogtest cur   page "$(printf 'https://blog.test/post\t3\t200\t0.015\t18')"
  _fixture httpsblogtest prior page "$(printf 'https://blog.test/post\t30\t210\t0.14\t17')"
  _run
  assert_contains "$OUT" "https://blog.test/" "the second site appears"
  assert_contains "$OUT" "No commerce on this site" "and is labelled unweighted"
}

test_the_report_never_claims_revenue_attribution() {
  _empty_all
  _run
  assert_contains "$OUT" "no query is credited with a sale" \
    "the report states the attribution limit rather than leaving it implied"
  assert_not_contains "$OUT" "ROAS" "and never prints a figure the stack cannot support"
}

test_a_dry_run_writes_nothing_to_the_vault() {
  _empty_all
  _run
  assert_eq "$(ls "$CEO_VAULT/CEO/reports/analytics"/*.md 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "--dry-run prints the report and leaves the vault alone"
}

test_a_real_run_writes_the_declared_artifact_path() {
  _empty_all
  OUT=$(bash "$ANALYTICS" 2>/dev/null); RC=$?
  assert_eq "$RC" "0" "the run succeeds"
  assert_file_exists "$CEO_VAULT/CEO/reports/analytics/$CEO_ANALYTICS_TODAY.md" \
    "written where the playbook's artifact: field declares (ceo doctor cross-checks this)"
}

test_the_report_carries_frontmatter() {
  _empty_all
  bash "$ANALYTICS" >/dev/null 2>&1
  local head5
  head5=$(head -5 "$CEO_VAULT/CEO/reports/analytics/$CEO_ANALYTICS_TODAY.md")
  assert_contains "$head5" "type: report" "vault notes carry frontmatter"
}

test_a_missing_credential_fails_loudly_rather_than_reporting_nothing() {
  _empty_all
  unset CEO_ANALYTICS_FIXTURE_DIR
  unset GA_SERVICE_ACCOUNT_JSON
  local err rc
  err=$(bash "$ANALYTICS" --dry-run 2>&1 >/dev/null); rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "no credential is a failure, not an empty report"
  assert_contains "$err" "GA_SERVICE_ACCOUNT_JSON" "and names the variable to set"
  export CEO_ANALYTICS_FIXTURE_DIR="$FIXTURES"
}

run_tests
