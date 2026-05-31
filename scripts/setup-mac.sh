#!/bin/bash
set -euo pipefail

# setup-mac.sh — Provision a Mac as the CEO agent's execution environment.
# Run this once, interactively, on the Mac.
#
# Flags:
#   --dry-run   Print package-install commands instead of executing them.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC2034  # populated by setup-common.sh's ceo_setup_git_config / read by ceo_setup_exit_if_missing
MISSING_CONFIG=()

# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"
# shellcheck source=setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

CEO_SETUP_DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) CEO_SETUP_DRY_RUN=1 ;;
    *) echo "setup-mac.sh: unknown argument '$_arg'" >&2; exit 2 ;;
  esac
done
export CEO_SETUP_DRY_RUN

# Refuse to proceed on a non-interactive stdin unless the caller is just
# previewing the package plan. Several steps below use `read -p`; without
# a TTY they silently accept empty input and persist a broken config
# (CEO_VAULT="") to ~/.ceo/config. Gate at the installer entrypoint per
# safety-invariant-scope so no read site can opt out.
if [ "$CEO_SETUP_DRY_RUN" = "0" ] && [ ! -t 0 ]; then
  echo "ceo setup requires an interactive terminal." >&2
  echo "  Re-run from a terminal (not piped, not </dev/null, not CI)." >&2
  echo "  For non-interactive package planning, pass --dry-run." >&2
  exit 1
fi

echo "=== CEO Agent — Mac Setup ==="
echo ""

# 1. System packages via Homebrew
if ! command -v brew &>/dev/null; then
  echo "[1/10] ERROR: brew not found. Install Homebrew from https://brew.sh and re-run." >&2
  exit 1
fi
echo "[1/10] Installing required CLIs via brew..."
ceo_setup_print_or_run brew install git gh jq yq

_missing_tools=()
for _tool in git gh jq; do
  command -v "$_tool" &>/dev/null || _missing_tools+=("$_tool")
done
if [ "${#_missing_tools[@]}" -gt 0 ] && [ "$CEO_SETUP_DRY_RUN" = "0" ]; then
  echo "  Missing after install: ${_missing_tools[*]}" >&2
  echo "  Check brew output above for errors." >&2
  exit 1
fi

# 2. gh authentication
if gh auth status &>/dev/null; then
  echo "[2/10] gh already authenticated"
else
  echo "[2/10] Authenticating gh CLI..."
  gh auth login
fi

ceo_setup_ssh_key "$(hostname -s 2>/dev/null || echo mac)"
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
