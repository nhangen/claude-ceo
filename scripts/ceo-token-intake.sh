#!/bin/bash
# ceo-token-intake.sh — Daily RTK + token-scope spend intake.
# Captures four command outputs to CEO/reports/token/<TODAY>-<host>.md and
# idempotently appends one inbox line to CEO/inbox/<host>.md linking to it.
# Per-host filenames keep two Syncthing peers from racing on the same path.
# The chat-triggered inbox playbook surfaces the line via `ceo chat inbox`.
#
# Invoked by ceo-cron.sh when the token-intake playbook (runner:script) fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_augment_path

# rtk and ccusage discover their state via $HOME-rooted paths
# (Library/Application Support/rtk/history.db on Mac, .local/share on Linux).
# Pin $HOME to the running user's canonical home so we read the real DBs even
# if invoked from a context that scrubbed or sandboxed $HOME. Without this,
# rtk silently returns "No tracking data yet" and the report ships empty.
if real_home=$(ceo_resolve_real_home); then
  export HOME="$real_home"
fi

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"
INBOX_DIR="$CEO_DIR/inbox"
INBOX_FILE="$INBOX_DIR/$HOST.md"
TOKEN_DIR="$CEO_DIR/reports/token"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$TOKEN_DIR/$TODAY-$HOST.md"
WIKILINK="[[CEO/reports/token/$TODAY-$HOST]]"
INBOX_LINE="- [ ] Review daily token report $WIKILINK"

mkdir -p "$TOKEN_DIR" "$INBOX_DIR"

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
if ! grep -qF -- "$WIKILINK" "$INBOX_FILE"; then
  printf '%s\n' "$INBOX_LINE" >> "$INBOX_FILE"
fi

exit 0
