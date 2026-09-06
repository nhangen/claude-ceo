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
_write_gh_stub() {
  local merged_body="$1"
  local review_body="${2:-[]}"
  local authored_body="${3:-[]}"
  cat > "$TMP/bin/gh" << STUB
#!/bin/bash
case "\$1 \$2" in
  "auth token") echo "ghs_faketoken"; exit 0 ;;
  "auth status") exit 0 ;;
esac
if [ "\$1" = "search" ] && [ "\$2" = "prs" ]; then
  case "\$*" in
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
    echo "DEGRADED=${PR_GATHER_DEGRADED}|REVIEW_COUNT=${PR_REVIEW_COUNT}|AUTHORED_COUNT=${PR_AUTHORED_COUNT}|MERGED_COUNT=${PR_MERGED_COUNT}|REASONS=${PR_GATHER_DEGRADED_REASONS}" )
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
