#!/bin/bash
# ceo-scan.sh — Gather vault state for morning scan.
# Source this file to export variables. Do not run standalone.
#
# Requires: CEO_VAULT or VAULT already set
# Exports:
#   VAULT_CHANGES_BY_DOMAIN, VAULT_CHANGES_COUNT
#   YESTERDAY_DAILY_NOTE, TODAY_DAILY_NOTE
#   PENDING_QUESTIONS, PENDING_APPROVALS_UNCHECKED
#   YESTERDAY_REPORT, FAILED_ACTIONS
#   ALERTS_FIRING

_SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=ceo-config.sh
source "$_SCAN_DIR/ceo-config.sh"

VAULT="${CEO_VAULT:-${VAULT:-$HOME/Documents/Obsidian}}"
CEO_DIR="$VAULT/CEO"
REPORT_DIR="$CEO_DIR/reports"
LOG_DIR="$CEO_DIR/log"
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
LAST_SCAN_MARKER="$LOG_DIR/.last-scan"

# --- Create scan marker if missing (first run = yesterday midnight) ---
if [ ! -f "$LAST_SCAN_MARKER" ]; then
  touch -t "$(date -d 'yesterday 00:00' +%Y%m%d%H%M.%S 2>/dev/null || date -v-1d -j -f '%H:%M' '00:00' +%Y%m%d%H%M.%S)" "$LAST_SCAN_MARKER" 2>/dev/null || touch "$LAST_SCAN_MARKER"
fi

# --- 1. Vault file changes since last scan ---
# Excludes:
#   .obsidian/    — editor metadata
#   CEO/log/      — append-only forensic history (per output-locations.md)
#   CEO/reports/  — CEO-generated reports
#   CEO/alerts/   — monitor state files (surfaced separately via ALERTS_FIRING below)
#   CEO/inbox/    — per-host task files; the inbox playbook handles these directly
VAULT_CHANGES_RAW=$(find "$VAULT" -newer "$LAST_SCAN_MARKER" -type f -name "*.md" \
  -not -path "*/.obsidian/*" \
  -not -path "*/CEO/log/*" \
  -not -path "*/CEO/reports/*" \
  -not -path "*/CEO/alerts/*" \
  -not -path "*/CEO/inbox/*" \
  -not -name "*.sync-conflict-*" \
  2>/dev/null || true)

if [ -z "$VAULT_CHANGES_RAW" ]; then
  export VAULT_CHANGES_COUNT=0
else
  export VAULT_CHANGES_COUNT=$(echo "$VAULT_CHANGES_RAW" | wc -l | xargs)
fi

# Categorize by domain (path prefix relative to vault)
VAULT_CHANGES_BY_DOMAIN=""
if [ -n "$VAULT_CHANGES_RAW" ]; then
  while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    rel="${filepath#$VAULT/}"
    domain=$(echo "$rel" | cut -d'/' -f1)
    VAULT_CHANGES_BY_DOMAIN="${VAULT_CHANGES_BY_DOMAIN}${domain}: ${rel}\n"
  done <<< "$VAULT_CHANGES_RAW"
fi
export VAULT_CHANGES_BY_DOMAIN

# --- 2. Yesterday's daily note (full content, max 10KB) ---
YESTERDAY_DAILY_FILE="$VAULT/Daily/$YESTERDAY.md"
if [ -f "$YESTERDAY_DAILY_FILE" ]; then
  export YESTERDAY_DAILY_NOTE=$(head -c 10000 "$YESTERDAY_DAILY_FILE")
else
  export YESTERDAY_DAILY_NOTE="No daily note for $YESTERDAY"
fi

# --- 3. Today's daily note (full content, max 10KB) ---
TODAY_DAILY_FILE="$VAULT/Daily/$TODAY.md"
if [ -f "$TODAY_DAILY_FILE" ]; then
  export TODAY_DAILY_NOTE=$(head -c 10000 "$TODAY_DAILY_FILE")
else
  export TODAY_DAILY_NOTE="No daily note for $TODAY yet"
fi

# --- 4. Pending/unresolved ---
PENDING_FILE="$VAULT/Pending.md"
if [ -f "$PENDING_FILE" ]; then
  export PENDING_QUESTIONS=$(head -c 5000 "$PENDING_FILE")
else
  export PENDING_QUESTIONS="No Pending.md found"
fi

APPROVALS_FILE="$CEO_DIR/approvals/pending.md"
if [ -f "$APPROVALS_FILE" ]; then
  export PENDING_APPROVALS_UNCHECKED=$(grep "^- \[ \]" "$APPROVALS_FILE" 2>/dev/null || echo "none")
else
  export PENDING_APPROVALS_UNCHECKED="none"
fi

# --- 5. Yesterday's report (carryover context) ---
YESTERDAY_REPORT_FILE="$REPORT_DIR/$YESTERDAY.md"
if [ -f "$YESTERDAY_REPORT_FILE" ]; then
  export YESTERDAY_REPORT=$(head -c 10000 "$YESTERDAY_REPORT_FILE")
else
  export YESTERDAY_REPORT="No report for $YESTERDAY"
fi

# Failed actions from yesterday's report
if [ -f "$YESTERDAY_REPORT_FILE" ]; then
  export FAILED_ACTIONS=$(grep -A2 "failed\|FAILED" "$YESTERDAY_REPORT_FILE" 2>/dev/null || echo "none")
else
  export FAILED_ACTIONS="none"
fi

# Surface only alerts whose `status:` frontmatter is "firing". Pulls host and
# transition timestamp from the same frontmatter; full reasons live in the
# alert body. Unknown status values are logged so a corrupt or typo'd alert
# file does not silently disappear from the morning scan.
ALERTS_DIR="$CEO_DIR/alerts"
ALERTS_FIRING=""
if [ -d "$ALERTS_DIR" ]; then
  for alert in "$ALERTS_DIR"/*.md; do
    [ -f "$alert" ] || continue
    status=$(ceo_read_alert_field "$alert" status)
    case "$status" in
      firing)
        name=$(basename "$alert" .md)
        host=$(ceo_read_alert_field "$alert" host)
        since=$(ceo_read_alert_field "$alert" since)
        ALERTS_FIRING="${ALERTS_FIRING}${name} (host=${host}, since=${since})\n"
        ;;
      clear|'')
        ;;
      *)
        printf 'WARN: ceo-scan: unknown alert status %q in %s; treating as not firing\n' \
          "$status" "$alert" >&2
        ;;
    esac
  done
fi
export ALERTS_FIRING
