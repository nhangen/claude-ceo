#!/bin/bash
# ceo-token-intake.sh — Daily RTK + token-scope spend intake.
# Captures four command outputs to CEO/reports/token/<TODAY>.md and idempotently
# appends one inbox line linking to it. The chat-triggered inbox playbook
# surfaces the line for morning discussion via `ceo chat inbox`.
#
# Invoked by ceo-cron.sh when the token-intake playbook (runner:script) fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
INBOX_FILE="$CEO_DIR/inbox.md"
TOKEN_DIR="$CEO_DIR/reports/token"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$TOKEN_DIR/$TODAY.md"
INBOX_LINE="- [ ] Review daily token report [[CEO/reports/token/$TODAY]]"

# bun lives in ~/.bun/bin; homebrew in /opt/homebrew/bin (Mac) or /usr/local/bin (Linux/WSL)
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

mkdir -p "$TOKEN_DIR"

# capture <label> <cmd> [args...] — run a command and wrap its output in a fenced block.
# Falls back to "<cmd> unavailable" so the inbox link always resolves to readable content.
capture() {
  local label="$1"; shift
  printf '\n## %s\n\n```\n' "$label"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 || printf '\n[command exited non-zero]\n'
  else
    printf '%s unavailable on PATH=%s\n' "$1" "$PATH"
  fi
  printf '```\n'
}

if ! {
  printf -- '---\ndate: %s\ntype: ceo-token-intake\n---\n\n' "$TODAY"
  printf '# Token Report — %s\n' "$TODAY"
  capture "RTK — global savings" rtk gain
  capture "RTK — current project" rtk gain -p
  capture "RTK — Claude Code economics" rtk cc-economics
  capture "token-scope — last 24h" token-scope --since 1d
} > "$REPORT_FILE"; then
  echo "ERROR: failed to write $REPORT_FILE" >&2
  exit 1
fi
[ -s "$REPORT_FILE" ] || { echo "ERROR: empty report $REPORT_FILE" >&2; exit 1; }

# Idempotently append the inbox line. Dedupe on the wikilink target
# rather than the full line so a `[x]` checkoff doesn't re-trigger the
# append.
touch "$INBOX_FILE"
WIKILINK="[[CEO/reports/token/$TODAY]]"
if ! grep -qF -- "$WIKILINK" "$INBOX_FILE"; then
  printf '%s\n' "$INBOX_LINE" >> "$INBOX_FILE"
fi

exit 0
