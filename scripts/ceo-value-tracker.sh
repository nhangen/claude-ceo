#!/bin/bash
# ceo-value-tracker.sh — Daily MCP tool-call value report.
# Invokes lib/value-tracker over the last 24h, writing an Obsidian note and a
# JSON snapshot. Idempotently appends one inbox line linking to the note so the
# chat-triggered inbox playbook surfaces it.
#
# Invoked by ceo-cron.sh when the value-tracker playbook (runner:script) fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/value-tracker"
ENTRY="$LIB_DIR/src/cli.ts"

# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }

# Validate before any helper that reads $HOME. `set -u` does not catch
# HOME="" (set-but-empty); that's the cron / stripped-env shape from PR #11
# where ceo_augment_path emits dangling `/.bun/bin` paths silently.
: "${HOME:?HOME must be set}"

# Pin $HOME before PATH augmentation so cron-stripped env still resolves bun.
ceo_pin_home_or_warn || true
ceo_augment_path

: "${CEO_VAULT:?CEO_VAULT must be set}"

if ! command -v bun >/dev/null 2>&1; then
  echo "ERROR: bun not on PATH; cannot run value-tracker" >&2
  exit 1
fi

if [ ! -f "$ENTRY" ]; then
  echo "ERROR: value-tracker entry not found at $ENTRY" >&2
  exit 1
fi

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"
INBOX_DIR="$CEO_DIR/inbox"
INBOX_FILE="$INBOX_DIR/$HOST.md"
TODAY=$(date +%Y-%m-%d)
SINCE=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null || true)
: "${SINCE:?SINCE computation failed; neither BSD nor GNU date resolved (check cron PATH)}"

NOTE_DIR="$VAULT/Projects/Development/nhangen/claude-ceo/value-tracker"
NOTE_PATH="$NOTE_DIR/$TODAY.md"
WIKILINK="[[Projects/Development/nhangen/claude-ceo/value-tracker/$TODAY]]"
INBOX_LINE="- [ ] Review daily value-tracker report $WIKILINK"

mkdir -p "$INBOX_DIR" "$NOTE_DIR"

# Run the analyser. --obsidian-vault is auto-detected from $HOME/Documents/Obsidian
# but pass it explicitly so non-default vault paths work via $CEO_VAULT.
bun "$ENTRY" \
  --since "$SINCE" \
  --obsidian-vault "$VAULT"

# Idempotent inbox append — skip if the line is already there.
if [ ! -f "$INBOX_FILE" ] || ! grep -qF -- "$WIKILINK" "$INBOX_FILE"; then
  printf '%s\n' "$INBOX_LINE" >> "$INBOX_FILE"
fi
