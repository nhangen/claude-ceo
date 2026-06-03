#!/bin/bash
set -euo pipefail

# ceo-report.sh — Append an entry to the CEO daily report with flock safety.
# Usage: ceo-report.sh <entry-type> <trigger-name> <content>
# Or:    echo "content" | ceo-report.sh <entry-type> <trigger-name>
#
# Entry types: intake, report, action
# Creates the report file with frontmatter if it doesn't exist.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ENTRY_TYPE="${1:?Usage: ceo-report.sh <intake|report|action> <trigger-name> [content]}"
TRIGGER_NAME="${2:?Usage: ceo-report.sh <intake|report|action> <trigger-name> [content]}"
CONTENT="${3:-}"

# Read from stdin if no content arg
if [ -z "$CONTENT" ] && [ ! -t 0 ]; then
  CONTENT=$(cat)
fi

if [ -z "$CONTENT" ]; then
  echo "ERROR: No content provided" >&2
  exit 1
fi

# Resolve vault — fail loud if unset (no silent provision under default).
ceo_require_vault
VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
REPORT_DIR="$CEO_DIR/reports"
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
REPORT_FILE="$REPORT_DIR/$TODAY.md"
LOCK_FILE="/tmp/ceo-report.lock"

mkdir -p "$REPORT_DIR"

# Acquire lock (flock on Linux, mkdir fallback on macOS)
if command -v flock &>/dev/null; then
  exec 201>"$LOCK_FILE"
  flock -w 10 201 || { echo "ERROR: Could not acquire report lock" >&2; exit 1; }
else
  LOCK_DIR="${LOCK_FILE}.d"
  _acquired=false
  for _i in $(seq 1 10); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      _acquired=true
      break
    fi
    sleep 1
  done
  $_acquired || { echo "ERROR: Could not acquire report lock" >&2; exit 1; }
  trap 'rmdir "'"$LOCK_DIR"'" 2>/dev/null' EXIT
fi

# Create report file with frontmatter if new
if [ ! -f "$REPORT_FILE" ]; then
  cat > "$REPORT_FILE" << HEADER
---
date: $TODAY
type: ceo-daily-report
---

# CEO Daily Report — $TODAY
HEADER
fi

HOST="${CEO_HOSTNAME:-$(hostname 2>/dev/null | cut -d. -f1 || echo "unknown")}"
OS="$(uname -s)"
META_BLOCK="> **Platform:** $HOST ($OS)"
if [ -n "${CEO_RUNNER:-}" ]; then
  META_BLOCK="$META_BLOCK
> **Agent:** $CEO_RUNNER (${CEO_MODEL:-unknown})"
fi

# Append entry
cat >> "$REPORT_FILE" << ENTRY

## $NOW — $TRIGGER_NAME [$ENTRY_TYPE]
$META_BLOCK

$CONTENT
ENTRY

# Optional side-channel delivery. The Obsidian report write above is canonical;
# Discord delivery is best-effort and must never make report capture fail.
if [ -x "$SCRIPT_DIR/ceo-discord-report.sh" ]; then
  printf '%s\n' "$CONTENT" | CEO_VAULT="$VAULT" CEO_DIR="$CEO_DIR" TODAY="$TODAY" \
    "$SCRIPT_DIR/ceo-discord-report.sh" "$TRIGGER_NAME" >/dev/null 2>&1 || true
fi

# Release lock (flock releases on fd close; mkdir trap handles the fallback)
