#!/usr/bin/env bash
# ceo-tier-lib.sh — shared task-shape -> cheaper-tier lookup.
# Sourced by ceo-cron.sh and the ceo-tier-router PreToolUse hook. Pure
# lookup, no side effects; every function fails open (empty result) rather
# than raising, so a broken map can never block a real dispatch.

CEO_TIER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ceo_tier_map_path() {
  echo "${CEO_TIER_MAP:-$CEO_TIER_LIB_DIR/ceo-tier-map.json}"
}

# ceo_tier_lookup <label> <subagent_type>
# <label> is the short caller-supplied string matched against each shape's
# match_pattern: a CEO playbook trigger name, or an Agent-tool `description`.
ceo_tier_lookup() {
  local label="$1" subagent_type="$2"
  local map_path
  map_path="$(ceo_tier_map_path)"
  [ -f "$map_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg label "$label" --arg st "$subagent_type" '
    .shapes[]?
    | select((.allowed_subagent_types // []) | index($st) != null)
    | . as $shape
    | select($label | test($shape.match_pattern; "i"))
    | "\(.tier)|\(.name)"
  ' "$map_path" 2>/dev/null | head -1
}
