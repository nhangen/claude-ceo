#!/bin/bash
# Tests for ceo-gather.sh — PR gather degradation observability (#167).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  OLD_HOME="$HOME"
  OLD_PATH="$PATH"
  export HOME="$TMP"
  export CEO_VAULT="$TMP/vault"
  mkdir -p "$CEO_VAULT/CEO/approvals" "$CEO_VAULT/CEO/log"

  mkdir -p "$TMP/.ceo"
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": ["testacct"] }, "gitlab": { "usernames": [] } }
JSON

  mkdir -p "$TMP/bin"
  # glab stub: report unauthenticated so the GitLab block is skipped entirely,
  # keeping the test deterministic regardless of a real glab on the host.
  cat > "$TMP/bin/glab" << 'STUB'
#!/bin/bash
[ "$1" = "auth" ] && [ "$2" = "status" ] && exit 1
exit 1
STUB
  chmod +x "$TMP/bin/glab"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  export HOME="$OLD_HOME"
  export PATH="$OLD_PATH"
  unset CEO_VAULT
  rm -rf "$TMP"
}

# argv-validating gh stub. $1 controls the merged-search body so each test can
# inject a valid or malformed payload; $2 and $3 do the same for the
# review-requested and authored searches, defaulting to empty. Exit 99 on any
# unexpected shape. One copy on purpose: an inlined second stub drifts from
# this one the moment production's search argv changes.
# $4 optionally names one search arm to fail the way a rate limit does, so a
# test can tell a review-search failure from an unrelated one. Kept in this one
# stub rather than a second copy, for the reason above.
_write_gh_stub() {
  local merged_body="$1"
  local review_body="${2:-[]}"
  local authored_body="${3:-[]}"
  local fail_arm="${4:-}"
  local fail_case=""
  case "$fail_arm" in
    '') ;;
    merged)   fail_case='*"--merged"*)' ;;
    review)   fail_case='*"--review-requested"*)' ;;
    authored) fail_case='*"--state open"*"--author"*)' ;;
    *) echo "_write_gh_stub: unknown fail arm '$fail_arm'" >&2; return 1 ;;
  esac
  [ -n "$fail_case" ] && fail_case="$fail_case echo 'gh: API rate limit exceeded' >&2; exit 1 ;;"
  cat > "$TMP/bin/gh" << STUB
#!/bin/bash
case "\$1 \$2" in
  "auth token") echo "ghs_faketoken"; exit 0 ;;
  "auth status") exit 0 ;;
esac
if [ "\$1" = "search" ] && [ "\$2" = "prs" ]; then
  case "\$*" in
    $fail_case
    *"--merged"*)            printf '%s' '$merged_body'; exit 0 ;;
    *"--review-requested"*)  printf '%s' '$review_body'; exit 0 ;;
    *"--state open"*"--author"*) printf '%s' '$authored_body'; exit 0 ;;
  esac
fi
echo "gh stub: unexpected argv: \$*" >&2
exit 99
STUB
  chmod +x "$TMP/bin/gh"
}

_run_gather() {
  # Source in an isolated subshell with set +eu (gather tolerates failures and
  # is sourced by cron without nounset); echo the observability vars.
  ( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "DEGRADED=${PR_GATHER_DEGRADED}|REVIEW_DEGRADED=${PR_REVIEW_GATHER_DEGRADED}|REVIEW_COUNT=${PR_REVIEW_COUNT}|AUTHORED_COUNT=${PR_AUTHORED_COUNT}|MERGED_COUNT=${PR_MERGED_COUNT}|REASONS=${PR_GATHER_DEGRADED_REASONS}" )
}

# _preflight_rc <count> <review-degraded> — the 0/1/2 contract on its own terms.
# Every other arm observes it through two layers of report formatting, where a
# changed exit code and a changed renderer look the same.
_preflight_rc() {
  ( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    PR_REVIEW_COUNT="$1"
    PR_REVIEW_GATHER_DEGRADED="$2"
    # shellcheck disable=SC2034  # read by ceo_pr_review_preflight, sourced above
    PR_REVIEW_GATHER_DEGRADED_REASONS="gh-review-failed:testacct"
    local out rc=0
    out=$(ceo_pr_review_preflight) || rc=$?
    echo "RC=$rc|OUT=$out" )
}

test_preflight_contract_covers_all_three_states() {
  _write_gh_stub '[]'
  assert_contains "$(_preflight_rc 2 0)" "RC=0" "PRs waiting is state 0"
  assert_contains "$(_preflight_rc 0 0)" "RC=1" "a trustworthy empty queue is state 1"
  local degraded; degraded=$(_preflight_rc 0 1)
  assert_contains "$degraded" "RC=2" "an empty queue behind a degraded search is state 2"
  assert_contains "$degraded" "gh-review-failed:testacct" "and state 2 carries the reason"
}

# The carve-out the function documents: a degraded search that still returned PRs
# has work to do. Reordering the two checks inverts that decision, and every
# report-level arm stays green when you do.
test_preflight_prefers_work_present_over_degraded() {
  _write_gh_stub '[]'
  assert_contains "$(_preflight_rc 3 1)" "RC=0" \
    "PRs present outrank a degraded search — there is work either way"
}

# A count that is not a number is not a zero. `[ x -gt 0 ]` is false for both,
# so the fall-through direction decides whether a malformed count reads as a
# trustworthy empty queue or as an unknown one.
test_preflight_treats_a_non_numeric_count_as_unknown() {
  _write_gh_stub '[]'
  assert_contains "$(_preflight_rc 'null' 0)" "RC=2" \
    "a non-numeric review count must be state 2, not a trustworthy empty"
}

# PR_GATHER_DEGRADED is a union over review, authored, merged, GitLab, and every
# jq transform. Consulting it wholesale records a preflight failure -- which
# feeds the fail counter and the alert -- because an unrelated 30-day merged
# search flaked.
test_a_merged_search_failure_does_not_degrade_the_review_queue() {
  _write_gh_stub '[]' '[]' '[]' merged
  local out; out=$(_run_gather)
  assert_contains "$out" "DEGRADED=1" "a failed merged search still degrades the gather overall"
  assert_contains "$out" "REVIEW_DEGRADED=0" \
    "but it says nothing about the review queue, which was searched cleanly"
}

test_a_review_search_failure_degrades_the_review_queue() {
  _write_gh_stub '[]' '[]' '[]' review
  local out; out=$(_run_gather)
  assert_contains "$out" "REVIEW_DEGRADED=1" "a failed review search must degrade the review queue"
}

# The other provider, same shape: configured but unreachable. glab missing, or
# unauthenticated, or an expired token all skip the whole MR block, and without a
# mark the empty result reads as trustworthy.
test_configured_but_unreachable_gitlab_degrades_the_review_queue() {
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": ["testacct"] }, "gitlab": { "usernames": ["gluser"] } }
JSON
  _write_gh_stub '[]'
  local out; out=$(_run_gather)
  assert_contains "$out" "REVIEW_DEGRADED=1" \
    "a configured GitLab source that could not be reached is a degradation, not an empty queue"
}

# gh is authenticated and the account list resolves to nothing, so no search is
# issued at all. Without a mark, the count is 0 and the preflight certifies an
# empty queue it never looked for.
test_no_resolved_accounts_degrades_rather_than_reporting_empty() {
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": [] }, "gitlab": { "usernames": [] } }
JSON
  _write_gh_stub '[]'
  local out; out=$(_run_gather)
  assert_contains "$out" "REVIEW_DEGRADED=1" \
    "a gather that issued no search must not report a trustworthy empty queue"
}

# A jq post-processing failure (malformed payload that the gh call returns with
# exit 0, so the gh-failure branch is NOT taken) must mark the gather degraded —
# otherwise a silently-shrunk PR set reads as a clean all-clear.
test_jq_postprocessing_failure_marks_degraded() {
  _write_gh_stub 'this is not valid json'
  local out; out=$(_run_gather)
  assert_contains "$out" "DEGRADED=1" "a jq post-processing failure must set PR_GATHER_DEGRADED (#167)"
}

# The complement: a fully-valid gather must NOT mark degraded — guards the fix
# against falsely flagging every run.
test_clean_gather_not_degraded() {
  _write_gh_stub '[]'
  local out; out=$(_run_gather)
  assert_contains "$out" "DEGRADED=0" "a clean gather must leave PR_GATHER_DEGRADED unset"
}

# Gather's PR count feeds preflight_has_prs_to_review, and a miscount there
# silently reads as "no work" rather than as an error -- so the parse gets its
# own arm rather than riding on the not-degraded one above.
test_gather_parses_prs_present() {
  local pr_json='[{"number":101,"title":"PR 1","createdAt":"2026-09-01T12:00:00Z","repository":{"nameWithOwner":"org/repo"}}]'
  _write_gh_stub '[]' "$pr_json" "$pr_json"

  local out; out=$(_run_gather)
  assert_contains "$out" "DEGRADED=0" "successful parse of PRs must not be degraded"
  assert_contains "$out" "REVIEW_COUNT=1" "review count must reflect parsed PRs"
  assert_contains "$out" "AUTHORED_COUNT=1" "authored count must reflect parsed PRs"
}

run_tests
