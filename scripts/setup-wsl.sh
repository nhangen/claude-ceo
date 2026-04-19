#!/bin/bash
set -euo pipefail

# setup-wsl.sh — Provision a WSL box as the CEO agent's execution environment.
# Run this once, interactively, on the WSL machine.

echo "=== CEO Agent — WSL Setup ==="
echo ""

# 1. System packages
echo "[1/9] Installing system packages..."
sudo apt update -qq
sudo apt install -y -qq git curl jq

# 2. GitHub CLI
if command -v gh &>/dev/null; then
  echo "[2/9] gh CLI already installed ($(gh --version | head -1))"
else
  echo "[2/9] Installing GitHub CLI..."
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
  echo "[3/9] SSH key already exists at $SSH_KEY"
else
  echo "[3/9] Generating SSH key..."
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
echo "[4/9] Configuring git..."
git config --global user.name "Nathan Hangen (CEO Agent)"
git config --global user.email "nhangen@users.noreply.github.com"

# 5. Syncthing
# Syncthing — must be installed and configured separately (see README.md)
if command -v syncthing &>/dev/null; then
  echo "[5/9] Syncthing found"
else
  echo "[5/9] WARNING: Syncthing not found."
  echo "  Install Syncthing on all machines before proceeding."
  echo "  See README.md and syncthing/README.md for setup instructions."
fi

# 6. Repo directory
echo "[6/9] Creating repo directory..."
mkdir -p "$HOME/repos"

# 7. Claude Code
if command -v claude &>/dev/null; then
  echo "[7/9] Claude Code already installed ($(claude --version 2>/dev/null || echo 'unknown version'))"
else
  echo "[7/9] Claude Code not found."
  echo "  Install it manually: https://claude.ai/download"
  echo "  After installing, run: claude login"
fi

# 8. Vault directory
VAULT="$HOME/Documents/Obsidian"
if [ -d "$VAULT/CEO" ]; then
  echo ""
  echo "[8/9] CEO vault structure found at $VAULT/CEO/"
else
  echo ""
  echo "[8/9] WARNING: CEO vault structure not found at $VAULT/CEO/"
  echo "  Make sure Syncthing is configured and the vault has synced."
fi

# 9. Install cron
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CRON="$SCRIPT_DIR/ceo-cron.sh"

if [ -f "$CEO_CRON" ]; then
  echo ""
  echo "[9/9] Cron Setup"
  echo "Add these entries to your crontab (crontab -e):"
  echo ""
  echo "*/15 * * * *  $CEO_CRON inbox"
  echo "57 8 * * 1-5  $CEO_CRON morning-brief"
  echo "3 10 * * 1-5  $CEO_CRON pr-triage"
  echo "33 9 * * *    $CEO_CRON pending-drip"
  echo "47 17 * * 1-5 $CEO_CRON eod-summary"
  echo "7 3 * * 0     $CEO_CRON cleanup"
  echo ""
  read -p "Install these cron entries now? (y/n) " INSTALL_CRON
  if [ "$INSTALL_CRON" = "y" ]; then
    (crontab -l 2>/dev/null || true; echo "# CEO Agent
*/15 * * * *  $CEO_CRON inbox
57 8 * * 1-5  $CEO_CRON morning-brief
3 10 * * 1-5  $CEO_CRON pr-triage
33 9 * * *    $CEO_CRON pending-drip
47 17 * * 1-5 $CEO_CRON eod-summary
7 3 * * 0     $CEO_CRON cleanup") | crontab -
    echo "Cron entries installed."
  fi
else
  echo ""
  echo "[9/9] WARNING: ceo-cron.sh not found at $CEO_CRON"
fi

# Write next steps to a file (claude login clears terminal history)
NEXT_STEPS="$HOME/claude-ceo-next-steps.txt"
{
  echo "=== CEO Agent — Next Steps ==="
  echo ""
  echo "Setup finished $(date). Pick up here after claude login."
  echo ""
  echo "  1. Verify Syncthing is syncing the vault"
  echo "  2. Run: claude login  (if not already authenticated)"
  echo "  3. Run: claude plugin add nhangen/claude-ceo"
  echo "  4. Test interactive:  cd ~/Documents/Obsidian && claude"
  echo "     Then type:  /ceo"
  if [ -f "$CEO_CRON" ]; then
    echo "  5. Test cron:  $CEO_CRON morning-brief"
  else
    echo "  5. Test cron:  ~/claude-ceo/scripts/ceo-cron.sh morning-brief"
  fi
  echo "  6. Check output:  cat ~/Documents/Obsidian/CEO/log/$(date +%Y-%m-%d).md"
  echo "  7. Enable cron:  crontab -e  (entries were offered during setup)"
  echo ""
  echo "This file: $NEXT_STEPS  (safe to delete after you're done)"
} > "$NEXT_STEPS"

echo ""
echo "=== Setup Complete ==="
echo ""
cat "$NEXT_STEPS"
echo ""
echo "NOTE: 'claude login' will clear your terminal."
echo "These steps are saved to: $NEXT_STEPS"
