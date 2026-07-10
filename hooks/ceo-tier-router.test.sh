#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/test-harness.sh"

setup() {
  CEO_TIER_MAP="$(mktemp)"
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export CEO_TIER_MAP OLLAMA_AGENT_LEDGER
  cat > "$CEO_TIER_MAP" <<'JSON'
{
  "shapes": [
    {"name": "read-only-lookup", "match_pattern": "^(find|locate)\\b", "allowed_subagent_types": ["general-purpose"], "tier": "haiku"}
  ]
}
JSON
}

teardown() {
  rm -f "$CEO_TIER_MAP" "$OLLAMA_AGENT_LEDGER"
}

test_matching_dispatch_gets_updated_input() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  local decision model
  decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  model=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.model')
  assert_eq "$decision" "allow" "matching dispatch is allowed through"
  assert_eq "$model" "haiku" "matching dispatch gets model overridden to the allowlisted tier"
}

test_non_matching_dispatch_passes_through_unmodified() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "refactor the billing module"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  assert_eq "$output" "" "no match means no hook output at all — the dispatch runs unmodified"
}

test_non_task_tool_is_ignored() {
  local input output
  input='{"tool_name": "Bash", "tool_input": {"command": "find . -name find"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  assert_eq "$output" "" "non-Task tool calls are never touched by this hook"
}

test_matching_dispatch_logs_to_ledger() {
  printf '%s' '{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}' \
    | bash "$SCRIPT_DIR/ceo-tier-router.sh" > /dev/null
  local logged
  logged=$(jq -c 'select(.writer == "interactive-tier")' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "1" "the downgrade decision is logged to the ledger"
}

test_disable_flag_short_circuits() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}'
  output=$(CEO_TIER_ROUTER_DISABLE=1 bash -c "printf '%s' '$input' | bash '$SCRIPT_DIR/ceo-tier-router.sh'")
  assert_eq "$output" "" "CEO_TIER_ROUTER_DISABLE=1 skips the hook entirely"
}

test_model_override_short_circuits() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}'
  output=$(CEO_MODEL_OVERRIDE=opus bash -c "printf '%s' '$input' | bash '$SCRIPT_DIR/ceo-tier-router.sh'")
  assert_eq "$output" "" "CEO_MODEL_OVERRIDE always wins over a tier-map match"
}

run_tests
