#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-tier-lib.sh"
source "$SCRIPT_DIR/ceo-model-ledger.sh"

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

# Simulates the resolution block ceo-cron.sh runs before dispatching a
# runner:claude playbook, isolated from the rest of the (very large) script.
_resolve_model_for_playbook() {
  local trigger="$1"
  local model="${MODEL:-sonnet}"
  if [ -z "${CEO_MODEL_OVERRIDE:-}" ] && [ -z "${CEO_TIER_ROUTER_DISABLE:-}" ]; then
    local match
    match=$(ceo_tier_lookup "$trigger" "general-purpose")
    if [ -n "$match" ]; then
      model="${match%%|*}"
      ceo_ledger_write_entry "claude-tier" "$model" "$trigger" "$(pwd)" "null" "null" > /dev/null
    fi
  fi
  [ -n "${CEO_MODEL_OVERRIDE:-}" ] && model="$CEO_MODEL_OVERRIDE"
  echo "$model"
}

test_matching_trigger_downgrades_and_logs() {
  local model
  model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "haiku" "matching trigger resolves to the allowlisted tier"
  local logged
  logged=$(jq -c --arg tn "find-stale-branches" 'select(.task_name == $tn)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "1" "the downgrade decision is logged to the ledger"
}

test_non_matching_trigger_keeps_default() {
  local model
  model=$(_resolve_model_for_playbook "reconcile-billing")
  assert_eq "$model" "sonnet" "non-matching trigger keeps the default model"
  local logged
  logged=$(jq -c --arg tn "reconcile-billing" 'select(.task_name == $tn)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "0" "no ledger entry when nothing was downgraded"
}

test_ceo_model_override_wins_over_tier_map() {
  local model
  CEO_MODEL_OVERRIDE="opus" model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "opus" "CEO_MODEL_OVERRIDE beats a tier-map match"
}

test_disable_flag_skips_tier_map() {
  local model
  CEO_TIER_ROUTER_DISABLE="1" model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "sonnet" "CEO_TIER_ROUTER_DISABLE skips the tier-map lookup entirely"
}

# --- The hook itself, run as a process, against a prompt past the pipe buffer ---
# The simulation above covers ceo-cron.sh's resolution block; these exercise
# hooks/ceo-tier-router.sh, which runs under `set -euo pipefail` where a
# SIGPIPEd jq aborts the hook and skips routing for the largest dispatches.

_oversized_task_payload() {
  local big
  # ~120KB, opening with "find" so the tier map matches on the first 200 bytes.
  big=$(printf 'find %.0s' {1..20000})
  jq -nc --arg p "$big" \
    '{tool_name:"Task", tool_input:{prompt:$p, subagent_type:"general-purpose"}}'
}

# Same load-bearing-fixture guard as the classifier suite: prove the pre-fix
# `jq … | head -c 200` form actually fails on this payload.
_assert_head_pipe_form_breaks() {
  local payload="$1" rc=0
  ( set -o pipefail
    printf '%s' "$payload" | jq -r '.tool_input.prompt' | head -c 200 >/dev/null
  ) || rc=$?
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL [%s] fixture no longer breaks the pre-fix `jq | head -c` form (rc=0), so it proves nothing — the prompt must exceed the pipe buffer\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
}

test_hook_routes_an_oversized_prompt() {
  local payload out rc=0
  payload=$(_oversized_task_payload)
  _assert_head_pipe_form_breaks "$payload"
  out=$(printf '%s' "$payload" | "$REPO_ROOT/hooks/ceo-tier-router.sh" 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "hook exits 0 on a prompt past the pipe buffer"
  assert_contains "$out" '"model":"haiku"' "oversized dispatch is still downgraded to the mapped tier"
}

test_hook_routes_a_small_prompt() {
  local payload out rc=0
  payload=$(jq -nc '{tool_name:"Task", tool_input:{prompt:"find stale branches", subagent_type:"general-purpose"}}')
  out=$(printf '%s' "$payload" | "$REPO_ROOT/hooks/ceo-tier-router.sh" 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "hook exits 0 on a small prompt"
  assert_contains "$out" '"model":"haiku"' "small dispatch is downgraded to the mapped tier"
}

run_tests
