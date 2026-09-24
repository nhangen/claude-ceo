#!/bin/bash
# Tests for ceo-agent-scope.sh and docs/playbooks/agent-scope.md (#279).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
SCRIPT="$SCRIPT_DIR/ceo-agent-scope.sh"
LIB="$SCRIPT_DIR/ceo-config.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  # The runner reads this when set, so a developer's exported value would send it
  # outside the fixture (test-writes-stay-in-the-fixture).
  export CLAUDE_AGENTS_DIR="$TEST_HOME/agents-dir"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$CEO_DIR/log" "$HOME/.ceo" "$CLAUDE_AGENTS_DIR"
  : > "$CEO_DIR/inbox.md"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR TEST_HOME HOME_BACKUP \
        CLAUDE_AGENTS_DIR LLM_TOOLS_REPO CEO_RUNNER_OUTCOME_FILE CEO_REPO_PLAYBOOK_DIR
}

# The declared artifact, expanded the way ceo doctor expands it. Every arm below
# derives the report path from this rather than a literal, because a literal
# copied from the playbook is what let {TODAY} ship against a tool that writes
# {MONTH} (test-expected-from-production-entry-point).
_declared_report() {
  local template
  template=$(sed -n 's/^artifact: *//p' "$SCRIPT_DIR/../docs/playbooks/agent-scope.md")
  local rel
  rel=$(bash -c "source '$LIB'; ceo_artifact_expand '$template' testhost")
  # An unexpandable template is the failure this helper exists to surface, so it
  # must not come back as an empty path that assert_file_exists shrugs at.
  [ -n "$rel" ] || { printf '%s\n' "UNEXPANDABLE:$template"; return 0; }
  printf '%s\n' "$CEO_VAULT/$rel"
}

# A stub that refuses an argv shape it was not given, and honors --reports-dir
# instead of writing to a hardcoded path. Without both, an assertion that a flag
# reached the launcher says nothing about whether the launcher used it.
_install_stub() {
  local mock_bin="$1" exit_code="${2:-0}" warn="${3:-}" write="${4:-yes}"
  mkdir -p "$(dirname "$mock_bin")"
  cat > "$mock_bin" <<STUB
#!/bin/bash
echo "STUB_INVOKED: \$*" > "\$HOME/stub.log"
reports_dir=""; ledger_root=""; agents_dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --reports-dir) reports_dir="\$2"; shift 2 ;;
    --ledger-root) ledger_root="\$2"; shift 2 ;;
    --agents-dir) agents_dir="\$2"; shift 2 ;;
    *) echo "unexpected argument: \$1" >&2; exit 64 ;;
  esac
done
for required in "\$reports_dir" "\$ledger_root" "\$agents_dir"; do
  [ -n "\$required" ] || { echo "missing required flag" >&2; exit 64; }
done
[ -n "$warn" ] && echo "WARNING: $warn" >&2
if [ "$write" = yes ]; then
  mkdir -p "\$reports_dir"
  echo "# Agent Scope Snapshot" > "\$reports_dir/\$(date +%Y-%m).md"
fi
exit $exit_code
STUB
  chmod +x "$mock_bin"
}

test_missing_launcher_fails_loudly() {
  export LLM_TOOLS_REPO="$TEST_HOME/nonexistent"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing launcher must exit 1"
  assert_contains "$err" "LLM_TOOLS_REPO is set but" "stderr must name the path it rejected"
}

test_explicit_override_is_never_searched_past() {
  # A normal host has a real launcher at ~/.claude/skills, so an override that
  # falls through to the candidate sweep runs a tree the operator did not pick.
  local real="$HOME/.claude/skills/agent-scope/scripts/agent-scope"
  _install_stub "$real"
  export LLM_TOOLS_REPO="$TEST_HOME/typo"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "a bad override must fail rather than fall back"
  local swept="absent"; [ -e "$TEST_HOME/stub.log" ] && swept="ran"
  assert_eq "$swept" "absent" "the candidate sweep must not run when the override is set"
  assert_contains "$err" "$TEST_HOME/typo" "stderr must name the override path"
}

test_present_but_not_executable_launcher_is_reported_as_such() {
  local mock_bin="$HOME/.claude/skills/agent-scope/scripts/agent-scope"
  _install_stub "$mock_bin"
  chmod -x "$mock_bin"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "a non-executable launcher must exit 1"
  assert_contains "$err" "[not executable]" "stderr must distinguish non-executable from absent"
}

test_ceo_dir_unset_refuses_to_run() {
  # Without the guard the runner would mkdir -p "/reports/agent-scope".
  local err="" rc=0
  err=$(env -u CEO_DIR bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "unset CEO_DIR must exit non-zero"
  assert_contains "$err" "CEO_DIR must be set" "stderr must name the missing variable"
}

test_successful_run_invokes_launcher_and_signals_fired() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope"
  export LLM_TOOLS_REPO="$mock_repo"
  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"

  local rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "successful agent-scope execution exits 0"
  assert_file_exists "$TEST_HOME/stub.log" "mock launcher must be executed"
  local log; log=$(cat "$TEST_HOME/stub.log")
  assert_contains "$log" "--ledger-root $CEO_DIR/agents" "passes ledger root"
  assert_contains "$log" "--reports-dir $CEO_DIR/reports/agent-scope" "passes reports dir"
  assert_contains "$log" "--agents-dir $CLAUDE_AGENTS_DIR" "passes agents dir"
  local outcome; outcome=$(cat "$outcome_file" 2>/dev/null || echo "")
  assert_eq "$outcome" "fired" "runner outcome must be marked fired"
}

test_report_lands_at_the_declared_artifact_path() {
  # The bug this pins: the playbook declared {TODAY} while the tool writes one
  # file per month, so doctor's cross-check looked at a path that never exists.
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope"
  export LLM_TOOLS_REPO="$mock_repo"
  local rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "run must succeed"
  local expected; expected=$(_declared_report)
  assert_file_exists "$expected" "report must land at the expanded declared artifact path"
}

test_launcher_failure_propagates_and_writes_no_outcome() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 1
  export LLM_TOOLS_REPO="$mock_repo"
  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"

  local rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "the launcher's exit code must reach the dispatcher"
  local outcome; outcome=$(cat "$outcome_file" 2>/dev/null || echo "")
  assert_eq "$outcome" "" "a failed run must not claim fired"
}

test_partial_input_exits_3_and_alerts() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 3 "could not read ledger file" no
  export LLM_TOOLS_REPO="$mock_repo"
  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"
  local report; report=$(_declared_report)
  mkdir -p "$(dirname "$report")"
  echo "# last good snapshot" > "$report"

  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "3" "partial input must exit 3"
  assert_contains "$err" "partial input or no agent ranked; snapshot NOT written" "stderr must name both rc=3 causes"
  # The launcher's own lines name the unreadable path; they are the only
  # diagnostic that says which input was bad.
  assert_contains "$err" "could not read ledger file" "the launcher's stderr must reach the operator"
  local line; line=$(printf '%s\n' "$err" | grep 'agent-scope rc=3')
  [ "${#line}" -le 120 ] || fail_test "rc=3 alert is ${#line} chars; ceo-cron cuts tail lines at 120"
  assert_eq "$(cat "$report")" "# last good snapshot" "a refused run must leave the prior snapshot alone"
  local outcome; outcome=$(cat "$outcome_file" 2>/dev/null || echo "")
  assert_eq "$outcome" "" "partial input must not claim fired"
}

test_missing_input_root_exits_2_without_partial_input_alert() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 2 "ledger root does not exist" no
  export LLM_TOOLS_REPO="$mock_repo"
  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"

  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "2" "missing input root must exit 2"
  assert_not_contains "$err" "partial input" "exit 2 must not be labeled as partial input"
  local outcome; outcome=$(cat "$outcome_file" 2>/dev/null || echo "")
  assert_eq "$outcome" "" "exit 2 must not claim fired"
}

test_an_entry_level_warning_does_not_fail_the_run() {
  # Failing on any stderr WARNING would turn the playbook red every week over
  # one malformed consult entry; the exit code alone decides.
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 0 "unparseable review_by in socrates/2026-09.md"
  export LLM_TOOLS_REPO="$mock_repo"
  local rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a warning about one entry must not fail the run"
}

test_exit_zero_is_success_whatever_stderr_says() {
  # #460 removed a grep that failed rc=0 runs on this exact warning text. The
  # launcher now exits 3 for that case, so the grep would only duplicate the
  # exit code and break when the wording changes.
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 0 "skipping unreadable file socrates/2026-09.md"
  export LLM_TOOLS_REPO="$mock_repo"
  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"
  local rc=0
  bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "rc=0 with a written report must succeed"
  assert_eq "$(cat "$outcome_file" 2>/dev/null)" "fired" "rc=0 with a written report must claim fired"
}

test_exit_zero_without_a_report_is_a_failure() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope" 0 "" no
  export LLM_TOOLS_REPO="$mock_repo"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "exit 0 with no report must fail the run"
  assert_contains "$err" "missing or empty" "stderr must name the missing report"
}

test_unwritable_reports_dir_fails_with_a_named_message() {
  # Without the guard the launcher hits the same directory and the operator gets
  # a Python traceback in cron-stderr.log instead of this line.
  local mock_repo="$TEST_HOME/mock-llm-tools"
  _install_stub "$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope"
  export LLM_TOOLS_REPO="$mock_repo"
  mkdir -p "$CEO_DIR/reports"
  chmod 500 "$CEO_DIR/reports"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  chmod 700 "$CEO_DIR/reports"
  assert_eq "$rc" "1" "an uncreatable reports dir must exit 1"
  assert_contains "$err" "cannot create" "stderr must name the directory it could not create"
}

test_playbook_scan_registers_agent_scope() {
  cp "$SCRIPT_DIR/../docs/playbooks/agent-scope.md" "$CEO_DIR/playbooks/agent-scope.md"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local reg="$HOME/.ceo/registry.json"
  assert_file_exists "$reg" "registry must exist after scan"
  local status runner script scope artifact
  status=$(jq -r '.playbooks[] | select(.name=="agent-scope") | .status' "$reg")
  runner=$(jq -r '.playbooks[] | select(.name=="agent-scope") | .runner' "$reg")
  script=$(jq -r '.playbooks[] | select(.name=="agent-scope") | .script' "$reg")
  scope=$(jq -r '.playbooks[] | select(.name=="agent-scope") | .scope' "$reg")
  artifact=$(jq -r '.playbooks[] | select(.name=="agent-scope") | .artifact' "$reg")

  assert_eq "$status" "active" "status is active"
  assert_eq "$runner" "script" "runner is script"
  assert_eq "$script" "ceo-agent-scope.sh" "script is ceo-agent-scope.sh"
  assert_eq "$scope" "single" "scope is single"
  # {MONTH} must survive the scan validator, not be dropped as an unknown token.
  assert_eq "$artifact" "CEO/reports/agent-scope/{MONTH}.md" "artifact keeps its {MONTH} token through scan"
}

run_tests
