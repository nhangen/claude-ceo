#!/bin/bash
set -euo pipefail

# setup-linux.sh — Provision a Linux box (non-WSL) as the CEO agent's execution environment.
# Run this once, interactively, on the Linux machine.
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
    *) echo "setup-linux.sh: unknown argument '$_arg'" >&2; exit 2 ;;
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

echo "=== CEO Agent — Linux Setup ==="
echo ""

# 1. System packages — detect apt-get vs dnf
# apt's `yq` is kislyuk/yq (python wrapper), not mikefarah/yq the codebase needs;
# Fedora's dnf ships mikefarah/yq, so it's safe there.
if command -v apt-get &>/dev/null; then
  _pkg_mgr="apt-get"
  _pkg_install=(sudo apt-get install -y)
  _pkg_argv=(git gh jq)
  _yq_hint="snap install yq  (or download from https://github.com/mikefarah/yq/releases)"
elif command -v dnf &>/dev/null; then
  _pkg_mgr="dnf"
  _pkg_install=(sudo dnf install -y)
  _pkg_argv=(git gh jq yq)
  _yq_hint="sudo dnf install yq"
else
  echo "[1/10] ERROR: no supported package manager (apt-get or dnf) found." >&2
  echo "  Install git, gh, jq, and yq manually, then re-run 'ceo setup'." >&2
  exit 1
fi
echo "[1/10] Installing required CLIs via $_pkg_mgr..."
ceo_setup_print_or_run "${_pkg_install[@]}" "${_pkg_argv[@]}"

_missing_tools=()
for _tool in git gh jq; do
  command -v "$_tool" &>/dev/null || _missing_tools+=("$_tool")
done
if [ "${#_missing_tools[@]}" -gt 0 ] && [ "$CEO_SETUP_DRY_RUN" = "0" ]; then
  echo "  Missing after install: ${_missing_tools[*]}" >&2
  echo "  Check $_pkg_mgr output above. On Ubuntu, 'gh' may require https://cli.github.com/." >&2
  exit 1
fi

# 2. gh authentication
if gh auth status &>/dev/null; then
  echo "[2/10] gh already authenticated"
else
  echo "[2/10] Authenticating gh CLI..."
  gh auth login
fi

ceo_setup_ssh_key "$(hostname -s 2>/dev/null || echo linux)"
ceo_setup_git_config
ceo_setup_check_syncthing
ceo_setup_check_yq "$_yq_hint"
ceo_setup_repos_dir
ceo_setup_check_claude
ceo_setup_vault
ceo_setup_pr_sources
ceo_setup_cron
ceo_setup_path_symlink
ceo_setup_write_next_steps "$_yq_hint"
ceo_setup_exit_if_missing
