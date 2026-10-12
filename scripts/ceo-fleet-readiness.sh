#!/usr/bin/env bash
set -euo pipefail
: "${HOME:?HOME must be set}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/ceo-config.sh
source "$script_dir/ceo-config.sh"
ceo_load_config
ceo_augment_path
: "${CEO_VAULT:?CEO vault must be configured}"
repo="${LLM_TOOLS_REPO:-}"
if [ -z "$repo" ]; then
  for candidate in "$HOME/code/llm-tools" "$HOME/Code/llm-tools" "$HOME/.local/share/llm-tools-deploy"; do
    if [ -f "$candidate/scripts/fleet-readiness.py" ]; then repo="$candidate"; break; fi
  done
fi
if [ -z "$repo" ] || [ ! -f "$repo/scripts/fleet-readiness.py" ]; then
  printf 'ERROR: fleet checker unavailable; set LLM_TOOLS_REPO\n' >&2
  exit 1
fi
host="${CEO_HOSTNAME:-$(hostname -s)}"
python3 "$script_dir/ceo-fleet-readiness-report.py" --vault "$CEO_VAULT" --host "$host" --checker "$repo/scripts/fleet-readiness.py" --registry "$repo/home/.claude/olla-fleet.json" --local-context "${CEO_FLEET_LOCAL_CONTEXT:-}" --outcome-file "${CEO_RUNNER_OUTCOME_FILE:-}"
