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

  # The four window dates main() computes are relative to *now*, not to
  # CEO_ANALYTICS_TODAY, so fixtures have to be keyed on whatever `_days_ago`
  # actually returns today. This used to re-derive "-9d"/"-16d" by hand
  # instead of calling `_days_ago` — a silent second copy of the arithmetic
  # that could drift from the real one, and did nothing to pin cur_end/
  # prior_end at all (see _fixture below). Source the real helper instead of
  # re-implementing the BSD/GNU probe.
  CUR_END=$(_source_analytics _days_ago "$CEO_ANALYTICS_LAG_DAYS")
  CUR_START=$(_source_analytics _days_ago $((CEO_ANALYTICS_LAG_DAYS + 6)))
  PRIOR_END=$(_source_analytics _days_ago $((CEO_ANALYTICS_LAG_DAYS + 7)))
  PRIOR_START=$(_source_analytics _days_ago $((CEO_ANALYTICS_LAG_DAYS + 13)))
}

teardown() {
  export HOME="$HOME_BACKUP"
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
}

# _fixture <site-slug> <window: cur|prior> <dim> <rows...>
# Filename carries both start AND end date — _gsc_query's fixture path used to
# key on start+dim only, so mutating cur_end/prior_end (a wrong comparison
# window) never missed a fixture and every arm stayed green. See the header
# comment on _gsc_query in ceo-analytics.sh.
_fixture() {
  local slug="$1" window="$2" dim="$3"; shift 3
  local start end
  if [ "$window" = cur ]; then start="$CUR_START"; end="$CUR_END"
  else start="$PRIOR_START"; end="$PRIOR_END"
  fi
  printf '%s\n' "$@" > "$FIXTURES/$slug-$start-$end-$dim.tsv"
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

# Same idea as _ctr_section: a URL excluded from "Pages losing clicks" can
# legitimately still show up under "Pages with impressions and zero clicks"
# (they are different findings on the same page), so a whole-report
# assert_not_contains proves nothing specific to the decline finder.
_clicks_lost_section() {
  printf '%s\n' "$OUT" | sed -n '/Pages losing clicks/,/^###/p'
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
  # This pins the behaviour, not a particular line: `[ -n "$p" ] || continue`
  # and the `[ "$d" -lt 0 ] || continue` below it both exclude a page absent
  # from the prior window, since an empty prior coerces to 0 and clicks are
  # never negative. The first guard is the explicit statement of the rule and
  # stays; do not read this arm as proof that deleting it would be caught.
  _empty_all
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/brand-new\t5\t100\t0.05\t12')"
  _fixture httpsshoptest prior page ""
  _run
  assert_not_contains "$OUT" "p/brand-new — 5 clicks" \
    "absent from the prior window means new, not a fall from zero"
}

# --- T2: the comparison window itself has coverage, not just its fixtures --

test_the_report_header_states_the_actual_comparison_window() {
  # cur_end/prior_end had no coverage at all: the fixture path used to key on
  # start+dim only, so `cur_end=$(_days_ago 0)` (today instead of the lagged
  # end) or a prior_end overlapping the current window both still resolved to
  # the same fixture and left every arm green. Pinning the exact window
  # string in the header catches either mutation directly.
  _empty_all
  _run
  assert_contains "$OUT" "This week $CUR_START → $CUR_END, compared against $PRIOR_START → $PRIOR_END." \
    "the header states the exact four-date window the run computed"
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
  newsec=$(printf '%s\n' "$OUT" | sed -n '/New queries this week/,/^## \|^### Pages/p')
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
  # The ranking claim was narrowed in the playbook and the script header but
  # not, for three rounds, in the sentence a human actually reads. Two of the
  # four sections sort on impressions and print no rank at all, so an
  # unqualified "findings are ordered by revenue rank" is false in the
  # artifact even while both docs are correct.
  assert_contains "$OUT" "query-dimension findings are ordered by impressions" \
    "the report scopes its ranking claim to the sections that actually rank"
}

test_a_dry_run_writes_nothing_to_the_vault() {
  _empty_all
  _run
  assert_eq "$(ls "$CEO_VAULT/CEO/reports/analytics"/*.md 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "--dry-run prints the report and leaves the vault alone"
}

test_a_dry_run_creates_no_vault_directory_either() {
  # The .md-count check above passes even if `mkdir -p "$REPORT_DIR"` ran
  # before the --dry-run return, since an empty directory still globs to
  # zero files. Pin the directory itself: a dry run must not touch the
  # filesystem at all, not just "not write the report file."
  _empty_all
  rm -rf "$CEO_VAULT/CEO/reports"
  _run
  assert_eq "$([ -d "$CEO_VAULT/CEO/reports/analytics" ] && echo exists || echo absent)" "absent" \
    "--dry-run must not create the reports/analytics directory"
}

test_a_real_run_writes_the_declared_artifact_path() {
  _empty_all
  OUT=$(bash "$ANALYTICS" 2>/dev/null); RC=$?
  assert_eq "$RC" "0" "the run succeeds"
  assert_file_exists "$CEO_VAULT/CEO/reports/analytics/$CEO_ANALYTICS_TODAY.md" \
    "written where the playbook's artifact: field declares (the playbook is status: draft, so ceo doctor does not cross-check this yet)"
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

test_a_new_query_that_is_a_suffix_of_an_old_one_is_still_new() {
  # The membership test used to be an unanchored `grep -qF`, so a new query
  # that appeared inside last week's longer query read as returning and was
  # dropped. On a store where "bpc-157" and "buy bpc-157" both rank, that is
  # the ordinary shape of the data rather than an edge case.
  _empty_all
  _fixture httpsshoptest cur   query "$(printf 'alpha peptide\t3\t500\t0.006\t12')"
  _fixture httpsshoptest prior query "$(printf 'buy alpha peptide\t9\t400\t0.02\t9')"
  _run
  local newsec
  newsec=$(printf '%s\n' "$OUT" | sed -n '/New queries this week/,/^## \|^### Pages/p')
  assert_contains "$newsec" 'alpha peptide' \
    "a query is new unless last week carried that exact query"
}

test_a_query_just_under_the_impression_floor_is_not_a_ctr_opportunity() {
  # The floor was pinned only from the qualifying side, so loosening it to
  # i>=0 kept every arm green and a query with three impressions would have
  # been reported as a title/meta opportunity.
  _empty_all
  _fixture httpsshoptest cur query "$(printf 'barely seen\t0\t99\t0.0\t8')"
  _run
  assert_not_contains "$(_ctr_section)" 'barely seen' \
    "99 impressions is below the floor — there is nothing to conclude from it"
}

test_a_query_at_the_ctr_ceiling_is_not_an_opportunity() {
  # Same one-sided problem on the CTR side: ctr<1 passed every arm.
  _empty_all
  _fixture httpsshoptest cur query "$(printf 'already converting\t60\t1000\t0.06\t8')"
  _run
  assert_not_contains "$(_ctr_section)" 'already converting' \
    "6% CTR is not a weak click rate — the list is for the ones people skip"
}

test_a_page_just_under_the_zero_click_floor_is_not_reported() {
  _empty_all
  _fixture httpsshoptest cur page "$(printf 'https://shop.test/p/faint\t0\t49\t0.0\t30')"
  _run
  assert_not_contains "$OUT" "p/faint" \
    "49 impressions with no clicks is noise, not a listing people refuse"
}

test_a_row_with_a_null_metric_field_is_dropped_not_misread() {
  # Tab is IFS whitespace, so `IFS=$'\t' read` collapses a *consecutive* tab
  # pair and every field after it shifts left. A row with an empty clicks
  # field ("page\t\t500\t0.01\t7") used to be read as clicks=500 — the
  # impressions figure reported as a click count. The fix rejects the row
  # outright rather than half-reading it, so this must produce no finding at
  # all: not the real numbers, and not the fabricated ones either.
  _empty_all
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/broken\t\t500\t0.01\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/broken\t900\t950\t0.95\t2')"
  _run
  assert_not_contains "$OUT" "https://shop.test/p/broken" \
    "a malformed row is dropped, not reported with shifted fields"
  assert_not_contains "$OUT" "500 clicks" \
    "the impressions figure must never be printed as a click count"
}

# --- T4: _valid_rows only had coverage for a null-clicks-field shape -------

test_a_row_with_too_many_fields_is_rejected() {
  # Every malformed fixture elsewhere in this suite is the same shape (a null
  # clicks field, still 5 tab-separated fields). A row SHORTER than 5 fields
  # is not actually a distinct case for `NF != 5`: awk reads a missing
  # trailing field as empty, and empty already fails every numeric check
  # below it (`https://shop.test/p/short\t5\t100` is caught by the $4 check
  # alone, with or without the NF guard — confirmed by running the reduced
  # awk program both ways). A row LONGER than 5 fields is the one shape only
  # `NF != 5` catches: fields 2-5 all look valid, so nothing else rejects it,
  # and removing that guard left it silently accepted as good.
  _empty_all
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')" \
    "$(printf 'https://shop.test/p/toolong\t5\t100\t0.05\t7\tEXTRA')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_eq "$RC" "0" "one good row alongside an over-long row is not a fatal reject"
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^### Pages losing/p')
  assert_contains "$shopsec" "1 row(s) rejected as malformed" \
    "a row with more than 5 fields is rejected outright, not silently accepted with its extra field ignored"
}

test_a_row_with_non_numeric_impressions_is_rejected() {
  _empty_all
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')" \
    "$(printf 'https://shop.test/p/badimp\t5\tNaN\t0.05\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_eq "$RC" "0" "one good row alongside a bad-impressions row is not a fatal reject"
  assert_not_contains "$OUT" "p/badimp" "a non-numeric impressions field is rejected outright"
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^### Pages losing/p')
  assert_contains "$shopsec" "1 row(s) rejected as malformed" "the bad-impressions row counts as a reject"
}

test_a_row_with_non_numeric_position_is_rejected() {
  _empty_all
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')" \
    "$(printf 'https://shop.test/p/badpos\t5\t100\t0.05\tN/A')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_eq "$RC" "0" "one good row alongside a bad-position row is not a fatal reject"
  assert_not_contains "$OUT" "p/badpos" "a non-numeric position field is rejected outright"
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^### Pages losing/p')
  assert_contains "$shopsec" "1 row(s) rejected as malformed" "the bad-position row counts as a reject"
}

test_a_reject_in_the_prior_query_window_marks_the_new_query_section_unverified() {
  # Rejects are not symmetric. Every other finder loses a finding when a row is
  # dropped, and the site banner ("findings below may be incomplete") is the
  # right warning for that. _new_queries decides "new" by ABSENCE from the
  # prior window, so a dropped prior row promotes a query that ranked last week
  # into a headline — a line that is present and wrong, which "incomplete" does
  # not describe. The prior query window therefore earns its own section note.
  #
  # A second good row in the prior window keeps the reject non-fatal, which is
  # the whole point: the all-rejected case already fails the run, so this
  # partial case is the only one that can still reach the renderer.
  _empty_all
  #
  # Two malformed prior rows, and the count is asserted: matching the sentence
  # alone passes with the number hardcoded, and the number is the disclosure.
  _fixture httpsshoptest prior query "$(printf 'alpha\t5\t400\t\t8\ngamma\t1\t50\t\t11\nbeta\t3\t200\t0.015\t9')"
  _fixture httpsshoptest cur   query "$(printf 'alpha\t9\t100\t0.09\t6\nbeta\t4\t150\t0.026\t9')"
  _run
  assert_contains "$OUT" "2 row(s) of the prior query window were malformed" \
    "the note says how many prior rows were dropped, not merely that some were"
  assert_contains "$OUT" "Treat this section as unverified" \
    "the note says the listed queries may be wrong, not merely missing"
}

test_an_unreadable_prior_window_fails_new_queries_rather_than_fabricating_one() {
  # R2. A hard read failure on the prior window (an unreadable file, not merely
  # a malformed row) must fail rather than read as "this query was not there",
  # which would print every current-week query as new.
  #
  # The caller shape is the whole test, and getting it wrong is why an earlier
  # version of this arm was deleted as vacuous. _render_site invokes the finder
  # as `out_new=$(_new_queries ...) || { ... }` — an assignment on the LEFT of
  # `||`, which suppresses errexit inside the command substitution. Call it any
  # other way and errexit aborts on its own, both versions look identical, and
  # the arm proves nothing. Measured in this shape: with the guard, rc=1 and no
  # output; without it, rc=0 and a fabricated "400  alpha peptide".
  #
  # Run through a child bash rather than _source_analytics, because that
  # helper's own subshell is one of the shapes that hides the difference.
  local probe out; probe=$(mktemp)
  cat > "$probe" <<PROBE
source "$ANALYTICS" >/dev/null 2>&1
d=\$(mktemp -d)
printf 'alpha peptide\t5\t400\t0.0125\t8\n' > "\$d/qc"
: > "\$d/qp"; chmod 000 "\$d/qp"
out_new=\$(_new_queries "\$d/qc" "\$d/qp") || { echo "CAUGHT"; chmod 644 "\$d/qp"; exit 0; }
echo "FABRICATED:[\$out_new]"
chmod 644 "\$d/qp"
PROBE
  out=$(bash "$probe" 2>/dev/null)
  rm -f "$probe"
  assert_eq "$out" "CAUGHT" \
    "an unreadable prior window must fail, not read as 'this query is new'"
}

test_a_row_with_an_empty_key_field_is_rejected_not_shifted() {
  # The last live instance of this file's recurring bug, and the one the
  # consecutive-tab fix did not cover. Tab is IFS whitespace even when IFS is
  # tab, so a LEADING tab is stripped rather than delimited: a row whose key
  # is empty has NF==5 and four numeric metrics, so it passed _valid_rows as
  # good, and every consumer then read clicks as the key and CTR as
  # impressions. The report printed a 500-clicks row as "500 impressions", at
  # exit 0, with no reject and no banner.
  #
  # _gsc_parse_body emits this shape for a Search Console row whose keys array
  # is empty or absent, so it is a live API shape rather than a contrived one.
  _empty_all
  _fixture httpsshoptest cur query "$(printf '\t500\t0.01\t7\t9')"
  _run
  assert_eq "$RC" "1" \
    "an all-empty-key input is every row rejected, which must fail the run"
  assert_not_contains "$OUT" "500" \
    "and a clicks figure is never printed as a query or an impression count"
}

test_a_truncated_new_query_list_says_how_many_it_dropped() {
  # The cap was the one omission in this file with no disclosure, while every
  # other dropped row earns a banner. Three of the four sections are
  # untruncated, so a reader had no way to tell this list was short: 50 new
  # queries rendered as exactly 10 bullets at exit 0, with nothing saying 40
  # were dropped.
  _empty_all
  local rows="" j
  for j in $(seq 1 50); do
    rows="$rows$(printf 'q%02d\t1\t%d\t0.01\t9\n' "$j" $((100 + j)))"$'\n'
  done
  _fixture httpsshoptest cur query "$(printf '%s' "$rows")"
  _run
  assert_eq "$RC" "0" "fifty new queries is a normal week, not a failure"
  assert_contains "$OUT" "50 new queries this week; the 10 with the most impressions are listed" \
    "the report says how many it dropped rather than silently showing ten"
}

# _source_analytics <fn> [args...] — call an internal function of the real
# script in a subshell, sourced rather than executed. A subshell keeps
# `set -euo pipefail`, the EXIT trap, and the top-level config load out of the
# test process; sourcing (not `bash "$ANALYTICS" ...`) is what makes a
# function below main() reachable at all, since main() runs the whole report.
_source_analytics() {
  # shellcheck source=/dev/null
  ( source "$ANALYTICS" >/dev/null 2>&1; "$@" )
}

test_a_200_response_carrying_an_error_body_fails_loudly() {
  # {"error":{...}} on a 200 used to hit `.rows[]?`, which emits nothing and
  # returns 0 — the report then printed "- none" for a query that actually
  # failed, indistinguishable from a real empty week.
  local out err rc
  out=$(_source_analytics _gsc_parse_body '{"error":{"code":403,"message":"quota exceeded"}}' site page 2>/tmp/gsc_err.$$)
  rc=$?
  err=$(cat /tmp/gsc_err.$$); rm -f /tmp/gsc_err.$$
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "an error-carrying body must fail rather than report nothing"
  assert_eq "$out" "" "no rows are emitted from an error body"
  assert_contains "$err" "quota exceeded" "the error message reaches stderr"
}

test_a_legitimate_empty_week_still_succeeds() {
  local out rc
  out=$(_source_analytics _gsc_parse_body '{"rows":[]}' site page)
  rc=$?
  assert_eq "$rc" "0" "rows: [] is a real empty week, not a failure"
  assert_eq "$out" "" "and emits no rows"
}

test_a_body_missing_the_rows_field_entirely_fails_loudly() {
  # Distinct from rows:[] — this shape carries neither an error nor a rows
  # key at all, which is not a week with no data, it's an unrecognized
  # response that must not be read as "nothing happened."
  local err rc
  err=$(_source_analytics _gsc_parse_body '{"unexpected":"shape"}' site page 2>&1 >/dev/null)
  rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a body with no rows field and no error field must still fail"
  assert_contains "$err" "no rows field" "and says why"
}

# _install_curl_stub <log_file> — a curl replacement that records its argv,
# the content of any --config file/fd, and anything piped to it on stdin,
# then returns a canned body. Used to prove a secret reaches curl only via
# stdin/--config and never as a literal argv token (readable via `ps`).
_install_curl_stub() {
  local log="$1"
  STUBDIR=$(mktemp -d)
  cat > "$STUBDIR/curl" <<STUB
#!/bin/bash
{ printf 'ARGV: %s\n' "\$*"; } >> "$log"
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "--config" ]; then
    { echo "CONFIG_START"; cat "\$arg" 2>/dev/null; echo "CONFIG_END"; } >> "$log"
  fi
  prev="\$arg"
done
if printf '%s\n' "\$*" | grep -q -- 'assertion@-'; then
  { echo "STDIN_START"; cat; echo "STDIN_END"; } >> "$log"
fi
case " \$* " in
  *'oauth2.googleapis.com/token'*) printf '%s' '{"access_token":"stub-token-123"}' ;;
  *'searchAnalytics/query'*) printf '%s' '{"rows":[]}' ;;
  *) printf '{}' ;;
esac
STUB
  chmod +x "$STUBDIR/curl"
}

test_the_bearer_token_never_reaches_curls_argv() {
  local log; log=$(mktemp)
  _install_curl_stub "$log"
  ( export PATH="$STUBDIR:$PATH" ACCESS_TOKEN="super-secret-bearer-xyz" \
      CEO_ANALYTICS_FIXTURE_DIR=""
    unset CEO_ANALYTICS_FIXTURE_DIR
    # shellcheck source=/dev/null
    source "$ANALYTICS" >/dev/null 2>&1
    _gsc_query "https://shop.test/" "2026-01-01" "2026-01-07" page >/dev/null
  )
  local recorded; recorded=$(cat "$log")
  rm -rf "$STUBDIR"; rm -f "$log"
  assert_not_contains "$recorded" "super-secret-bearer-xyz -H" \
    "the token must never be adjacent to -H in curl's argv"
  # A plain `assert_not_contains "$recorded" "super-secret-bearer-xyz"` would
  # also match the value inside CONFIG_START/CONFIG_END, which is exactly
  # where it is supposed to live — so assert on the ARGV line alone.
  local argv_line; argv_line=$(printf '%s\n' "$recorded" | grep '^ARGV:')
  assert_not_contains "$argv_line" "super-secret-bearer-xyz" \
    "curl's argv line must not carry the bearer token"
  assert_contains "$recorded" "CONFIG_START" "the header is delivered via --config"
  assert_contains "$recorded" "super-secret-bearer-xyz" \
    "the token is present somewhere (in the config content) — not simply lost"
}

test_the_jwt_assertion_never_reaches_curls_argv() {
  # Sibling to the bearer-token arm above: the signed JWT assertion is the
  # other secret _access_token builds, and it goes to curl via
  # `--data-urlencode assertion@-` on stdin, never `assertion=$assertion` on
  # argv. `_install_curl_stub` already logs stdin whenever argv carries
  # `assertion@-` — that half of the stub existed and nothing asserted
  # against it.
  local keydir keyfile
  keydir=$(mktemp -d)
  openssl genrsa -out "$keydir/key.pem" 2048 >/dev/null 2>&1
  keyfile="$keydir/sa.json"
  jq -Rs --arg email "test@example.iam.gserviceaccount.com" \
    '{client_email: $email, private_key: .}' "$keydir/key.pem" > "$keyfile"

  local log; log=$(mktemp)
  _install_curl_stub "$log"

  # The JWT header segment (`{"alg":"RS256","typ":"JWT"}`, base64url-encoded)
  # is fixed content independent of the key or the clock, so it is a known
  # fragment of whatever assertion this run builds — a probe that doesn't
  # depend on capturing the real, time-varying assertion out of the run.
  local header
  # shellcheck source=/dev/null
  header=$(source "$ANALYTICS" >/dev/null 2>&1; printf '{"alg":"RS256","typ":"JWT"}' | _b64url)

  local token rc
  token=$(
    export PATH="$STUBDIR:$PATH" GA_SERVICE_ACCOUNT_JSON="$keyfile" CEO_ANALYTICS_FIXTURE_DIR=""
    unset CEO_ANALYTICS_FIXTURE_DIR
    # shellcheck source=/dev/null
    source "$ANALYTICS" >/dev/null 2>&1
    _access_token
  )
  rc=$?
  local recorded; recorded=$(cat "$log")
  rm -rf "$STUBDIR" "$keydir"; rm -f "$log"

  assert_eq "$rc" "0" "the token request succeeds against the stub"
  assert_eq "$token" "stub-token-123" "and returns the token from the response"

  local argv_line; argv_line=$(printf '%s\n' "$recorded" | grep '^ARGV:')
  assert_not_contains "$argv_line" "$header" \
    "the assertion's header segment must not appear in curl's argv"
  local stdin_section
  stdin_section=$(printf '%s\n' "$recorded" | sed -n '/^STDIN_START$/,/^STDIN_END$/p')
  assert_contains "$stdin_section" "$header" \
    "the assertion is delivered to curl via stdin (assertion@-), not argv"
}

test_a_malformed_rank_file_fails_the_run_rather_than_truncating_it() {
  # _rank_of returning 0 is also its "unranked" answer, so a rank file that
  # HAS an entry for this url but a garbage rank column must not read the
  # same as "unranked" or "no rank file" — and the failure must actually
  # reach the caller: `while ... done < <(finder)` discards a process
  # substitution's exit status, so a finder that fails partway used to leave
  # the report silently short instead of failing the run.
  _empty_all
  printf 'https://shop.test/p/alpha\tNaN\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_eq "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a non-numeric revenue rank must fail the run, not print a partial report"
}

test_a_non_money_site_never_shows_a_revenue_rank_even_on_a_coincidental_match() {
  # _rank_of used to be called unconditionally, so a page on a non-money site
  # that happens to share a URL with an entry in the (money-site) rank file
  # would print a "revenue rank" suffix right under the disclosure that says
  # findings here are unweighted — the report would contradict itself in the
  # same section. Gate the call on `weighted` instead of hoping for no match.
  _empty_all
  printf 'https://blog.test/post\t3\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsblogtest cur   page "$(printf 'https://blog.test/post\t3\t200\t0.015\t18')"
  _fixture httpsblogtest prior page "$(printf 'https://blog.test/post\t30\t210\t0.14\t17')"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/ignored\t0\t800\t0.0\t11')"
  _run
  local blogsec
  blogsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/blog.test\//,/^## /p')
  assert_contains "$blogsec" "No commerce on this site" "the section still discloses unweighted"
  assert_not_contains "$blogsec" "revenue rank" \
    "no finding in the unweighted section may carry a revenue rank, even on a URL that matches the rank file"
}

# --- T3: _zero_click_pages' weighted gate is unpinned ----------------------

test_a_non_money_sites_zero_click_page_never_shows_a_revenue_rank_either() {
  # The arm above pins the `weighted` gate for _clicks_lost only; calling
  # _rank_of unconditionally inside _zero_click_pages left every existing arm
  # green, because the only zero-click fixture in the suite lives on the
  # money site (where a rank IS wanted). Same coincidental-match shape as
  # above, applied to the zero-click finder instead.
  _empty_all
  printf 'https://blog.test/zero\t2\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsblogtest cur page "$(printf 'https://blog.test/zero\t0\t80\t0.0\t15')"
  _run
  local blogsec
  blogsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/blog.test\//,/^## /p')
  assert_contains "$blogsec" "https://blog.test/zero — 80 impressions, 0 clicks" \
    "the zero-click finding itself still appears"
  assert_not_contains "$blogsec" "revenue rank" \
    "a zero-click page on the unweighted site must not carry a revenue rank either"
}

test_a_money_site_still_keeps_its_revenue_rank_alongside_the_gate() {
  # Companion to the arm above, the other direction: gating on `weighted`
  # must not also silence ranking on the site it's supposed to apply to.
  _empty_all
  printf 'https://shop.test/p/alpha\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^## /p')
  assert_contains "$shopsec" "revenue rank 1" "the money site keeps its rank"
}

test_a_page_gaining_clicks_is_not_reported_as_losing_them() {
  # Pins `[ "$d" -lt 0 ] || continue` in _clicks_lost: a page whose clicks
  # went UP week over week must never appear under "Pages losing clicks".
  # Scoped to that section (T6): removing the ZERO-CLICK guard in a wholly
  # unrelated function (_zero_click_pages) also renders "p/growing" — under a
  # different section — so a whole-report assert_not_contains here used to
  # fail for the wrong reason and wasn't evidence about this guard at all.
  _empty_all
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/growing\t100\t900\t0.11\t5')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/growing\t50\t850\t0.06\t6')"
  _run
  assert_not_contains "$(_clicks_lost_section)" "p/growing" \
    "clicks went from 50 to 100 — a gain, never a decline"
}

test_a_flat_week_page_is_not_reported_as_losing_clicks() {
  # `[ "$d" -lt 0 ]` is the boundary the sibling arm above doesn't reach:
  # delta == 0 (clicks unchanged) is flat, not a decline, and `-le 0` in
  # place of `-lt 0` also passes every existing arm.
  _empty_all
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/flat\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/flat\t40\t900\t0.044\t7')"
  _run
  assert_not_contains "$(_clicks_lost_section)" "p/flat" \
    "clicks unchanged week over week (40 -> 40, delta 0) is flat, not a decline"
}

test_a_page_with_real_clicks_is_not_a_zero_click_finding() {
  # Pins `[ "${c%%.*}" -eq 0 ] ... || continue` in _zero_click_pages: a page
  # with real clicks must never appear in the "impressions and zero clicks"
  # list just because it also has plenty of impressions.
  _empty_all
  _fixture httpsshoptest cur page "$(printf 'https://shop.test/p/converting\t12\t800\t0.015\t9')"
  _run
  assert_not_contains "$OUT" "p/converting" \
    "12 clicks is not zero clicks, regardless of impression volume"
}

test_an_unranked_page_on_the_money_site_shows_no_revenue_rank_suffix() {
  # The rank file exists (so the "unranked" disclosure doesn't fire) and has
  # an entry for a DIFFERENT page, so this page's rank resolves to the
  # sentinel 9999. `[ "$rk" != 9999 ]` is what keeps that sentinel from
  # printing as a literal "revenue rank 9999".
  _empty_all
  printf 'https://shop.test/p/other\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/never-ranked\t5\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/never-ranked\t50\t910\t0.1\t6')"
  _run
  assert_contains "$OUT" "https://shop.test/p/never-ranked — 5 clicks (was 50, -45)" \
    "the finding itself is unaffected"
  assert_not_contains "$OUT" "revenue rank 9999" \
    "the unranked sentinel must never print as a literal rank"
}

test_a_site_with_no_findings_shows_none_for_every_section() {
  _empty_all
  _run
  local shopsec none_count
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^## /p')
  none_count=$(printf '%s\n' "$shopsec" | grep -c '^- none$')
  assert_eq "$none_count" "4" "all four sections report none when there is no data"
}

test_new_queries_are_capped_at_ten_by_impressions() {
  local rows=() i
  for i in 01 02 03 04 05 06 07 08 09 10 11; do
    rows+=("$(printf 'query-%s\t1\t%d\t0.01\t10' "$i" "$((1100 - 10#$i))")")
  done
  _empty_all
  _fixture httpsshoptest cur query "${rows[@]}"
  _run
  local newsec
  newsec=$(printf '%s\n' "$OUT" | sed -n '/New queries this week/,/^## \|^### Pages/p')
  assert_contains "$newsec" "query-01" "the highest-impression query is included"
  assert_not_contains "$newsec" "query-11" \
    "the eleventh query (lowest impressions) is dropped past the cap of 10"
}

test_new_queries_are_ordered_by_impressions_descending() {
  _empty_all
  _fixture httpsshoptest cur query \
    "$(printf 'low volume\t1\t150\t0.01\t10')" \
    "$(printf 'high volume\t2\t900\t0.02\t9')"
  _run
  local newsec low_pos high_pos
  newsec=$(printf '%s\n' "$OUT" | sed -n '/New queries this week/,/^## \|^### Pages/p')
  low_pos=$(printf '%s\n' "$newsec" | grep -n 'low volume' | head -1 | cut -d: -f1)
  high_pos=$(printf '%s\n' "$newsec" | grep -n 'high volume' | head -1 | cut -d: -f1)
  assert_eq "$([ "$high_pos" -lt "$low_pos" ] && echo yes || echo no)" "yes" \
    "the higher-impression new query is listed first"
}

# --- R1: a fully-rejected input must fail the run, not report a clean week --

test_a_fully_rejected_current_window_fails_the_run_rather_than_reporting_clean() {
  # Every row in the current-window page fixture is malformed (a null clicks
  # field). A run that silently drops all of them and prints "- none" is
  # reporting a discarded read as a real quiet week — the exact invariant
  # this fix exists to hold.
  _empty_all
  _fixture httpsshoptest cur page "$(printf 'https://shop.test/p/alpha\t\t900\t0.04\t7')"
  _run
  assert_eq "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a 100%-rejected input must fail the run, not exit clean"
}

test_a_partially_rejected_input_discloses_the_reject_count() {
  # One good row and one malformed row: the run must still succeed (this is
  # not the "every row rejected" case), but the report must say so above the
  # sections rather than silently rendering as if nothing were dropped.
  _empty_all
  #
  # TWO malformed rows, not one, and the count is asserted. An arm that only
  # matches "rejected as malformed" passes with the count hardcoded to any
  # constant, which is the message-not-the-harm shape this suite keeps
  # producing: the banner's whole job is the number.
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')" \
    "$(printf 'https://shop.test/p/broken\t\t500\t0.01\t7')" \
    "$(printf 'https://shop.test/p/short\t5\t100')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_eq "$RC" "0" "one good row alongside two bad ones is not a fatal reject"
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^### Pages losing/p')
  assert_contains "$shopsec" "2 row(s) rejected as malformed" \
    "the banner discloses how many rows were dropped, not merely that some were"
}

test_an_empty_input_is_a_quiet_week_not_a_reject() {
  # The companion boundary: zero rows is not the same as "every row
  # rejected." An empty fixture must succeed with no reject banner at all.
  _empty_all
  _run
  assert_eq "$RC" "0" "an empty week is not a failure"
  assert_not_contains "$OUT" "rejected as malformed" \
    "an empty input never triggers the reject banner — it dropped nothing"
}

# --- R3: the unranked disclosure must reflect what happened, not the file's mere existence ---

test_a_rank_file_present_but_never_matching_is_disclosed_as_unranked() {
  # Sibling to test_a_missing_rank_file_is_disclosed_not_silently_ignored:
  # the file EXISTS this time, but every entry in it is for a different page
  # than anything found this run — the shape of a stale file after a site
  # migration or a truncated edit. Every lookup resolves to the unranked
  # sentinel, and that must be disclosed exactly like a missing file is.
  _empty_all
  printf 'https://shop.test/p/other\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_contains "$OUT" "unranked" \
    "a present-but-never-matching rank file discloses unranked, the same as a missing one"
}

test_a_mix_of_ranked_and_never_sold_pages_does_not_trigger_the_stale_disclosure() {
  # The other direction: a real catalog legitimately has pages that never
  # sold (rank 0) alongside ones that did. That mix must NOT read as a stale
  # file — the disclosure fires only when NOTHING this run matched.
  _empty_all
  printf 'https://shop.test/p/best\t1\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/never-sold\t1\t500\t0.002\t9')" \
    "$(printf 'https://shop.test/p/best\t50\t800\t0.06\t6')"
  _fixture httpsshoptest prior page \
    "$(printf 'https://shop.test/p/never-sold\t90\t520\t0.17\t8')" \
    "$(printf 'https://shop.test/p/best\t60\t810\t0.07\t6')"
  _run
  local shopsec
  shopsec=$(printf '%s\n' "$OUT" | sed -n '/## https:\/\/shop.test\//,/^### Pages losing/p')
  assert_not_contains "$shopsec" "unranked" \
    "one matching page among several is a normal catalog, not a stale file"
}

# --- R7: a page genuinely ranked 9999 is not the unranked sentinel ---

test_a_page_genuinely_ranked_9999_still_shows_its_rank() {
  _empty_all
  printf 'https://shop.test/p/alpha\t9999\n' > "$CEO_ANALYTICS_RANK_FILE"
  _fixture httpsshoptest cur   page "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  _run
  assert_contains "$OUT" "revenue rank 9999" \
    "a real rank of 9999 must print, not be swallowed by the unranked sentinel"
}

# --- R4: a Search Console query failure must include the response body -----

test_a_search_console_query_failure_includes_the_response_body() {
  STUBDIR=$(mktemp -d)
  cat > "$STUBDIR/curl" <<'STUB'
#!/bin/bash
case " $* " in
  *'searchAnalytics/query'*)
    printf '%s' '{"error":{"code":403,"message":"User does not have sufficient permission for site"}}'
    exit 22
    ;;
  *) printf '{}'; exit 22 ;;
esac
STUB
  chmod +x "$STUBDIR/curl"
  local err rc
  err=$(
    export PATH="$STUBDIR:$PATH" ACCESS_TOKEN="tok" CEO_ANALYTICS_FIXTURE_DIR=""
    unset CEO_ANALYTICS_FIXTURE_DIR
    # shellcheck source=/dev/null
    source "$ANALYTICS" >/dev/null 2>&1
    _gsc_query "https://shop.test/" "2026-01-01" "2026-01-07" page 2>&1 >/dev/null
  )
  rc=$?
  rm -rf "$STUBDIR"
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "the query fails"
  assert_contains "$err" "sufficient permission" \
    "the response body — the only thing that distinguishes a permission error from a timeout — reaches the error message"
}

# --- R5: a token-request failure must report Google's error_description ----

test_a_token_request_failure_reports_the_error_description() {
  local keydir keyfile
  keydir=$(mktemp -d)
  openssl genrsa -out "$keydir/key.pem" 2048 >/dev/null 2>&1
  keyfile="$keydir/sa.json"
  # jq -Rs slurps the PEM (with its embedded newlines) into a single JSON string
  # so the key file is valid JSON with the raw PEM as `.private_key`.
  jq -Rs --arg email "test@example.iam.gserviceaccount.com" \
    '{client_email: $email, private_key: .}' "$keydir/key.pem" > "$keyfile"

  STUBDIR=$(mktemp -d)
  cat > "$STUBDIR/curl" <<'STUB'
#!/bin/bash
case " $* " in
  *'oauth2.googleapis.com/token'*)
    printf '%s' '{"error":"invalid_grant","error_description":"Invalid JWT Signature."}'
    exit 22
    ;;
  *) printf '{}'; exit 22 ;;
esac
STUB
  chmod +x "$STUBDIR/curl"
  local err rc
  err=$(
    export PATH="$STUBDIR:$PATH" GA_SERVICE_ACCOUNT_JSON="$keyfile" CEO_ANALYTICS_FIXTURE_DIR=""
    unset CEO_ANALYTICS_FIXTURE_DIR
    # shellcheck source=/dev/null
    source "$ANALYTICS" >/dev/null 2>&1
    _access_token 2>&1 >/dev/null
  )
  rc=$?
  rm -rf "$STUBDIR" "$keydir"
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "the token request fails"
  assert_contains "$err" "Invalid JWT Signature" \
    "Google's error_description reaches the operator instead of being withheld"
}

# --- R6: a missing fixture must fail loudly, not read as an empty week -----

test_a_missing_fixture_fails_loudly_rather_than_reporting_an_empty_week() {
  # The fixture seam is the only ingress the whole suite exercises, so a
  # missing file here (a fixture typo, not a real empty week) must not be
  # indistinguishable from `- none`.
  _empty_all
  rm -f "$FIXTURES/httpsshoptest-$CUR_START-$CUR_END-page.tsv"
  _run
  assert_eq "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a missing fixture must fail the run"
}

# --- R1: the outcome channel reports a degraded (non-fatal) reject ---------

test_a_degraded_run_writes_the_outcome_file_for_ceo_cron() {
  # ceo-cron.sh (:1558) exports CEO_RUNNER_OUTCOME_FILE; this script never
  # wrote to it. A run with disclosed-but-non-fatal rejects should surface
  # itself there so the cron layer notices dropped data without parsing the
  # report body.
  #
  # The expected value is `fired` because that is a word ceo-cron.sh:262-272
  # actually matches — its `case` has arms for `fired` and `noop` and nothing
  # else. This arm previously expected `degraded`, and passed, while the
  # value it asserted fell through cron's `case` to the per-trigger default:
  # a green arm pinning a string no consumer reads.
  _empty_all
  _fixture httpsshoptest cur page \
    "$(printf 'https://shop.test/p/alpha\t40\t900\t0.044\t7')" \
    "$(printf 'https://shop.test/p/broken\t\t500\t0.01\t7')"
  _fixture httpsshoptest prior page "$(printf 'https://shop.test/p/alpha\t100\t1000\t0.1\t6')"
  local outcome_file; outcome_file=$(mktemp)
  rm -f "$outcome_file"
  CEO_RUNNER_OUTCOME_FILE="$outcome_file" _run
  assert_eq "$RC" "0" "a degraded-but-not-fatal run still succeeds"
  assert_eq "$(cat "$outcome_file" 2>/dev/null)" "fired" \
    "the outcome file uses a word ceo-cron actually matches, so the run notifies"
  rm -f "$outcome_file"
}

run_tests
