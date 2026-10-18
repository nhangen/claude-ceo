#!/usr/bin/env bash
set -euo pipefail
: "${HOME:?HOME must be set}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/ceo-config.sh
source "$script_dir/ceo-config.sh"
ceo_load_config
ceo_augment_path
: "${CEO_VAULT:?CEO vault must be configured}"
host="${CEO_HOSTNAME:-$(hostname -s)}"
notify_execution_failure() {
  if python3 "$script_dir/ceo-fleet-readiness-discord.py" --vault "$CEO_VAULT" --host "$host" --execution-failure; then
    if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then printf 'failure-notified' > "$CEO_RUNNER_OUTCOME_FILE"; fi
  fi
}
repo="${LLM_TOOLS_REPO:-}"
if [ -z "$repo" ]; then
  for candidate in "$HOME/code/llm-tools" "$HOME/Code/llm-tools" "$HOME/.local/share/llm-tools-deploy"; do
    if [ -f "$candidate/scripts/fleet-readiness.py" ]; then repo="$candidate"; break; fi
  done
fi
if [ -z "$repo" ] || [ ! -f "$repo/scripts/fleet-readiness.py" ]; then
  printf 'ERROR: fleet checker unavailable; set LLM_TOOLS_REPO\n' >&2
  notify_execution_failure
  exit 1
fi
if ! python3 "$script_dir/ceo-fleet-readiness-report.py" --vault "$CEO_VAULT" --host "$host" --checker "$repo/scripts/fleet-readiness.py" --registry "$repo/home/.claude/olla-fleet.json" --local-context "${CEO_FLEET_LOCAL_CONTEXT:-}"; then
  notify_execution_failure
  exit 1
fi
python3 "$script_dir/ceo-fleet-readiness-discord.py" --vault "$CEO_VAULT" --host "$host"
if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"; fi
