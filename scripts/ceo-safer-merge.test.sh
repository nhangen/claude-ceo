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
  echo '[]' > "$CHECKS_JSON"
  echo 'deadbeef' > "$HEAD_SHA"

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
    echo "merged" ;;
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

test_missing_pr_ref_errors() {
  out=$("$SAFER_MERGE" --merge 2>&1); rc=$?
  assert_eq "$rc" "2" "exit 2 when no PR ref"
  assert_contains "$out" "no PR specified" "error message"
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
  if [ -f "$log_file" ]; then
    assert_eq "found" "absent" "log must not be written for rejected reason"
  fi
}

test_admin_reason_whitespace_only_is_rejected() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  "$SAFER_MERGE" 76 --admin --merge --admin-reason "          " >/dev/null 2>&1
  assert_eq "$?" "3" "whitespace-only reason rejected"
}

test_admin_reason_equals_form_accepted() {
  cat > "$CHECKS_JSON" <<'JSON'
[{"__typename":"CheckRun","name":"Tests","conclusion":"FAILURE"}]
JSON
  "$SAFER_MERGE" 76 --admin --merge --admin-reason="branch protection irrelevant on personal repo" >/dev/null 2>&1
  assert_eq "$?" "0" "--admin-reason=<text> form accepted"
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
  unset CEO_ALLOW_RED_ADMIN_MERGE
}

run_tests
