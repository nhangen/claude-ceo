#!/bin/bash
set -euo pipefail

# setup-mac.sh — Provision a Mac as the CEO agent's execution environment.
# Run this once, interactively, on the Mac.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"
# shellcheck source=setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

# shellcheck disable=SC2034  # populated by setup-common.sh's ceo_setup_git_config / read by ceo_setup_exit_if_missing
MISSING_CONFIG=()

echo "=== CEO Agent — Mac Setup ==="
echo ""

# 1. System packages — manual install at this stage (#96 will add brew driver)
echo "[1/10] Required CLIs (install manually for now):"
echo "  brew install git gh jq yq"
echo ""
_missing_tools=()
for _tool in git gh jq; do
  command -v "$_tool" &>/dev/null || _missing_tools+=("$_tool")
done
if [ "${#_missing_tools[@]}" -gt 0 ]; then
  echo "  Missing: ${_missing_tools[*]}"
  echo "  Install the above with brew and re-run 'ceo setup'."
  exit 1
fi
echo "  All required CLIs present."

# 2. gh authentication
if gh auth status &>/dev/null; then
  echo "[2/10] gh already authenticated"
else
  echo "[2/10] Authenticating gh CLI..."
  gh auth login
fi

ceo_setup_ssh_key "mac"
ceo_setup_git_config
ceo_setup_check_syncthing
ceo_setup_check_yq "brew install yq"
ceo_setup_repos_dir
ceo_setup_check_claude
ceo_setup_vault
ceo_setup_pr_sources
ceo_setup_cron
ceo_setup_path_symlink
ceo_setup_write_next_steps "brew install yq"
ceo_setup_exit_if_missing
