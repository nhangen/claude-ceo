#!/bin/bash
set -euo pipefail

# setup-wsl.sh — Provision a WSL box as the CEO agent's execution environment.
# Run this once, interactively, on the WSL machine.
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
    *) echo "setup-wsl.sh: unknown argument '$_arg'" >&2; exit 2 ;;
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

echo "=== CEO Agent — WSL Setup ==="
echo ""

# 1. System packages
echo "[1/10] Installing system packages..."
ceo_setup_print_or_run sudo apt update -qq
ceo_setup_print_or_run sudo apt install -y -qq git curl jq

# 2. GitHub CLI
if command -v gh &>/dev/null; then
  echo "[2/10] gh CLI already installed ($(gh --version | head -1))"
else
  echo "[2/10] Installing GitHub CLI..."
  _gh_keyring='curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg'
  _gh_apt_src='echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null'
  _gh_install='sudo apt update -qq && sudo apt install -y -qq gh'
  if [ "$CEO_SETUP_DRY_RUN" = "1" ]; then
    echo "  [dry-run] $_gh_keyring"
    echo "  [dry-run] $_gh_apt_src"
    echo "  [dry-run] $_gh_install"
  else
    bash -eo pipefail -c "$_gh_keyring"
    bash -eo pipefail -c "$_gh_apt_src"
    bash -eo pipefail -c "$_gh_install"
  fi
fi

# gh authentication — disambiguate not-authed from transient network failures.
ceo_setup_gh_auth " "

ceo_setup_ssh_key "$(hostname -s 2>/dev/null || echo wsl)"
ceo_setup_git_config
ceo_setup_check_syncthing
ceo_setup_check_yq "sudo snap install yq  (or: brew install yq on Mac)"
ceo_setup_repos_dir
ceo_setup_check_claude
ceo_setup_vault
ceo_setup_swarm
ceo_setup_pr_sources
ceo_setup_cron
ceo_setup_path_symlink
ceo_setup_write_next_steps "sudo snap install yq  (or: brew install yq)"
ceo_setup_exit_if_missing
