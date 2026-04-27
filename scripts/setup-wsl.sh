#!/bin/bash
set -euo pipefail

# setup-wsl.sh — Provision a WSL box as the CEO agent's execution environment.
# Run this once, interactively, on the WSL machine.

# Source config library for ceo_detect_os
SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR_EARLY/ceo-config.sh"

echo "=== CEO Agent — WSL Setup ==="
echo ""

# 1. System packages
echo "[1/10] Installing system packages..."
sudo apt update -qq
sudo apt install -y -qq git curl jq

# 2. GitHub CLI
if command -v gh &>/dev/null; then
  echo "[2/10] gh CLI already installed ($(gh --version | head -1))"
else
  echo "[2/10] Installing GitHub CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt update -qq && sudo apt install -y -qq gh
fi

# Authenticate gh
if gh auth status &>/dev/null; then
  echo "  gh already authenticated"
else
  echo "  Authenticating gh CLI..."
  gh auth login
fi

# 3. SSH key for GitHub
SSH_KEY="$HOME/.ssh/github_ceo"
if [ -f "$SSH_KEY" ]; then
  echo "[3/10] SSH key already exists at $SSH_KEY"
else
  echo "[3/10] Generating SSH key..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "ceo-agent@wsl"

  echo ""
  echo "  Add this public key to GitHub → Settings → SSH Keys:"
  echo ""
  cat "${SSH_KEY}.pub"
  echo ""
  read -p "  Press Enter after adding the key to GitHub..."
fi

# Configure SSH to use this key
if grep -q "github_ceo" "$HOME/.ssh/config" 2>/dev/null; then
  echo "  SSH config already references github_ceo"
elif grep -q "^Host github.com" "$HOME/.ssh/config" 2>/dev/null; then
  # Existing Host block — inject the CEO key as an additional IdentityFile
  sed -i '/^Host github.com/a\  IdentityFile ~/.ssh/github_ceo' "$HOME/.ssh/config"
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

# 4. Git config
echo "[4/10] Configuring git..."
git config --global user.name "Nathan Hangen (CEO Agent)"
git config --global user.email "nhangen@users.noreply.github.com"

# 5. Syncthing
# Syncthing — must be installed and configured separately (see README.md)
if command -v syncthing &>/dev/null; then
  echo "[5/10] Syncthing found"
else
  echo "[5/10] WARNING: Syncthing not found."
  echo "  Install Syncthing on all machines before proceeding."
  echo "  See README.md and syncthing/README.md for setup instructions."
fi

# 6. yq (YAML parser for playbook frontmatter)
if command -v yq &>/dev/null; then
  echo "[6/10] yq found ($(yq --version 2>/dev/null || echo 'unknown'))"
else
  echo "[6/10] WARNING: yq not found."
  echo "  Install: sudo snap install yq  (or: brew install yq on Mac)"
fi

# Derive install root from script location (works regardless of clone path)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find repo root by walking up from scripts/ to find .claude-plugin/
INSTALL_DIR="$SCRIPT_DIR"
while [ "$INSTALL_DIR" != "/" ]; do
  [ -d "$INSTALL_DIR/.claude-plugin" ] && break
  INSTALL_DIR="$(dirname "$INSTALL_DIR")"
done
if [ "$INSTALL_DIR" = "/" ]; then
  INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
fi

# 7. Repo directory (sibling of the plugin clone)
REPOS_DIR="$(dirname "$INSTALL_DIR")/repos"
echo "[7/10] Creating repo directory at $REPOS_DIR..."
mkdir -p "$REPOS_DIR"

# 8. Claude Code
if command -v claude &>/dev/null; then
  echo "[8/10] Claude Code already installed ($(claude --version 2>/dev/null || echo 'unknown version'))"
else
  echo "[8/10] Claude Code not found."
  echo "  Install it manually: https://claude.ai/download"
  echo "  After installing, run: claude login"
fi

# 9. Vault directory — ask user, validate, write ~/.ceo/config
echo ""
echo "[9/10] Vault configuration"
CEO_OS="$(ceo_detect_os)"

# Suggest detected location, let user override
_detected_vault=""
_user="${USER:-$(whoami)}"
for _c in \
  "/mnt/z/Users/$_user/Documents/Obsidian" \
  "/mnt/c/Users/$_user/Documents/Obsidian" \
  "$HOME/Documents/Obsidian" \
  "$HOME/Obsidian"
do
  if [ -d "$_c/CEO" ]; then
    _detected_vault="$_c"
    break
  fi
done

if [ -n "$_detected_vault" ]; then
  echo "  Detected vault: $_detected_vault"
  read -rp "  Vault path [press Enter to accept, or type a different path]: " _input_vault
  VAULT="${_input_vault:-$_detected_vault}"
else
  echo "  No vault auto-detected. Enter the full path to your Obsidian vault."
  read -rp "  Vault path (e.g. /mnt/z/Users/$_user/Documents/Obsidian): " VAULT
fi

# Validate
if [ -f "$VAULT/CEO/inbox.md" ]; then
  echo "  Vault OK — CEO/inbox.md found at $VAULT/CEO/"
else
  echo "  WARNING: CEO/inbox.md not found at $VAULT/CEO/"
  echo "  Make sure Syncthing is running and the vault has fully synced."
  echo "  You can re-run 'ceo setup' after syncing to update the config."
fi

# Write ~/.ceo/config
mkdir -p "$HOME/.ceo"
cat > "$HOME/.ceo/config" << CEOCONF
# CEO agent configuration — written by ceo setup on $(date)
# Edit this file to change the vault path or OS hint.
CEO_VAULT="$VAULT"
CEO_OS="$CEO_OS"
CEOCONF
echo "  Config written: $HOME/.ceo/config"

# 10. Install cron via playbook scan
CEO_CLI="$SCRIPT_DIR/ceo"
if [ -f "$CEO_CLI" ] && command -v yq &>/dev/null; then
  echo ""
  echo "[10/10] Cron Setup"
  read -p "  Scan playbooks and install cron entries? (y/n) " INSTALL_CRON
  if [ "$INSTALL_CRON" = "y" ]; then
    bash "$CEO_CLI" playbook scan
  else
    echo "  Skipped. Run 'ceo playbook scan' later to install cron entries."
  fi
else
  echo ""
  echo "[10/10] Skipping cron setup (ceo CLI or yq not available)."
  echo "  Run 'ceo playbook scan' after installing yq."
fi

# 11. Add ceo CLI to PATH
CEO_CLI="$SCRIPT_DIR/ceo"
if [ -f "$CEO_CLI" ]; then
  # Check if already on PATH
  if command -v ceo &>/dev/null && [ "$(command -v ceo)" = "$CEO_CLI" ]; then
    echo ""
    echo "[11] ceo CLI already on PATH"
  elif command -v ceo &>/dev/null; then
    echo ""
    echo "[11] WARNING: 'ceo' already exists on PATH at $(command -v ceo)"
    echo "  Skipping — add an alias manually if needed:"
    echo "  echo 'alias ceo=\"$CEO_CLI\"' >> ~/.bashrc"
  else
    echo ""
    echo "[11] Add 'ceo' command to PATH?"
    echo "  This creates a symlink in ~/.local/bin/ so you can run 'ceo' from anywhere."
    read -p "  Add to PATH? (y/n) " ADD_PATH
    if [ "$ADD_PATH" = "y" ]; then
      mkdir -p "$HOME/.local/bin"
      ln -sf "$CEO_CLI" "$HOME/.local/bin/ceo"
      echo "  Symlinked: ~/.local/bin/ceo → $CEO_CLI"
      if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        echo "  NOTE: ~/.local/bin is not in your PATH yet."
        echo "  Add this to your ~/.bashrc or ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      fi
    fi
  fi
fi

# Write next steps to a file (claude login clears terminal history)
NEXT_STEPS="$INSTALL_DIR/next-steps.txt"
{
  echo "=== CEO Agent — Next Steps ==="
  echo ""
  echo "Setup finished $(date). Pick up here after claude login."
  echo ""
  echo "  1. Verify Syncthing is syncing the vault"
  echo "  2. Install yq if missing:  sudo snap install yq  (or: brew install yq)"
  echo "  3. Run: claude login  (if not already authenticated)"
  echo "  4. Run: claude plugin add nhangen/claude-ceo"
  echo "  5. Run: ceo doctor  (verify everything is configured)"
  echo "  6. Run: ceo playbook scan  (register playbooks + install cron)"
  echo "  7. Test interactive:  cd $VAULT && claude"
  echo "     Then type:  /ceo"
  echo "  8. Test cron:  ceo test"
  echo ""
  echo "Redisplay:  ceo next"
} > "$NEXT_STEPS"

echo ""
echo "=== Setup Complete ==="
echo ""
cat "$NEXT_STEPS"
echo ""
echo "NOTE: 'claude login' will clear your terminal."
echo "To redisplay:  ceo next"
echo "To verify:     ceo doctor"
