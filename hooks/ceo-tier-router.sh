#!/usr/bin/env bash
# ceo-tier-router.sh — PreToolUse hook. Enforces automatic downgrade-to-
# cheaper-tier for Task/Agent dispatches whose shape matches
# scripts/ceo-tier-map.json. This is the single choke point for interactive-
# session routing — see docs/superpowers/specs/2026-07-10-tiered-model-delegation-design.md.
set -euo pipefail

if [ -n "${CEO_TIER_ROUTER_DISABLE:-}" ] || [ -n "${CEO_MODEL_OVERRIDE:-}" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ceo-tier-lib.sh
source "$REPO_ROOT/scripts/ceo-tier-lib.sh"
# shellcheck source=ceo-model-ledger.sh
source "$REPO_ROOT/scripts/ceo-model-ledger.sh"

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""')"

if [ "$tool_name" != "Task" ] && [ "$tool_name" != "Agent" ]; then
  exit 0
fi

subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')"
label="$(printf '%s' "$input" | jq -r '.tool_input.description // .tool_input.prompt // ""' | head -c 200)"

[ -n "$label" ] || exit 0

match="$(ceo_tier_lookup "$label" "$subagent_type")"
[ -n "$match" ] || exit 0

tier="${match%%|*}"
shape="${match##*|}"

ceo_ledger_write_entry "interactive-tier" "$tier" "$shape" "$(pwd)" "null" "null" > /dev/null

jq -nc --arg tier "$tier" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { model: $tier }
  }
}'
