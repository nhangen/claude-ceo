#!/bin/bash
# Tests for ceo-ollama-smoke.sh and docs/playbooks/ollama-smoke.md (#276).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
SCRIPT="$SCRIPT_DIR/ceo-ollama-smoke.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$CEO_DIR/alerts" "$HOME/.ceo"
  : > "$CEO_DIR/inbox.md"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR TEST_HOME HOME_BACKUP OLLAMA_SMOKE_BIN
}

test_missing_smoke_bin_fails_loudly() {
  export OLLAMA_SMOKE_BIN="$TEST_HOME/nonexistent"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing smoke bin must exit 1"
  assert_contains "$err" "integration_smoke.sh not found" "stderr must describe missing smoke bin"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

test_all_skip_marks_stack_absent_and_clear() {
  local mock_bin="$TEST_HOME/mock-smoke"
  cat > "$mock_bin" << 'STUB'
#!/bin/bash
echo "Prerequisites"
echo "  SKIP ollama daemon"
echo "PASS=0  FAIL=0  SKIP=6"
exit 0
STUB
  chmod +x "$mock_bin"
  export OLLAMA_SMOKE_BIN="$mock_bin"

  bash "$SCRIPT" >/dev/null 2>&1
  local alert="$CEO_DIR/alerts/ollama-smoke.md"
  assert_file_exists "$alert" "alert file must be created"
  local content; content=$(cat "$alert")
  assert_contains "$content" "status: clear" "status must be clear for all-skip"
  assert_contains "$content" "stack: absent" "stack must be marked absent"
  assert_contains "$content" "skip_count: 6" "skip count preserved"

  local inbox; inbox=$(cat "$CEO_DIR/inbox.md")
  assert_eq "$inbox" "" "no inbox line when all skip"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 5))
}

test_failure_marks_firing_and_escalates_to_inbox() {
  local mock_bin="$TEST_HOME/mock-smoke"
  cat > "$mock_bin" << 'STUB'
#!/bin/bash
echo "  FAIL ccr chat round-trip"
echo "PASS=2  FAIL=1  SKIP=3"
exit 1
STUB
  chmod +x "$mock_bin"
  export OLLAMA_SMOKE_BIN="$mock_bin"

  bash "$SCRIPT" >/dev/null 2>&1
  local alert="$CEO_DIR/alerts/ollama-smoke.md"
  assert_file_exists "$alert" "alert file must exist"
  local content; content=$(cat "$alert")
  assert_contains "$content" "status: firing" "status must be firing on failure"
  assert_contains "$content" "fail_count: 1" "fail count recorded"

  local inbox; inbox=$(cat "$CEO_DIR/inbox.md")
  assert_contains "$inbox" "- [ ] Investigate local ollama live stack failure" "inbox task created"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 4))
}

test_recovery_from_firing_marks_inbox_done() {
  local mock_bin="$TEST_HOME/mock-smoke"
  cat > "$mock_bin" << 'STUB'
#!/bin/bash
echo "  FAIL ccr chat round-trip"
echo "PASS=2  FAIL=1  SKIP=3"
exit 1
STUB
  chmod +x "$mock_bin"
  export OLLAMA_SMOKE_BIN="$mock_bin"

  bash "$SCRIPT" >/dev/null 2>&1

  # Now simulate recovery
  cat > "$mock_bin" << 'STUB'
#!/bin/bash
echo "  PASS all checks"
echo "PASS=5  FAIL=0  SKIP=1"
exit 0
STUB

  bash "$SCRIPT" >/dev/null 2>&1
  local alert="$CEO_DIR/alerts/ollama-smoke.md"
  local content; content=$(cat "$alert")
  assert_contains "$content" "status: clear" "status flips to clear"
  assert_contains "$content" "pass_count: 5" "pass count recorded"

  local inbox; inbox=$(cat "$CEO_DIR/inbox.md")
  assert_contains "$inbox" "- [done] Ollama live stack smoke cleared" "inbox task marked done"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 3))
}

test_playbook_scan_registers_ollama_smoke() {
  cp "$SCRIPT_DIR/../docs/playbooks/ollama-smoke.md" "$CEO_DIR/playbooks/ollama-smoke.md"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local reg="$HOME/.ceo/registry.json"
  assert_file_exists "$reg" "registry must exist after scan"
  local status runner script scope artifact
  status=$(jq -r '.playbooks[] | select(.name=="ollama-smoke") | .status' "$reg")
  runner=$(jq -r '.playbooks[] | select(.name=="ollama-smoke") | .runner' "$reg")
  script=$(jq -r '.playbooks[] | select(.name=="ollama-smoke") | .script' "$reg")
  scope=$(jq -r '.playbooks[] | select(.name=="ollama-smoke") | .scope' "$reg")
  artifact=$(jq -r '.playbooks[] | select(.name=="ollama-smoke") | .artifact' "$reg")

  assert_eq "$status" "active" "status is active"
  assert_eq "$runner" "script" "runner is script"
  assert_eq "$script" "ceo-ollama-smoke.sh" "script is ceo-ollama-smoke.sh"
  assert_eq "$scope" "single" "scope is single"
  assert_eq "$artifact" "CEO/alerts/ollama-smoke.md" "artifact is CEO/alerts/ollama-smoke.md"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 6))
}

run_tests
