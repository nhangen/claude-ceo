#!/bin/bash
# setup-common.sh — Shared steps for ceo setup across WSL/Mac/Linux installers.
# Sourced, not executed. Functions preserve the WSL-baseline output strings
# verbatim so `diff` against captured baselines shows only date drift.
#
# Required from caller (sourced before any function is called):
#   - SCRIPT_DIR resolved (the dirname of the calling installer)
#   - MISSING_CONFIG array declared (callers populate this; final exit check reads it)

declare -p MISSING_CONFIG &>/dev/null || {
  echo "setup-common.sh: caller must declare MISSING_CONFIG=() before sourcing." >&2
  exit 1
}

# Echo the command (with a [dry-run] prefix) when CEO_SETUP_DRY_RUN=1; otherwise execute it.
# Callers pass `argv...` with no shell quoting tricks — this is for package-install drivers,
# not arbitrary shell pipelines.
ceo_setup_print_or_run() {
  if [ "${CEO_SETUP_DRY_RUN:-0}" = "1" ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# Verify each <tool> is on PATH; on any missing, echo a diagnostic with the
# caller-supplied follow-up hint (e.g. "Check brew output above for errors.")
# and return 1. Returns 0 if all tools present, or if CEO_SETUP_DRY_RUN=1
# (dry-run doesn't install anything, so don't fail it on a fresh shell).
# Helper does NOT exit — callers must propagate.
#
# Sites collapsed from setup-mac.sh + setup-linux.sh per #122.
ceo_setup_check_required_tools() {
  local followup_hint="$1"; shift
  local _missing=() _tool
  for _tool in "$@"; do
    command -v "$_tool" &>/dev/null || _missing+=("$_tool")
  done
  if [ "${#_missing[@]}" -gt 0 ] && [ "${CEO_SETUP_DRY_RUN:-0}" = "0" ]; then
    echo "  Missing after install: ${_missing[*]}" >&2
    echo "  $followup_hint" >&2
    return 1
  fi
  return 0
}

# Authenticate gh, distinguishing "not logged in" from "network/transient
# failure". Pre-#102 each installer used `gh auth status &>/dev/null` and
# fell through to `gh auth login` on any non-zero exit — including DNS
# failures and 5xx — silently restarting the interactive auth flow when
# the real fix was retrying later. command-v-presence-vs-success applied
# to rc.
#
# Contract:
#   rc=0 → already authed; echo "$1 gh already authenticated" and return 0
#   rc=1 + stderr contains "not logged" or "not authenticated" → echo
#     "$1 Authenticating gh CLI..." then `gh auth login`; return its rc
#   otherwise → echo a network/error diagnostic with the captured stderr
#     and return 1 without invoking `gh auth login`
#
# $1 is the step prefix the caller wants on the success/auth-prompt lines
# ("[2/10]" on mac/linux; "  " on wsl).
ceo_setup_gh_auth() {
  local prefix="${1:-}"
  local _err _rc=0
  _err=$(gh auth status 2>&1 >/dev/null) || _rc=$?
  if [ "$_rc" = "0" ]; then
    echo "${prefix} gh already authenticated"
    return 0
  fi
  case "$_err" in
    *"not logged"*|*"not authenticated"*)
      echo "${prefix} Authenticating gh CLI..."
      gh auth login
      return $?
      ;;
    *)
      echo "${prefix} ERROR: gh auth status failed and did not indicate 'not logged in'." >&2
      echo "  Likely a transient network / GitHub API failure — re-run later." >&2
      echo "  gh stderr: ${_err}" >&2
      return 1
      ;;
  esac
}

# Treat y / Y / yes / YES / Yes / 'y ' (trailing whitespace) all as yes; any
# other input (including empty / n / N / no / typos) as no. Bash 3.2 has no
# `${var,,}` so we route through tr for the lowercase fold.
_ceo_is_yes() {
  local _v
  _v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$_v" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

ceo_setup_ssh_key() {
  local host_label="$1"
  [ -n "$host_label" ] || host_label="host"
  local ssh_key="$HOME/.ssh/github_ceo"
  if [ -f "$ssh_key" ]; then
    echo "[3/10] SSH key already exists at $ssh_key"
  else
    echo "[3/10] Generating SSH key..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "ceo-agent@$host_label"

    echo ""
    echo "  Add this public key to GitHub → Settings → SSH Keys:"
    echo ""
    cat "${ssh_key}.pub"
    echo ""
    read -p "  Press Enter after adding the key to GitHub..."
  fi

  if grep -q "github_ceo" "$HOME/.ssh/config" 2>/dev/null; then
    echo "  SSH config already references github_ceo"
  elif grep -q "^Host github.com" "$HOME/.ssh/config" 2>/dev/null; then
    sed -i.bak '/^Host github.com/a\
  IdentityFile ~/.ssh/github_ceo' "$HOME/.ssh/config"
    rm -f "$HOME/.ssh/config.bak"
    echo "  Added github_ceo key to existing Host github.com block"
  else
    cat >> "$HOME/.ssh/config" << 'SSHEOF'

Host github.com
  IdentityFile ~/.ssh/github_ceo
  IdentityFile ~/.ssh/id_ed25519
SSHEOF
    chmod 600 "$HOME/.ssh/config"
    echo "  SSH config updated"
  fi
}

ceo_setup_git_config() {
  echo "[4/10] Configuring git..."
  local existing_name existing_email
  existing_name="$(git config --global --get user.name 2>/dev/null || true)"
  if [ -n "$existing_name" ]; then
    echo "  user.name preserved: $existing_name"
  elif [ -n "${CEO_GIT_USER_NAME:-}" ]; then
    git config --global user.name "$CEO_GIT_USER_NAME"
    echo "  user.name set from CEO_GIT_USER_NAME: $CEO_GIT_USER_NAME"
  else
    echo "  WARNING: git user.name not set. Set CEO_GIT_USER_NAME or run:" >&2
    echo "    git config --global user.name \"Your Name\"" >&2
    MISSING_CONFIG+=("git user.name")
  fi
  existing_email="$(git config --global --get user.email 2>/dev/null || true)"
  if [ -n "$existing_email" ]; then
    echo "  user.email preserved: $existing_email"
  elif [ -n "${CEO_GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$CEO_GIT_USER_EMAIL"
    echo "  user.email set from CEO_GIT_USER_EMAIL: $CEO_GIT_USER_EMAIL"
  else
    echo "  WARNING: git user.email not set. Set CEO_GIT_USER_EMAIL or run:" >&2
    echo "    git config --global user.email <you@example.com>" >&2
    MISSING_CONFIG+=("git user.email")
  fi
}

ceo_setup_check_syncthing() {
  if command -v syncthing &>/dev/null; then
    echo "[5/10] Syncthing found"
  else
    echo "[5/10] WARNING: Syncthing not found."
    echo "  Install Syncthing on all machines before proceeding."
    echo "  See README.md and syncthing/README.md for setup instructions."
  fi
}

ceo_setup_check_yq() {
  local install_hint="${1:-sudo snap install yq  (or: brew install yq on Mac)}"
  if command -v yq &>/dev/null; then
    echo "[6/10] yq found ($(yq --version 2>/dev/null || echo 'unknown'))"
  else
    echo "[6/10] WARNING: yq not found."
    echo "  Install: $install_hint"
  fi
}

# Resolves INSTALL_DIR (the plugin clone root) by walking up from $SCRIPT_DIR
# to find .claude-plugin/. Exports INSTALL_DIR and REPOS_DIR for later steps.
ceo_setup_repos_dir() {
  INSTALL_DIR="$SCRIPT_DIR"
  while [ "$INSTALL_DIR" != "/" ]; do
    [ -d "$INSTALL_DIR/.claude-plugin" ] && break
    INSTALL_DIR="$(dirname "$INSTALL_DIR")"
  done
  if [ "$INSTALL_DIR" = "/" ]; then
    INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
    echo "  WARNING: could not locate .claude-plugin/ above $SCRIPT_DIR — falling back to $INSTALL_DIR" >&2
    echo "  'ceo doctor' may not find plugin assets if this is wrong." >&2
    MISSING_CONFIG+=("plugin INSTALL_DIR")
  fi
  REPOS_DIR="$(dirname "$INSTALL_DIR")/repos"
  echo "[7/10] Creating repo directory at $REPOS_DIR..."
  mkdir -p "$REPOS_DIR"
  export INSTALL_DIR REPOS_DIR
}

ceo_setup_check_claude() {
  if command -v claude &>/dev/null; then
    echo "[8/10] Claude Code already installed ($(claude --version 2>/dev/null || echo 'unknown version'))"
  else
    echo "[8/10] Claude Code not found."
    echo "  Install it manually: https://claude.ai/download"
    echo "  After installing, run: claude login"
  fi
}

# Vault detection + write ~/.ceo/config. Exports VAULT and CEO_OS for later
# steps (next-steps banner). Candidate list mirrors ceo_load_config's
# Step 3 — gated so /mnt/* only suggested on WSL.
ceo_setup_vault() {
  echo ""
  echo "[9/10] Vault configuration"
  CEO_OS="$(ceo_detect_os)"

  local _detected_vault=""
  local _user="${USER:-$(whoami)}"
  local _candidates=()
  if [ "$CEO_OS" = "wsl" ]; then
    _candidates+=( \
      "/mnt/z/Users/$_user/Documents/Obsidian" \
      "/mnt/c/Users/$_user/Documents/Obsidian" \
    )
  fi
  _candidates+=( \
    "$HOME/Documents/Obsidian" \
    "$HOME/Obsidian" \
  )
  local _c
  for _c in "${_candidates[@]}"; do
    if [ -d "$_c/CEO" ]; then
      _detected_vault="$_c"
      break
    fi
  done

  local _example_path
  if [ "$CEO_OS" = "wsl" ]; then
    _example_path="/mnt/z/Users/$_user/Documents/Obsidian"
  else
    _example_path="$HOME/Documents/Obsidian"
  fi

  if [ -n "$_detected_vault" ]; then
    echo "  Detected vault: $_detected_vault"
    local _input_vault
    read -rp "  Vault path [press Enter to accept, or type a different path]: " _input_vault
    VAULT="${_input_vault:-$_detected_vault}"
  else
    echo "  No vault auto-detected. Enter the full path to your Obsidian vault."
    read -rp "  Vault path (e.g. $_example_path): " VAULT
  fi

  # Empty vault is a missing-required-config event, not a default. Writing
  # CEO_VAULT="" to ~/.ceo/config silently breaks every downstream helper
  # (doctor probe, value-tracker, scheduler install) and the user has no
  # signal until something else fails far from the cause. Push onto
  # MISSING_CONFIG; ceo_setup_exit_if_missing surfaces it at the bottom
  # of the installer.
  if [ -z "$VAULT" ]; then
    echo "  ERROR: empty vault path." >&2
    echo "  CEO_VAULT must be set explicitly. Re-run 'ceo setup' and enter the full path." >&2
    MISSING_CONFIG+=("CEO_VAULT")
    export VAULT CEO_OS
    return 0
  fi

  if [ -f "$VAULT/CEO/inbox.md" ]; then
    echo "  Vault OK — CEO/inbox.md found at $VAULT/CEO/"
  else
    echo "  WARNING: CEO/inbox.md not found at $VAULT/CEO/"
    echo "  Make sure Syncthing is running and the vault has fully synced."
    echo "  You can re-run 'ceo setup' after syncing to update the config."
  fi

  mkdir -p "$HOME/.ceo"
  cat > "$HOME/.ceo/config" << CEOCONF
# CEO agent configuration — written by ceo setup on $(date)
# Edit this file to change the vault path or OS hint.
CEO_VAULT="$VAULT"
CEO_OS="$CEO_OS"
CEOCONF
  echo "  Config written: $HOME/.ceo/config"

  export VAULT CEO_OS
}

ceo_setup_swarm() {
  echo ""
  echo "[9a] Swarm registration"
  # ceo_setup_vault may have pushed CEO_VAULT onto MISSING_CONFIG and left
  # VAULT empty; without a vault there is nowhere to write swarm.json. Skip
  # rather than fail — the missing-config surface already flags the real issue.
  if [ -z "${VAULT:-}" ]; then
    echo "  Skipped (no vault configured yet)."
    return 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "  Skipped (jq not installed). Re-run 'ceo setup' after installing jq."
    return 0
  fi
  CEO_VAULT="$VAULT" _swarm_bootstrap || {
    echo "  WARNING: could not bootstrap swarm.json."
    return 0
  }
  if CEO_VAULT="$VAULT" _swarm_register_host; then
    echo "  Registered this host in $VAULT/CEO/swarm.json"
  else
    echo "  Host NOT registered — set a unique CEO_HOSTNAME (see message above) and re-run 'ceo setup'."
  fi
}

ceo_setup_pr_sources() {
  echo ""
  echo "[9b] PR sources configuration"
  echo "  Selects which gh/glab accounts the morning brief queries for PR counts."
  ceo_pr_sources_setup || echo "  (skipped — re-run later with: ceo pr-sources)"
}

ceo_setup_cron() {
  local ceo_cli="$SCRIPT_DIR/ceo"
  if [ -f "$ceo_cli" ] && command -v yq &>/dev/null; then
    echo ""
    echo "[10/10] Playbook Scan"
    local install_cron
    read -p "  Scan playbooks and generate the host-local registry? (y/n) " install_cron
    if _ceo_is_yes "$install_cron"; then
      bash "$ceo_cli" playbook scan
    else
      echo "  Skipped ('${install_cron}' interpreted as no). Run 'ceo playbook scan' later to generate the registry."
    fi
  else
    echo ""
    echo "[10/10] Skipping playbook scan (ceo CLI or yq not available)."
    echo "  Run 'ceo playbook scan' after installing yq."
  fi
}

ceo_setup_path_symlink() {
  local ceo_cli="$SCRIPT_DIR/ceo"
  if [ ! -f "$ceo_cli" ]; then
    return 0
  fi
  if command -v ceo &>/dev/null && [ "$(command -v ceo)" = "$ceo_cli" ]; then
    echo ""
    echo "[11] ceo CLI already on PATH"
  elif command -v ceo &>/dev/null; then
    echo ""
    echo "[11] WARNING: 'ceo' already exists on PATH at $(command -v ceo)"
    echo "  Skipping — add an alias manually if needed:"
    echo "  echo 'alias ceo=\"$ceo_cli\"' >> ~/.bashrc"
  else
    echo ""
    echo "[11] Add 'ceo' command to PATH?"
    echo "  This creates a symlink in ~/.local/bin/ so you can run 'ceo' from anywhere."
    local add_path
    read -p "  Add to PATH? (y/n) " add_path
    if _ceo_is_yes "$add_path"; then
      mkdir -p "$HOME/.local/bin"
      ln -sf "$ceo_cli" "$HOME/.local/bin/ceo"
      echo "  Symlinked: ~/.local/bin/ceo → $ceo_cli"
      if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        echo "  NOTE: ~/.local/bin is not in your PATH yet."
        echo "  Add this to your ~/.bashrc or ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      fi
    else
      echo "  Skipped ('${add_path}' interpreted as no). Add the alias manually if needed."
    fi
  fi
}

ceo_setup_write_next_steps() {
  local next_steps="$INSTALL_DIR/next-steps.txt"
  local yq_hint="${1:-sudo snap install yq  (or: brew install yq)}"
  {
    echo "=== CEO Agent — Next Steps ==="
    echo ""
    echo "Setup finished $(date). Pick up here after claude login."
    echo ""
    echo "  1. Verify Syncthing is syncing the vault"
    echo "  2. Install yq if missing:  $yq_hint"
    echo "  3. Run: claude login  (if not already authenticated)"
    echo "  4. Run: claude plugin add nhangen/claude-ceo"
    echo "  5. Run: ceo doctor  (verify everything is configured)"
    echo "  6. Run: ceo pr-sources  (pick which gh/glab accounts to query, if you skipped it)"
    echo "  7. Run: ceo playbook scan  (register playbooks + install cron)"
    echo "  8. Test interactive:  cd $VAULT && claude"
    echo "     Then type:  /ceo"
    echo "  9. Test cron:  ceo test"
    echo ""
    echo "Redisplay:  ceo next"
  } > "$next_steps"

  echo ""
  echo "=== Setup Complete ==="
  echo ""
  cat "$next_steps"
  echo ""
  echo "NOTE: 'claude login' will clear your terminal."
  echo "To redisplay:  ceo next"
  echo "To verify:     ceo doctor"
}

ceo_setup_exit_if_missing() {
  if [ "${#MISSING_CONFIG[@]}" -gt 0 ]; then
    echo "" >&2
    echo "=== MISSING REQUIRED CONFIG ===" >&2
    local _missing
    for _missing in "${MISSING_CONFIG[@]}"; do
      echo "  - $_missing" >&2
    done
    echo "" >&2
    echo "Set the values above and re-run 'ceo doctor' before any CEO commits." >&2
    exit 1
  fi
}
