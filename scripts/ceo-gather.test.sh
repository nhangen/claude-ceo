#!/bin/bash
# Tests for ceo-gather.sh — PR gather degradation observability (#167).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
# Synthetic credentials for redaction tests. None of these are real. The gh
# stub's fake token is assembled at runtime through this helper (#572).
# shellcheck disable=SC1090  # sourced for its fake_token helper
source "$SCRIPT_DIR/fake-credentials.sh"

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
  local FAKE_GITHUB_TOKEN
  FAKE_GITHUB_TOKEN=$(fake_token ghp_)
  cat > "$TMP/bin/gh" << STUB
#!/bin/bash
case "\$1 \$2" in
  "auth token") echo "${FAKE_GITHUB_TOKEN}"; exit 0 ;;
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

_pending_preflight_rc() {
  ( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    # All three are read by ceo_pending_items_preflight, which is sourced above,
    # so the use is invisible to static analysis from here.
    # shellcheck disable=SC2034
    PENDING_ASK_QUESTIONS="$1"
    # shellcheck disable=SC2034
    PENDING_GATHER_DEGRADED="$2"
    # shellcheck disable=SC2034
    PENDING_GATHER_DEGRADED_REASONS="file-read-failed:/path/to/Pending.md:rc=2"
    local out rc=0
    out=$(ceo_pending_items_preflight) || rc=$?
    echo "RC=$rc|OUT=$out" )
}

test_pending_items_preflight_covers_all_three_states() {
  assert_contains "$(_pending_preflight_rc '- [ ] ask Slava' 0)" "RC=0" "pending questions waiting is state 0"
  assert_contains "$(_pending_preflight_rc '' 0)" "RC=1" "a trustworthy empty questions list is state 1"
  local degraded; degraded=$(_pending_preflight_rc '' 1)
  assert_contains "$degraded" "RC=2" "an empty questions list behind a degraded file gather is state 2"
  assert_contains "$degraded" "file-read-failed:/path/to/Pending.md:rc=2" "and state 2 carries the reason"
}

test_pending_items_preflight_prefers_work_present_over_degraded() {
  assert_contains "$(_pending_preflight_rc '- [ ] ask Slava' 1)" "RC=0" \
    "pending questions present outrank a degraded file gather — there is work either way"
}

# The weekly memo (llm-tools#827) treats context as current only when
# CEO_PROFILE_CONTEXT_VERSION=1 is set, so the version must follow the parser's
# verdict: set for current domains, unset when they are withheld.
_write_goals() {
  mkdir -p "$CEO_VAULT/Profile"
  printf -- '---\nactive_domains_as_of: %s\n---\n\n## Active Domains\n\n- Test domain\n' "$1" \
    > "$CEO_VAULT/Profile/goals.md"
}

test_current_profile_context_exports_version_1() {
  _write_goals "$(date +%Y-%m-%d)"
  local out
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "VERSION=${CEO_PROFILE_CONTEXT_VERSION:-unset}|EXPORTED=$(env | grep -c '^CEO_PROFILE_CONTEXT_VERSION=1$')"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
  )
  assert_contains "$out" "VERSION=1|EXPORTED=1" "current canonical domains must export version 1"
  assert_contains "$out" "Test domain" "the content is the canonical section"
}

test_withheld_profile_context_does_not_export_version() {
  _write_goals "2000-01-01"
  local out
  out=$( set +eu
    export CEO_PROFILE_CONTEXT_VERSION=1
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "VERSION=${CEO_PROFILE_CONTEXT_VERSION:-unset}"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
  )
  assert_contains "$out" "VERSION=unset" "stale domains must not claim version 1, even when the caller's env had it"
  assert_contains "$out" "Active domains unavailable" "the withheld message still reaches the prompt"
}

# A crashed context reader (python3 missing, or an exception the parser does not
# catch) must degrade the gather, not abort it: ceo-cron.sh sources this under
# set -e, so an unguarded failure stops every cron playbook (#578).
test_crashed_profile_context_reader_degrades_instead_of_aborting() {
  _write_goals "$(date +%Y-%m-%d)"
  local stub; stub="$TMP/py-stub"
  mkdir -p "$stub"
  # Prints a partial success line before failing, so the exit status, not the
  # output, has to decide.
  printf '#!/bin/sh\ncase "$1" in *ceo-profile-context.py) printf "Canonical active domains (x)\\n"; echo Traceback >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v python3)" > "$stub/python3"
  chmod +x "$stub/python3"
  local out
  out=$( set -euo pipefail
    export CEO_PROFILE_CONTEXT_VERSION=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|VERSION=${CEO_PROFILE_CONTEXT_VERSION-unset}|DEGRADED=$FILE_GATHER_DEGRADED|PENDING=$PENDING_GATHER_DEGRADED"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    echo "STATUS=$CEO_GATHER_STATUS"
  )
  assert_contains "$out" "COMPLETED|VERSION=unset|DEGRADED=1|PENDING=0" "a crashed reader must finish the gather, unset the version, degrade only the file scope, and mark it degraded"
  assert_contains "$out" "Active domains unavailable: context reader failed (rc=1)" "the prompt says the context reader failed and carries the status"
  assert_contains "$out" "profile-context-reader-failed:rc=1" "the degraded reason carries the exit status"
  assert_not_contains "$out" "Canonical active domains (" "a crashed reader's partial output must not survive into the exported content"
  assert_contains "$out" "STATUS=failed" "a degenerate degraded gather must roll up failed, not subtly as empty"
}

# The command-not-found path (python3 missing for the reader, or a shim exiting
# 127) must degrade like every other reader failure (#576 M5): 127 falls through
# no select-exit-code protocol, so a code that special-cases some statuses would
# silently hand an empty read back as a clean pass.
test_python3_not_found_for_reader_degrades_with_rc_127() {
  _write_goals "$(date +%Y-%m-%d)"
  local stub; stub="$TMP/py-stub-127"
  mkdir -p "$stub"
  printf '#!/bin/sh\ncase "$1" in *ceo-profile-context.py) exit 127 ;; esac\nexec "%s" "$@"\n' "$(command -v python3)" > "$stub/python3"
  chmod +x "$stub/python3"
  local out
  out=$( set -euo pipefail
    export CEO_PROFILE_CONTEXT_VERSION=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|VERSION=${CEO_PROFILE_CONTEXT_VERSION-unset}|DEGRADED=$FILE_GATHER_DEGRADED|PENDING=$PENDING_GATHER_DEGRADED"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    echo "STATUS=$CEO_GATHER_STATUS"
    echo "ENV_SETS=$(env | grep -c '^CEO_PROFILE_CONTEXT_VERSION')"
  )
  assert_contains "$out" "COMPLETED|VERSION=unset|DEGRADED=1|PENDING=0" "a reader exiting 127 must finish the gather, unset the version, degrade only the file scope, and mark it degraded"
  assert_contains "$out" "Active domains unavailable: context reader failed (rc=127)" "the prompt says the context reader failed and carries the status"
  assert_contains "$out" "Do not infer current roles or priorities from history." "the fallback tells the model not to guess roles from history"
  assert_contains "$out" "profile-context-reader-failed:rc=127" "the degraded reason carries the exit status"
  assert_not_contains "$out" "Canonical active domains (" "a reader that exits before printing must not read as current context"
  assert_contains "$out" "STATUS=failed" "a degenerate degraded gather must roll up failed, not subtly as empty"
  assert_contains "$out" "ENV_SETS=0" "the version must not merely be emptied from the env; it must be gone"
}

# An unreadable canonical Profile/goals.md (directory where the file should be)
# must degrade the gather exactly like a crashed reader: the reader exits
# non-zero, so gather marks the file scope degraded (#617).
test_unreadable_goals_degrades_the_gather() {
  mkdir -p "$CEO_VAULT/Profile"
  rm -rf "$CEO_VAULT/Profile/goals.md"
  mkdir "$CEO_VAULT/Profile/goals.md"
  local out
  out=$( set -euo pipefail
    export CEO_PROFILE_CONTEXT_VERSION=1
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|VERSION=${CEO_PROFILE_CONTEXT_VERSION-unset}|DEGRADED=$FILE_GATHER_DEGRADED|PENDING=$PENDING_GATHER_DEGRADED"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    echo "STATUS=$CEO_GATHER_STATUS"
  )
  assert_contains "$out" "COMPLETED|VERSION=unset|DEGRADED=1|PENDING=0" "an unreadable goals.md must finish the gather, unset the version, and degrade only the file scope"
  assert_contains "$out" "Active domains unavailable: canonical Profile/goals.md is missing or unreadable" "the prompt withholds the canonical context and names the unreadable source"
  assert_contains "$out" "Do not infer current roles or priorities from history." "the fallback tells the model not to guess roles from history"
  assert_contains "$out" "profile-context-reader-failed" "the degraded reason names the failed reader"
  assert_not_contains "$out" "Canonical active domains (" "an unreadable goals.md must not read as current context"
  assert_contains "$out" "STATUS=failed" "a degenerate degraded gather must roll up failed, not subtly as empty"
}

test_non_utf8_goals_degrades_the_gather_with_the_reader_reason() {
  mkdir -p "$CEO_VAULT/Profile"
  printf -- '---\nactive_domains_as_of: %s\n---\n\n## Active Domains\n\n- \377\376bad\n' "$(date +%Y-%m-%d)" \
    > "$CEO_VAULT/Profile/goals.md"
  local out
  out=$( set -euo pipefail
    export CEO_PROFILE_CONTEXT_VERSION=1
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|VERSION=${CEO_PROFILE_CONTEXT_VERSION-unset}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    echo "STATUS=$CEO_GATHER_STATUS"
  )
  assert_contains "$out" "COMPLETED|VERSION=unset|DEGRADED=1" "a non-UTF-8 goals.md must degrade the gather and unset the version"
  assert_contains "$out" "Active domains unavailable: canonical Profile/goals.md is missing or unreadable" "the reader's reason reaches the prompt"
  assert_contains "$out" "profile-context-reader-failed:rc=1" "the degraded reason carries the exit status"
  assert_contains "$out" "STATUS=failed" "a degenerate degraded gather must roll up failed, not subtly as empty"
}

# Legacy Profile.md cannot affect canonical context or the pending queue.
test_legacy_profile_does_not_degrade_the_pending_queue() {
  _write_goals "$(date +%Y-%m-%d)"
  echo "## Active Domains" > "$CEO_VAULT/Profile.md"
  chmod 000 "$CEO_VAULT/Profile.md"
  local out
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    chmod 644 "$CEO_VAULT/Profile.md"
    ceo_pending_items_preflight >/dev/null; rc=$?
    echo "FILE_DEGRADED=${FILE_GATHER_DEGRADED}|RC=$rc"
  )
  assert_contains "$out" "FILE_DEGRADED=0" "legacy Profile.md must not control canonical context"
  assert_contains "$out" "RC=1" "the pending preflight remains a trustworthy empty"
}

test_an_unreadable_pending_file_normalizes_counts_and_degrades() {
  echo "- [ ] test" > "$CEO_VAULT/CEO/approvals/pending.md"
  chmod 000 "$CEO_VAULT/CEO/approvals/pending.md"
  local out
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    chmod 644 "$CEO_VAULT/CEO/approvals/pending.md"
    echo "PENDING_COUNT=${PENDING_COUNT}|APPROVED_COUNT=${APPROVED_COUNT}|FILE_DEGRADED=${FILE_GATHER_DEGRADED}"
  )
  assert_contains "$out" "PENDING_COUNT=0" "an unreadable approvals/pending.md must normalize PENDING_COUNT to 0"
  assert_contains "$out" "APPROVED_COUNT=0" "an unreadable approvals/pending.md must normalize APPROVED_COUNT to 0"
  assert_contains "$out" "FILE_DEGRADED=1" "and mark the file gather degraded"
}

# grep -c prints 0 and exits 1 on a file with no matches; that is a quiet day,
# not a read failure.
test_a_count_with_no_matches_is_zero_not_degraded() {
  _write_goals "$(date +%Y-%m-%d)"
  printf -- '- [x] done one\n- [x] done two\n' > "$CEO_VAULT/CEO/approvals/pending.md"
  local out
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "PENDING_COUNT=${PENDING_COUNT}|APPROVED_COUNT=${APPROVED_COUNT}|FILE_DEGRADED=${FILE_GATHER_DEGRADED}"
  )
  assert_contains "$out" "PENDING_COUNT=0|APPROVED_COUNT=2|FILE_DEGRADED=0" \
    "no unchecked items must count 0 without degrading the gather"
}

test_ceo_branches_preflight_missing_repos_md() {
  rm -f "$CEO_VAULT/CEO/repos.md"
  local out rc=0
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    ceo_ceo_branches_preflight ) || rc=$?
  assert_eq "$rc" "2" "missing repos.md must return 2"
  assert_contains "$out" "repos file missing" "stdout must name missing repos.md"
}

test_ceo_branches_preflight_unreadable_repos_md() {
  echo "| Repo | Local Path | Description |" > "$CEO_VAULT/CEO/repos.md"
  chmod 000 "$CEO_VAULT/CEO/repos.md"
  local out rc=0
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    ceo_ceo_branches_preflight ) || rc=$?
  chmod 644 "$CEO_VAULT/CEO/repos.md"
  assert_eq "$rc" "2" "unreadable repos.md must return 2"
  assert_contains "$out" "cannot read repos file" "stdout must state cannot read repos file"
}

test_ceo_branches_preflight_finds_branch() {
  local repo="$TMP/repo1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "t"
  git -C "$repo" config user.email "t@t"
  git -C "$repo" commit --allow-empty -qm "init" --no-verify
  git -C "$repo" branch -q "ceo/my-branch"
  cat > "$CEO_VAULT/CEO/repos.md" << MD
| Repo | Local Path | Description |
|---|---|---|
| repo1 | $repo | Test repo |
MD
  local out rc=0
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    ceo_ceo_branches_preflight ) || rc=$?
  assert_eq "$rc" "0" "branch present must return 0"
}

test_ceo_branches_preflight_no_branches() {
  local repo="$TMP/repo2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "t"
  git -C "$repo" config user.email "t@t"
  git -C "$repo" commit --allow-empty -qm "init" --no-verify
  cat > "$CEO_VAULT/CEO/repos.md" << MD
| Repo | Local Path | Description |
|---|---|---|
| repo2 | $repo | Test repo |
MD
  local out rc=0
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    ceo_ceo_branches_preflight ) || rc=$?
  assert_eq "$rc" "1" "no branch present must return 1"
}

_branches_preflight() {
  ( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    out=$(ceo_ceo_branches_preflight); echo "RC=$?|$out" )
}

_repo_with_ceo_branch() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "t"
  git -C "$repo" config user.email "t@t"
  git -C "$repo" commit --allow-empty -qm "init" --no-verify
  git -C "$repo" branch -q "ceo/my-branch"
}

# #453 names "a corrupt repo or a permissions failure": a directory git cannot
# read as a repository, not a path that is absent on this host.
test_ceo_branches_preflight_git_error_returns_2() {
  mkdir -p "$TMP/not-a-repo"
  cat > "$CEO_VAULT/CEO/repos.md" << MD
| Repo | Local Path | Description |
|---|---|---|
| badrepo | $TMP/not-a-repo | Not a repo |
MD
  local out; out=$(_branches_preflight)
  assert_contains "$out" "RC=2" "git failing on an existing directory must return 2"
  assert_contains "$out" "git failure checking branches in '$TMP/not-a-repo'" "stdout must name the failing repo"
}

test_ceo_branches_preflight_skips_a_clone_absent_on_this_host() {
  cat > "$CEO_VAULT/CEO/repos.md" << MD
| Repo | Local Path | Description |
|---|---|---|
| gone | /nonexistent/repo/path/xyz | Not cloned here |
MD
  assert_contains "$(_branches_preflight)" "RC=1" \
    "a listed path absent on this host is skipped, as ceo-cleanup.sh does, not a failure"
}

test_ceo_branches_preflight_prefers_work_over_a_failing_repo() {
  mkdir -p "$TMP/not-a-repo"
  _repo_with_ceo_branch "$TMP/repo3"
  cat > "$CEO_VAULT/CEO/repos.md" << MD
| Repo | Local Path | Description |
|---|---|---|
| badrepo | $TMP/not-a-repo | Not a repo |
| repo3 | $TMP/repo3 | Has work |
MD
  assert_contains "$(_branches_preflight)" "RC=0" \
    "a ceo/* branch in a later repo must not be hidden by an earlier repo's failure"
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

# Every reason interpolates an account name from pr-sources.json, so classifying
# by globbing the reason for "review" makes an account called `reviewbot` turn an
# unrelated merged-search flake into a review degradation — the false alarm the
# review-scoped flag exists to prevent, arriving through the fix for it.
test_an_account_named_review_does_not_forge_a_review_degradation() {
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": ["reviewbot"] }, "gitlab": { "usernames": [] } }
JSON
  _write_gh_stub '[]' '[]' '[]' merged
  local out; out=$(_run_gather)
  assert_contains "$out" "DEGRADED=1" "the merged-search failure still degrades the gather"
  assert_contains "$out" "REVIEW_DEGRADED=0" \
    "an account name is not a classification — the review search was clean"
}

# The reason is the payload of state 2. `xargs` is not a trim: it parses shell
# quoting, so an account name containing a quote makes it exit non-zero with
# empty output, and the reason vanishes from inside the command substitution.
test_a_quoted_account_name_does_not_blank_the_reason() {
  _write_gh_stub '[]'
  local out
  out=$( set +eu
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    PR_REVIEW_COUNT=0
    PR_REVIEW_GATHER_DEGRADED=1
    # shellcheck disable=SC2034  # read by ceo_pr_review_preflight, sourced above
    PR_REVIEW_GATHER_DEGRADED_REASONS="gh-review-failed:acc't"
    ceo_pr_review_preflight ) || true   # state 2 is the expected exit here
  assert_contains "$out" "gh-review-failed:acc't" \
    "state 2 must still carry its reason when the account name contains a quote"
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

test_stalled_profile_context_reader_times_out_and_marks_gather_degraded() {
  _write_goals "$(date +%Y-%m-%d)"
  local stub; stub="$TMP/py-stub-timeout"
  mkdir -p "$stub"
  local real_python3; real_python3="$(type -P python3)"
  printf '#!/bin/sh\ncase "$1" in *ceo-profile-context.py) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_python3" > "$stub/python3"
  chmod +x "$stub/python3"
  local out
  out=$(
    set -euo pipefail
    export CEO_PROFILE_CONTEXT_VERSION=1
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|VERSION=${CEO_PROFILE_CONTEXT_VERSION-unset}|DEGRADED=$FILE_GATHER_DEGRADED|PENDING=$PENDING_GATHER_DEGRADED"
    printf 'CONTENT=%s\n' "$ACTIVE_DOMAINS_CONTENT"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    echo "STATUS=$CEO_GATHER_STATUS"
  )
  assert_contains "$out" "COMPLETED|VERSION=unset|DEGRADED=1|PENDING=0" \
    "a timed-out reader must finish the gather, unset version, degrade only the file scope, and mark degraded (#594)"
  assert_contains "$out" "profile-context-reader-failed:rc=124" \
    "the degraded reason carries timeout rc 124"
  assert_contains "$out" "STATUS=failed" \
    "a degenerate degraded gather must roll up failed, not subtly as empty"
  assert_contains "$out" "Active domains unavailable: context reader failed (rc=124)" \
    "the timed-out reader's fallback message still reaches the prompt with its status"
}

test_stalled_pending_approvals_read_times_out_and_degrades() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/grep-stub-timeout"
  mkdir -p "$stub"
  local real_grep; real_grep="$(type -P grep)"
  printf '#!/bin/sh\ncase "$*" in *"approvals/pending.md"*) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_grep" > "$stub/grep"
  chmod +x "$stub/grep"
  echo "- [ ] test" > "$CEO_VAULT/CEO/approvals/pending.md"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|PENDING_COUNT=$PENDING_COUNT|APPROVED_COUNT=$APPROVED_COUNT|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|PENDING_COUNT=0|APPROVED_COUNT=0|DEGRADED=1" \
    "timed-out pending grep must set counts to 0 and mark degraded (#594)"
  assert_contains "$out" "pending-count:rc=124" \
    "the degraded reason records timeout rc 124"
  assert_contains "$out" "approved-count:rc=124" "the approved count times out too"
}

test_stalled_delegations_find_times_out_and_degrades() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/find-stub-timeout"
  mkdir -p "$stub"
  local real_find; real_find="$(type -P find)"
  printf '#!/bin/sh\ncase "$*" in *"delegations"*) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_find" > "$stub/find"
  chmod +x "$stub/find"
  mkdir -p "$CEO_VAULT/CEO/delegations"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|DELEGATION_COMPLETED=$DELEGATION_COMPLETED|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|DELEGATION_COMPLETED=0|DEGRADED=1" \
    "timed-out delegations find must set counts to 0 and mark degraded (#594)"
  assert_contains "$out" "delegations:find:rc=124" \
    "the degraded reason records timeout rc 124"
}

test_stalled_delegation_status_read_times_out_and_degrades() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/grep-stub-timeout"
  mkdir -p "$stub"
  local real_grep; real_grep="$(type -P grep)"
  printf '#!/bin/sh\ncase "$*" in *"^status: "*) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_grep" > "$stub/grep"
  chmod +x "$stub/grep"
  mkdir -p "$CEO_VAULT/CEO/delegations"
  printf -- '---\nstatus: failed\n---\n' > "$CEO_VAULT/CEO/delegations/a.md"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|FAILED=$DELEGATION_FAILED|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|FAILED=0|DEGRADED=1" \
    "a delegation file that stalls on read must time out and degrade, not hang the tick (#594)"
  assert_contains "$out" "delegations:failed:rc=124" "the reason names the status and the timeout"
}

test_stalled_briefings_training_read_times_out_and_degrades() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/head-stub-timeout"
  mkdir -p "$stub"
  local real_head; real_head="$(type -P head)"
  printf '#!/bin/sh\ncase "$*" in *"briefings.md"*) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_head" > "$stub/head"
  chmod +x "$stub/head"
  mkdir -p "$CEO_VAULT/CEO/training"
  echo "briefing training content" > "$CEO_VAULT/CEO/training/briefings.md"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|BRIEFINGS=${BRIEFINGS_TRAINING}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|BRIEFINGS=|DEGRADED=1" \
    "timed-out briefings read must leave training empty without aborting under set -euo pipefail (#594)"
  assert_contains "$out" "briefings.md:read:rc=124" \
    "the degraded reason records timeout rc 124"
}

test_timeout_fallback_to_python3_when_no_timeout_bin_on_path() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/head-stub-timeout-py"
  mkdir -p "$stub"
  local real_head; real_head="$(type -P head)"
  printf '#!/bin/sh\ncase "$*" in *"briefings.md"*) sleep 2; exit 0 ;; esac\nexec "%s" "$@"\n' "$real_head" > "$stub/head"
  chmod +x "$stub/head"
  mkdir -p "$CEO_VAULT/CEO/training"
  echo "briefing training content" > "$CEO_VAULT/CEO/training/briefings.md"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    export CEO_GATHER_TIMEOUT_BIN=""
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|BRIEFINGS=${BRIEFINGS_TRAINING}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
    type _CEO_TIMEOUT | grep -q "python3 -c" && echo "PYBRANCH=yes"
  )
  assert_contains "$out" "PYBRANCH=yes" "the shim must be the python3 fallback, not a timeout binary on PATH"
  assert_contains "$out" "COMPLETED|BRIEFINGS=|DEGRADED=1" \
    "python3 timeout fallback must enforce timeout and mark degraded (#594)"
  assert_contains "$out" "briefings.md:read:rc=124" \
    "the degraded reason records timeout rc 124 under python3 fallback"
}

test_delegation_counts_do_not_abort_under_set_euo_pipefail() {
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/CEO/delegations"
  cat > "$CEO_VAULT/CEO/delegations/delegation-1.md" << 'EOF'
---
status: completed
---
EOF
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED=$DELEGATION_COMPLETED|IN_PROGRESS=$DELEGATION_IN_PROGRESS|FAILED=$DELEGATION_FAILED"
  )
  assert_contains "$out" "COMPLETED=1|IN_PROGRESS=0|FAILED=0" \
    "gather must not abort under set -euo pipefail when a status has 0 matches (#592)"
}

# Every status needs a zero-match case, and a name with a space must count as one file.
test_delegation_counts_cover_each_status_and_spaced_names() {
  _write_goals "$(date +%Y-%m-%d)"
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/CEO/delegations"
  printf -- '---\nstatus: failed\n---\n' > "$CEO_VAULT/CEO/delegations/my delegation.md"
  printf -- '---\nstatus: pending\n---\n' > "$CEO_VAULT/CEO/delegations/other.md"
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED=$DELEGATION_COMPLETED|IN_PROGRESS=$DELEGATION_IN_PROGRESS|FAILED=$DELEGATION_FAILED|DEGRADED=$FILE_GATHER_DEGRADED"
  )
  assert_contains "$out" "COMPLETED=0|IN_PROGRESS=0|FAILED=1|DEGRADED=0" \
    "zero-match statuses count 0 and a spaced filename counts once"
}

# grep exits 1 on no match and 2 on a read error; only the read error degrades.
test_unreadable_delegation_file_degrades_the_gather() {
  [ "$(id -u)" -eq 0 ] && { assert_eq 0 0 "skipped as root"; return; }
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/CEO/delegations"
  printf -- '---\nstatus: failed\n---\n' > "$CEO_VAULT/CEO/delegations/a.md"
  printf -- '---\nstatus: failed\n---\n' > "$CEO_VAULT/CEO/delegations/b.md"
  chmod 000 "$CEO_VAULT/CEO/delegations/b.md"
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "FAILED=$DELEGATION_FAILED|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  chmod 644 "$CEO_VAULT/CEO/delegations/b.md"
  assert_contains "$out" "DEGRADED=1" "an unreadable delegation file must degrade the gather"
  assert_contains "$out" "delegations:failed:rc=2" "the reason names the status and grep's exit"
}

test_unreadable_today_log_degrades_the_gather() {
  [ "$(id -u)" -eq 0 ] && { assert_eq 0 0 "skipped as root"; return; }
  _write_gh_stub '[]'
  local today; today=$(date +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/CEO/log"
  printf '**Status:** completed\n' > "$CEO_VAULT/CEO/log/$today.md"
  chmod 000 "$CEO_VAULT/CEO/log/$today.md"
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "SUMMARY=$TODAY_LOG_SUMMARY|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  chmod 644 "$CEO_VAULT/CEO/log/$today.md"
  assert_contains "$out" "SUMMARY=actions:0 completed:0 failed:0|DEGRADED=1" \
    "an unreadable today log must degrade rather than read as a quiet day"
  assert_contains "$out" "today-log-actions:rc=2" "the reason names the field and grep's exit"
}

test_today_log_summary_zero_matches_does_not_double_zero() {
  _write_gh_stub '[]'
  local today; today=$(date +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/CEO/log"
  cat > "$CEO_VAULT/CEO/log/$today.md" << 'EOF'
# Daily Log
Just some notes with no status lines.
EOF
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "SUMMARY=$TODAY_LOG_SUMMARY"
  )
  assert_contains "$out" "SUMMARY=actions:0 completed:0 failed:0" \
    "zero status matches must yield 0, not 0\n0 (#592)"
  assert_not_contains "$out" $'\n0' \
    "today log summary must not contain newline-separated zeros"
}

test_today_log_summary_mixed_counts() {
  _write_gh_stub '[]'
  local today; today=$(date +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/CEO/log"
  cat > "$CEO_VAULT/CEO/log/$today.md" << 'EOF'
**Status:** completed
**Status:** completed
**Status:** failed
EOF
  local out
  out=$(
    set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "SUMMARY=$TODAY_LOG_SUMMARY"
  )
  assert_contains "$out" "SUMMARY=actions:3 completed:2 failed:1" \
    "mixed status matches must count accurately (#592)"
}

# --- Parse-time timeout validation (#606) ---
# GNU timeout exits 125 on a non-numeric delay before the command ever runs,
# which would read as every bounded vault read failing at once; 0 disables the
# wall-clock cap entirely. Both must fall back to the default with a WARN.

test_invalid_CEO_VAULT_TIMEOUT_warns_and_falls_back() {
  _write_gh_stub '[]'
  _write_goals "$(date +%Y-%m-%d)"
  mkdir -p "$CEO_VAULT/CEO/training"
  echo "briefings content" > "$CEO_VAULT/CEO/training/briefings.md"
  local out err
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=abc
    source "$SCRIPT_DIR/ceo-gather.sh" 2>"$TMP/stderr.log" >/dev/null
    echo "BRIEFINGS=${BRIEFINGS_TRAINING}|DEGRADED=$FILE_GATHER_DEGRADED"
  )
  err=$(cat "$TMP/stderr.log")
  assert_contains "$out" "BRIEFINGS=briefings content|DEGRADED=0" \
    "an invalid CEO_VAULT_TIMEOUT must fall back to the default, not fail every bounded read at once"
  assert_contains "$err" "CEO_VAULT_TIMEOUT 'abc' is not a positive integer; using 10" \
    "the fallback must warn, not silently swap the value"
}

test_zero_CEO_VAULT_TIMEOUT_falls_back_to_default() {
  _write_gh_stub '[]'
  _write_goals "$(date +%Y-%m-%d)"
  mkdir -p "$CEO_VAULT/CEO/training"
  echo "briefings content" > "$CEO_VAULT/CEO/training/briefings.md"
  local out err
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=0
    source "$SCRIPT_DIR/ceo-gather.sh" 2>"$TMP/stderr.log" >/dev/null
    echo "BRIEFINGS=${BRIEFINGS_TRAINING}|DEGRADED=$FILE_GATHER_DEGRADED"
  )
  err=$(cat "$TMP/stderr.log")
  assert_contains "$out" "BRIEFINGS=briefings content|DEGRADED=0" \
    "CEO_VAULT_TIMEOUT=0 must not disable the wall-clock cap (#606)"
  assert_contains "$err" "not a positive integer; using 10" \
    "the 0 fallback warns like the non-numeric one"
}

test_valid_CEO_VAULT_TIMEOUT_survives_validation() {
  _write_gh_stub '[]'
  _write_goals "$(date +%Y-%m-%d)"
  mkdir -p "$CEO_VAULT/CEO/training"
  echo "briefings content" > "$CEO_VAULT/CEO/training/briefings.md"
  local out err
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=12
    source "$SCRIPT_DIR/ceo-gather.sh" 2>"$TMP/stderr.log" >/dev/null
    echo "BRIEFINGS=${BRIEFINGS_TRAINING}|DEGRADED=$FILE_GATHER_DEGRADED"
  )
  err=$(cat "$TMP/stderr.log")
  assert_contains "$out" "BRIEFINGS=briefings content|DEGRADED=0" \
    "a valid configured timeout must run the gather clean"
  assert_not_contains "$err" "CEO_VAULT_TIMEOUT" \
    "a valid configured timeout must not trigger the WARN"
}

# --- Bounded orphan reads (#606): extraction greps, stat guards, section seds,
# the ledger awk, and the blessings cache read each sit on the vault mount and
# must not hang the tick.

test_stalled_pending_extraction_grep_times_out_and_degrades() {
  _write_gh_stub '[]'
  echo '- [ ] ask Slava about the mount' > "$CEO_VAULT/Pending.md"
  local stub; stub="$TMP/pending-grep-stub"
  mkdir -p "$stub"
  local real_grep; real_grep="$(type -P grep)"
  printf '#!/bin/sh\ncase "$*" in *"Pending.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_grep" > "$stub/grep"
  chmod +x "$stub/grep"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|PENDING_ASK_QUESTIONS=${PENDING_ASK_QUESTIONS}|DEGRADED=$FILE_GATHER_DEGRADED|PD=$PENDING_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|PENDING_ASK_QUESTIONS=|DEGRADED=1|PD=1" \
    "a stalled Pending.md extraction grep must time out and degrade the pending preflight, not claim a quiet day (#606)"
  assert_contains "$out" "Pending.md:rc=124" \
    "the degraded reason records the extraction timeout"
}

test_stalled_today_log_count_times_out_and_degrades() {
  _write_gh_stub '[]'
  local today; today=$(date +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/CEO/log"
  printf '**Status:** completed\n' > "$CEO_VAULT/CEO/log/$today.md"
  local stub; stub="$TMP/log-grep-stub"
  mkdir -p "$stub"
  local real_grep; real_grep="$(type -P grep)"
  printf '#!/bin/sh\ncase "$*" in *"log/%s.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$today" "$real_grep" > "$stub/grep"
  chmod +x "$stub/grep"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|SUMMARY=$TODAY_LOG_SUMMARY|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|SUMMARY=actions:0 completed:0 failed:0|DEGRADED=1" \
    "a stalled today-log count must time out to zeros and degrade, not hang the tick (#606)"
  assert_contains "$out" "today-log-actions:rc=124" \
    "the degraded reason records the count timeout"
}

test_stalled_daily_note_sed_times_out_without_hanging() {
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/Daily"
  printf '## Top 3\n- one\n' > "$CEO_VAULT/Daily/$(date +%Y-%m-%d).md"
  local stub; stub="$TMP/dailynote-sed-stub"
  mkdir -p "$stub"
  local real_sed; real_sed="$(type -P sed)"
  printf '#!/bin/sh\ncase "$*" in *"Daily/"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_sed" > "$stub/sed"
  chmod +x "$stub/sed"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|TOP3=$DAILY_NOTE_TOP3|TASKS=$DAILY_NOTE_TASKS|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|TOP3=|TASKS=|DEGRADED=1" \
    "a stalled daily-note section read must time out to empty and degrade, not read as a clean empty section (#606)"
  assert_contains "$out" "daily-note-top3:rc=124" \
    "the degraded reason records the Top 3 read timeout"
  assert_contains "$out" "daily-note-tasks:rc=124" \
    "the degraded reason records the Tasks read timeout"
}

test_stalled_yesterday_summary_sed_times_out_without_hanging() {
  _write_gh_stub '[]'
  local yday; yday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/CEO/log"
  printf '# log\n<!-- eod-summary -->\nan entry\n' > "$CEO_VAULT/CEO/log/$yday.md"
  local stub; stub="$TMP/yday-sed-stub"
  mkdir -p "$stub"
  local real_sed; real_sed="$(type -P sed)"
  printf '#!/bin/sh\ncase "$*" in *"log/%s.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$yday" "$real_sed" > "$stub/sed"
  chmod +x "$stub/sed"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|SUMMARY=$YESTERDAY_LOG_SUMMARY|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|SUMMARY=no eod summary|DEGRADED=1" \
    "a stalled eod-summary read must time out to the absent state and degrade (#606)"
  assert_contains "$out" "yesterday-summary:rc=124" \
    "the degraded reason records the eod-summary timeout"
}

test_stalled_sync_conflict_find_times_out_without_hanging() {
  _write_gh_stub '[]'
  local stub; stub="$TMP/sync-find-stub"
  mkdir -p "$stub"
  local real_find; real_find="$(type -P find)"
  printf '#!/bin/sh\ncase "$*" in *"sync-conflict-"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_find" > "$stub/find"
  chmod +x "$stub/find"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|SYNC_CONFLICT_COUNT=$SYNC_CONFLICT_COUNT|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|SYNC_CONFLICT_COUNT=0|DEGRADED=1" \
    "a stalled sync-conflict walk must time out to 0 and degrade, not report a healthy zero (#606)"
  assert_contains "$out" "sync-conflicts:rc=124" \
    "the degraded reason records the sync-conflict walk timeout"
}

test_stalled_ledger_awk_times_out_without_hanging() {
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/CEO/model"
  printf -- '---\npredicted today:\n  - org/repo#1: explanation\n---\n' > "$CEO_VAULT/CEO/model/2026-01-01.md"
  local stub; stub="$TMP/ledger-awk-stub"
  mkdir -p "$stub"
  local real_awk; real_awk="$(type -P awk)"
  printf '#!/bin/sh\ncase "$*" in *"model/2026-01-01.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_awk" > "$stub/awk"
  chmod +x "$stub/awk"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|LEDGER=${LEDGER_RECENT}|PREDICTED=${LEDGER_PREV_PREDICTED}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED" \
    "a stalled ledger awk must time out without hanging or aborting the gather (#606)"
  assert_contains "$out" "PREDICTED=[]|DEGRADED=1" \
    "the timed-out prediction parse reads empty and degrades"
  assert_contains "$out" "ledger-predicted:rc=124" \
    "the degraded reason records the awk timeout"
}

test_stalled_pending_stat_guard_times_out_and_degrades() {
  _write_gh_stub '[]'
  echo '- [ ] something' > "$CEO_VAULT/Pending.md"
  local stub; stub="$TMP/test-stat-stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\ncase "$2" in *Pending.md*) sleep 2; exit 0 ;; *) exec /usr/bin/test "$@" ;; esac\n' > "$stub/test"
  chmod +x "$stub/test"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|ASKQ=${PENDING_ASK_QUESTIONS}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|ASKQ=|DEGRADED=1" \
    "a timed-out stat guard must read as unanswerable, not as an absent file (#606)"
  assert_contains "$out" "stat:rc=124" \
    "the degraded reason records the stat timeout"
}

test_stalled_blessings_cache_read_times_out_and_degrades() {
  _write_gh_stub '[]'
  mkdir -p "$CEO_VAULT/CEO/cache"
  printf -- '---\ndate: %s\n---\nblessing one\n' "$(date +%Y-%m-%d)" > "$CEO_VAULT/CEO/cache/blessings-today.md"
  local stub; stub="$TMP/bless-head-stub"
  mkdir -p "$stub"
  local real_head; real_head="$(type -P head)"
  printf '#!/bin/sh\ncase "$*" in *"blessings-today.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_head" > "$stub/head"
  chmod +x "$stub/head"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|BLESSINGS=${BLESSINGS_TODAY}|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|BLESSINGS=|DEGRADED=1" \
    "a stalled blessings cache read must time out, empty the blessing, and degrade without hanging (#606)"
  assert_contains "$out" "blessings-today.md:read:rc=124" \
    "the degraded reason records the cache read timeout"
}

test_gather_test_marks_degraded_on_unrunnable_stat() {
  _write_gh_stub '[]'
  echo '- [ ] something' > "$CEO_VAULT/Pending.md"
  local stub; stub="$TMP/test-126-stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\ncase "$2" in *Pending.md*) exit 126 ;; *) exec /usr/bin/test "$@" ;; esac\n' > "$stub/test"
  chmod +x "$stub/test"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED|DEGRADED=$FILE_GATHER_DEGRADED"
    printf 'REASONS=%s\n' "$FILE_GATHER_DEGRADED_REASONS"
  )
  assert_contains "$out" "COMPLETED|DEGRADED=1" \
    "an unrunnable stat (rc 126) must read as unanswerable, not as an absent file (#606)"
  assert_contains "$out" "stat:rc=126" \
    "the degraded reason records the unrunnable stat"
}

test_stalled_blessings_pool_read_leaves_cache_unwritten() {
  _write_gh_stub '[]'
  printf -- '---\n---\n- one\n- two\n- three\n' > "$CEO_VAULT/CEO/blessings.md"
  rm -f "$CEO_VAULT/CEO/cache/blessings-today.md"
  local stub; stub="$TMP/bless-pool-stub"
  mkdir -p "$stub"
  local real_head; real_head="$(type -P head)"
  printf '#!/bin/sh\ncase "$*" in *"/blessings.md"*) sleep 2; exit 0 ;; *) exec "%s" "$@" ;; esac\n' "$real_head" > "$stub/head"
  chmod +x "$stub/head"
  local out
  out=$(
    set -euo pipefail
    export CEO_VAULT_TIMEOUT=1
    PATH="$stub:$PATH"
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    echo "COMPLETED"
  )
  assert_contains "$out" "COMPLETED" \
    "a stalled blessings pool read must not abort or hang the gather (#606)"
  if [ -e "$CEO_VAULT/CEO/cache/blessings-today.md" ]; then
    echo "FAIL: a timed-out pool read wrote a blessing-less cache stamped with today's date"
    return 1
  fi
}

run_tests
