#!/bin/bash
# Tests for ceo-agent-scope.sh and docs/playbooks/agent-scope.md (#279).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
SCRIPT="$SCRIPT_DIR/ceo-agent-scope.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$CEO_DIR/log" "$HOME/.ceo"
  : > "$CEO_DIR/inbox.md"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR TEST_HOME HOME_BACKUP
}

test_missing_launcher_fails_loudly() {
  export LLM_TOOLS_REPO="$TEST_HOME/nonexistent"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing launcher must exit 1"
  assert_contains "$err" "agent-scope launcher not found" "stderr must describe missing launcher"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

test_successful_run_invokes_launcher_and_signals_fired() {
  local mock_repo="$TEST_HOME/mock-llm-tools"
  local mock_bin="$mock_repo/home/.claude/skills/agent-scope/scripts/agent-scope"
  mkdir -p "$(dirname "$mock_bin")"
  cat > "$mock_bin" << 'STUB'
#!/bin/bash
echo "STUB_INVOKED: $*" > "$HOME/stub.log"
mkdir -p "$HOME/vault/CEO/reports/agent-scope"
echo "# Agent Scope Snapshot" > "$HOME/vault/CEO/reports/agent-scope/2026-09.md"
exit 0
STUB
  chmod +x "$mock_bin"
  export LLM_TOOLS_REPO="$mock_repo"

  local outcome_file="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"

  local out="" rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "0" "successful agent-scope execution exits 0"
  assert_file_exists "$TEST_HOME/stub.log" "mock launcher must be executed"
  local log; log=$(cat "$TEST_HOME/stub.log")
  assert_contains "$log" "--ledger-root $CEO_DIR/agents" "passes ledger root"
  assert_contains "$log" "--reports-dir $CEO_DIR/reports/agent-scope" "passes reports dir"
  local outcome; outcome=$(cat "$outcome_file" 2>/dev/null || echo "")
  assert_eq "$outcome" "fired" "runner outcome must be marked fired"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 5))
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
  assert_eq "$artifact" "CEO/reports/agent-scope/{TODAY}.md" "artifact is declared under reports/agent-scope"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 6))
}

run_tests
