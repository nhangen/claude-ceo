#!/bin/bash
set -euo pipefail

# setup-wsl.sh — Provision a WSL box as the CEO agent's execution environment.
# Run this once, interactively, on the WSL machine.

echo "=== CEO Agent — WSL Setup ==="
echo ""

# 1. System packages
echo "[1/7] Installing system packages..."
sudo apt update -qq
sudo apt install -y -qq git curl jq

# 2. GitHub CLI
if command -v gh &>/dev/null; then
  echo "[2/7] gh CLI already installed ($(gh --version | head -1))"
else
  echo "[2/7] Installing GitHub CLI..."
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
  echo "[3/7] SSH key already exists at $SSH_KEY"
else
  echo "[3/7] Generating SSH key..."
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
if ! grep -q "github_ceo" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" << 'SSHEOF'

Host github.com
  IdentityFile ~/.ssh/github_ceo
  IdentityFile ~/.ssh/id_ed25519
SSHEOF
  chmod 600 "$HOME/.ssh/config"
  echo "  SSH config updated"
fi

# 4. Git config
echo "[4/7] Configuring git..."
git config --global user.name "Nathan Hangen (CEO Agent)"
git config --global user.email "nhangen@users.noreply.github.com"

# 5. Syncthing
if command -v syncthing &>/dev/null; then
  echo "[5/7] Syncthing already installed"
else
  echo "[5/7] Installing Syncthing..."
  sudo apt install -y -qq syncthing
fi
echo "  Configure Syncthing to sync your Obsidian vault with your Mac."
echo "  Vault path on this machine: ~/Documents/Obsidian/"
echo "  See the CEO spec for write-domain rules."

# 6. Repo directory
echo "[6/7] Creating repo directory..."
mkdir -p "$HOME/repos"

# 7. Claude Code
if command -v claude &>/dev/null; then
  echo "[7/7] Claude Code already installed ($(claude --version 2>/dev/null || echo 'unknown version'))"
else
  echo "[7/7] Claude Code not found."
  echo "  Install it manually: https://claude.ai/download"
  echo "  After installing, run: claude login"
fi

# 8. Vault directory
VAULT="$HOME/Documents/Obsidian"
if [ -d "$VAULT/CEO" ]; then
  echo ""
  echo "CEO vault structure found at $VAULT/CEO/"
else
  echo ""
  echo "WARNING: CEO vault structure not found at $VAULT/CEO/"
  echo "  Make sure Syncthing is configured and the vault has synced."
fi

# 9. Install cron
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CRON="$SCRIPT_DIR/ceo-cron.sh"

if [ -f "$CEO_CRON" ]; then
  echo ""
  echo "=== Cron Setup ==="
  echo "Add these entries to your crontab (crontab -e):"
  echo ""
  echo "57 8 * * 1-5  $CEO_CRON morning-brief"
  echo "3 10 * * 1-5  $CEO_CRON pr-triage"
  echo "33 9 * * *    $CEO_CRON pending-drip"
  echo "47 17 * * 1-5 $CEO_CRON eod-summary"
  echo "7 3 * * 0     $CEO_CRON cleanup"
  echo ""
  read -p "Install these cron entries now? (y/n) " INSTALL_CRON
  if [ "$INSTALL_CRON" = "y" ]; then
    (crontab -l 2>/dev/null || true; echo "# CEO Agent
57 8 * * 1-5  $CEO_CRON morning-brief
3 10 * * 1-5  $CEO_CRON pr-triage
33 9 * * *    $CEO_CRON pending-drip
47 17 * * 1-5 $CEO_CRON eod-summary
7 3 * * 0     $CEO_CRON cleanup") | crontab -
    echo "Cron entries installed."
  fi
else
  echo ""
  echo "WARNING: ceo-cron.sh not found at $CEO_CRON"
fi

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. Verify Syncthing is syncing the vault"
echo "  2. Run: claude login (if not already authenticated)"
echo "  3. Test: $CEO_CRON morning-brief"
