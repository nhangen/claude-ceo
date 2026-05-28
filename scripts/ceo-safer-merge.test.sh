#!/bin/bash
# Self-contained test harness for ceo-safer-merge.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAFER_MERGE="$SCRIPT_DIR/ceo-safer-merge.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export XDG_STATE_HOME="$TEST_HOME/.local/state"
  unset CEO_ALLOW_RED_ADMIN_MERGE

  STUB_DIR="$TEST_HOME/stubs"
  mkdir -p "$STUB_DIR"
  GH_LOG="$TEST_HOME/gh-calls.log"
  CHECKS_JSON="$TEST_HOME/checks.json"
  HEAD_SHA="$TEST_HOME/head-sha.txt"
  GH_EXIT="$TEST_HOME/gh-exit.txt"
  echo '[{"__typename":"CheckRun","name":"Tests","conclusion":"SUCCESS"}]' > "$CHECKS_JSON"
  echo 'deadbeef' > "$HEAD_SHA"
  echo '0' > "$GH_EXIT"
  : > "$GH_LOG"

  cat > "$STUB_DIR/gh" <<EOF
#!/bin/bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr view")
    case "\$*" in
      *statusCheckRollup*) cat "$CHECKS_JSON" ;;
      *headRefOid*)        cat "$HEAD_SHA" ;;
    esac
    ;;
  "pr merge")
    echo "merged"
    exit "\$(cat "$GH_EXIT")"
    ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/gh"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  rm -rf "$TEST_HOME"
}

# --- Non-admin path: pure passthrough --------------------------------------

test_no_admin_passes_through_to_gh_pr_merge() {
  out=$("$SAFER_MERGE" 42 --merge 2>&1)
  assert_eq "$?" "0" "passthrough exits 0"
  assert_contains "$out" "merged" "stub gh ran"
  call=$(cat "$GH_LOG")
  assert_contains "$call" "pr merge 42 --merge" "args forwarded verbatim"
}

test_passthrough_propagates_gh_exit_code() {
  echo '7' > "$GH_EXIT"
  "$SAFER_MERGE" 42 --merge >/dev/null 2>&1
  assert_eq "$?" "7" "non-zero gh exit propagated"
}

test_missing_pr_ref_errors() {
  out=$("$SAFER_MERGE" --merge 2>&1); rc=$?
  assert_eq "$rc" "2" "exit 2 when no PR ref"
  assert_contains "$out" "first argument must be the PR ref" "error message"
}

test_pr_ref_must_be_first_positional() {
  # Pre-fix behavior: `--repo OWNER/NAME 87` captured OWNER/NAME as pr_ref
  # and silently green-lit the merge when the downstream gh lookup failed.
  out=$("$SAFER_MERGE" --repo nhangen/claude-ceo 87 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "2" "leading --repo rejected"
  assert_contains "$out" "first argument must be the PR ref" "error names the constraint"
  call=$(cat "$GH_LOG")
  assert_no_match "$call" "pr merge" "no merge attempted"
}

# --- Admin path: red checks ------------------------------------------------

test_admin_refuses_when_checks_failing() {
  cat > "$CHECKS_JSON" <<'JSON'
[
  {"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"FAILURE"},
  {"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"SUCCESS"}
]
JSON
  out=$("$SAFER_MERGE" 76 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "4" "exit 4 on red admin merge"
  assert_contains "$out" "REFUSED" "refused header"
  assert_contains "$out" "Tests: FAILURE" "names the failing check"
  call=$(cat "$GH_LOG")
  assert_no_match "$call" "pr merge 76" "gh pr merge was NOT called"
}

test_admin_refuses_on_each_blocking_conclusion() {
  for conclusion in CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE ERROR; do
    cat > "$CHECKS_JSON" <<JSON
[{"__typename":"CheckRun","name":"Probe","conclusion":"$conclusion"}]
JSON
    : > "$GH_LOG"
    "$SAFER_MERGE" 76 --admin --merge >/dev/null 2>&1
    assert_eq "$?" "4" "exit 4 on conclusion=$conclusion"
    assert_no_match "$(cat "$GH_LOG")" "pr merge 76" "no merge attempted for $conclusion"
  done
}

test_admin_refuses_on_status_context_failure_state() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]
JSON
  "$SAFER_MERGE" 76 --admin --merge >/dev/null 2>&1
  assert_eq "$?" "4" "StatusContext .state=FAILURE blocks"
}

test_admin_refuses_on_mixed_pending_and_failure() {
  cat > "$CHECKS_JSON" <<'JSON'
[
  {"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"},
  {"__typename":"CheckRun","name":"Lint","status":"IN_PROGRESS","conclusion":""}
]
JSON
  "$SAFER_MERGE" 76 --admin --merge >/dev/null 2>&1
  assert_eq "$?" "4" "pending alongside failure still blocks"
}

test_admin_allows_when_all_checks_passing() {
  cat > "$CHECKS_JSON" <<'JSON'
[
  {"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS"}
]
JSON
  out=$("$SAFER_MERGE" 77 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "0" "exit 0 on green admin merge"
  call=$(cat "$GH_LOG")
  assert_contains "$call" "pr merge 77 --admin --merge" "merge forwarded"
}

test_admin_allows_when_checks_pending() {
  cat > "$CHECKS_JSON" <<'JSON'
[
  {"__typename":"CheckRun","name":"Tests","status":"IN_PROGRESS","conclusion":""}
]
JSON
  "$SAFER_MERGE" 78 --admin --merge >/dev/null 2>&1
  assert_eq "$?" "0" "pending checks do not block"
}

test_admin_allows_when_only_neutral_or_skipped() {
  cat > "$CHECKS_JSON" <<'JSON'
[
  {"__typename":"CheckRun","name":"Optional","conclusion":"NEUTRAL"},
  {"__typename":"CheckRun","name":"Skipped","conclusion":"SKIPPED"}
]
JSON
  "$SAFER_MERGE" 79 --admin --merge >/dev/null 2>&1
  assert_eq "$?" "0" "neutral/skipped do not block"
}

# --- Admin path: silent-failure modes the gate must close ------------------

test_admin_refuses_when_gh_pr_view_fails() {
  # Override gh stub to fail on `pr view` so the wrapper cannot read checks.
  cat > "$STUB_DIR/gh" <<EOF
#!/bin/bash
echo "\$@" >> "$GH_LOG"
if [ "\$1 \$2" = "pr view" ]; then
  echo "boom: auth expired" >&2
  exit 1
fi
echo "merged"
exit 0
EOF
  chmod +x "$STUB_DIR/gh"
  out=$("$SAFER_MERGE" 76 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "5" "exit 5 when gh pr view fails"
  assert_contains "$out" "could not read check status" "explains the refusal"
  assert_no_match "$(cat "$GH_LOG")" "pr merge 76" "no merge attempted"
}

test_admin_refuses_when_rollup_is_empty() {
  echo '[]' > "$CHECKS_JSON"
  out=$("$SAFER_MERGE" 76 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "4" "exit 4 when rollup empty"
  assert_contains "$out" "no checks reported" "explains the refusal"
  assert_no_match "$(cat "$GH_LOG")" "pr merge 76" "no merge attempted"
}

test_admin_refuses_when_jq_missing() {
  # Wrap the safer-merge invocation in a PATH that lacks jq.
  PATH_NO_JQ=$(printf '%s\n' "$PATH" | tr ':' '\n' | while read -r p; do
    [ -x "$p/jq" ] || printf '%s:' "$p"
  done)
  out=$(PATH="$PATH_NO_JQ" "$SAFER_MERGE" 76 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "5" "exit 5 when jq missing"
  assert_contains "$out" "jq is required" "explains the refusal"
}

# --- Admin path: --admin-reason override -----------------------------------

test_admin_reason_unblocks_red_merge_and_is_logged() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  out=$("$SAFER_MERGE" 76 --admin --merge --admin-reason "stuck check on cancelled runner" 2>&1); rc=$?
  assert_eq "$rc" "0" "exit 0 with valid reason"
  log_file="$TEST_HOME/.local/state/ceo-admin-merges.log"
  assert_file_exists "$log_file" "log written"
  log_line=$(cat "$log_file")
  assert_contains "$log_line" "PR=76" "PR logged"
  assert_contains "$log_line" "SHA=deadbeef" "SHA logged"
  assert_contains "$log_line" "stuck check on cancelled runner" "reason logged"
  call=$(cat "$GH_LOG")
  assert_contains "$call" "pr merge 76 --admin --merge" "merge forwarded"
  assert_no_match "$call" "admin-reason" "admin-reason stripped before gh"
}

test_admin_reason_too_short_is_rejected() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  out=$("$SAFER_MERGE" 76 --admin --merge --admin-reason "fix it" 2>&1); rc=$?
  assert_eq "$rc" "3" "exit 3 on trivial reason"
  assert_contains "$out" "at least 10" "error explains threshold"
  log_file="$TEST_HOME/.local/state/ceo-admin-merges.log"
  [ ! -f "$log_file" ] || assert_eq "exists" "absent" "log must not be written for rejected reason"
  assert_eq "1" "1" "anchor assertion"
}

test_admin_reason_whitespace_only_is_rejected() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  "$SAFER_MERGE" 76 --admin --merge --admin-reason "          " >/dev/null 2>&1
  assert_eq "$?" "3" "whitespace-only reason rejected"
}

test_admin_reason_equals_form_accepted_and_logged() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  "$SAFER_MERGE" 76 --admin --merge --admin-reason="branch protection irrelevant on personal repo" >/dev/null 2>&1
  assert_eq "$?" "0" "--admin-reason=<text> form accepted"
  log_file="$TEST_HOME/.local/state/ceo-admin-merges.log"
  assert_file_exists "$log_file" "log written"
  assert_contains "$(cat "$log_file")" "branch protection irrelevant on personal repo" "reason logged"
  assert_no_match "$(cat "$GH_LOG")" "admin-reason" "= form stripped before gh"
}

test_admin_reason_swallowing_next_flag_is_rejected() {
  out=$("$SAFER_MERGE" 76 --admin --admin-reason --merge 2>&1); rc=$?
  assert_eq "$rc" "3" "rejects --admin-reason whose value starts with --"
  assert_contains "$out" "requires a value" "explains the rejection"
}

test_admin_reason_without_admin_is_rejected() {
  out=$("$SAFER_MERGE" 76 --merge --admin-reason "this should require --admin" 2>&1); rc=$?
  assert_eq "$rc" "2" "rejects --admin-reason without --admin"
  assert_contains "$out" "requires --admin" "explains the rejection"
}

# --- Admin path: env override ----------------------------------------------

test_env_override_unblocks_red_merge_and_is_logged() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  export CEO_ALLOW_RED_ADMIN_MERGE=1
  "$SAFER_MERGE" 76 --admin --merge >/dev/null 2>&1
  assert_eq "$?" "0" "env override allows merge"
  log_file="$TEST_HOME/.local/state/ceo-admin-merges.log"
  assert_file_exists "$log_file" "env override is logged"
  assert_contains "$(cat "$log_file")" "env:CEO_ALLOW_RED_ADMIN_MERGE" "env reason recorded"
  assert_contains "$(cat "$GH_LOG")" "pr merge 76 --admin --merge" "merge forwarded"
  unset CEO_ALLOW_RED_ADMIN_MERGE
}

test_override_refuses_when_head_sha_fetch_fails() {
  cat > "$STUB_DIR/gh" <<EOF
#!/bin/bash
echo "\$@" >> "$GH_LOG"
if [ "\$1 \$2" = "pr view" ] && [[ "\$*" == *headRefOid* ]]; then
  echo "boom: rate limited" >&2
  exit 1
fi
if [ "\$1 \$2" = "pr view" ] && [[ "\$*" == *statusCheckRollup* ]]; then
  cat "$CHECKS_JSON"
  exit 0
fi
echo "merged"
exit 0
EOF
  chmod +x "$STUB_DIR/gh"
  export CEO_ALLOW_RED_ADMIN_MERGE=1
  out=$("$SAFER_MERGE" 76 --admin --merge 2>&1); rc=$?
  assert_eq "$rc" "5" "exit 5 when audit-trail SHA fetch fails"
  assert_contains "$out" "could not resolve head SHA" "explains refusal"
  assert_no_match "$(cat "$GH_LOG")" "pr merge 76" "no merge attempted"
  unset CEO_ALLOW_RED_ADMIN_MERGE
}

run_tests
