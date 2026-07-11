#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-model-ledger.sh"

setup() {
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export OLLAMA_AGENT_LEDGER
}

teardown() {
  rm -f "$OLLAMA_AGENT_LEDGER"
}

test_write_entry_returns_a_run_id() {
  local run_id
  run_id=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  assert_contains "$run_id" "claude-tier-" "run_id is prefixed with the writer type"
}

test_two_writes_get_unique_run_ids() {
  local a b
  a=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  b=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  assert_fails "run_ids must differ" [ "$a" = "$b" ]
}

test_entry_is_one_valid_json_line() {
  ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true" > /dev/null
  local last_line
  last_line=$(tail -1 "$OLLAMA_AGENT_LEDGER")
  assert_fails "last line must not be valid JSON when this test intentionally breaks it" bash -c "! echo '$last_line' | jq -e . >/dev/null 2>&1"
}

test_claude_tier_entry_coexists_with_ollama_agent_entry() {
  printf '%s\n' '{"ts": "2026-07-09T16:18:50Z", "run_id": "lean-batch-1", "session_id": "abc", "model": "gpt-oss:20b", "task_name": null, "cwd": "/tmp/task1", "ollama_input_tokens": 100, "ollama_output_tokens": 20, "turns": 3, "completed": true, "verified": true}' >> "$OLLAMA_AGENT_LEDGER"
  local run_id
  run_id=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")

  local ollama_matches claude_matches
  ollama_matches=$(jq -c --arg rid "lean-batch-1" 'select(.run_id == $rid)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  claude_matches=$(jq -c --arg rid "$run_id" 'select(.run_id == $rid)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')

  assert_eq "$ollama_matches" "1" "the pre-existing ollama-agent row is still uniquely selectable by run_id"
  assert_eq "$claude_matches" "1" "the new claude-tier row is uniquely selectable by run_id"
}

test_ledger_write_entry_does_not_propagate_write_failures_under_set_e() {
  local output exit_code
  output=$( (
    set -e
    export OLLAMA_AGENT_LEDGER="/nonexistent_root_dir/cant/write/here.jsonl"
    ceo_ledger_write_entry "claude-tier" "haiku" "test" "/tmp" "0.002" "true" > /dev/null 2>&1
    echo "reached_end"
  ) 2>&1 )
  exit_code=$?

  assert_eq "$exit_code" "0" "subshell must exit with 0 after failed ceo_ledger_write_entry under set -e"
  assert_contains "$output" "reached_end" "line after failed ceo_ledger_write_entry must execute under set -e"
}

run_tests
