#!/bin/bash
set -euo pipefail

# ceo-log.sh — Display CEO execution log for a given date.
# Usage: ceo-log.sh [date|yesterday|today]
# Called by the /ceo:log skill to avoid an AI call for pure file display.

_LOG_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$_LOG_DIR/ceo-config.sh"
ceo_require_vault
VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
LOG_DIR="$CEO_DIR/log"

# Parse date argument
ARG="${1:-today}"
case "$ARG" in
  today)
    DATE=$(date +%Y-%m-%d)
    ;;
  yesterday)
    # macOS and Linux compatible
    DATE=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
    ;;
  *)
    DATE="$ARG"
    ;;
esac

LOG_FILE="$LOG_DIR/$DATE.md"

if [ ! -f "$LOG_FILE" ]; then
  echo "No CEO activity logged for $DATE."
  exit 0
fi

# Display the log
echo "## CEO Log — $DATE"
echo ""
sed -n '/^## /,$p' "$LOG_FILE"  # Skip frontmatter and heading, start at first ## entry
echo ""

# Helper to count matches without grep -c failing under set -euo pipefail
# or appending a second zero under || echo 0 (#600).
_count_matches() {
  local pattern="$1" file="$2" count
  count=$(grep -c "$pattern" "$file" 2>/dev/null || true)
  printf '%s' "${count:-0}"
}

# Summary stats
TOTAL=$(_count_matches "^\*\*Status:\*\*" "$LOG_FILE")
COMPLETED=$(_count_matches "^\*\*Status:\*\* completed" "$LOG_FILE")
FAILED=$(_count_matches "^\*\*Status:\*\* failed" "$LOG_FILE")
PARTIAL=$(_count_matches "^\*\*Status:\*\* partial" "$LOG_FILE")

echo "---"
echo "**Summary:** $TOTAL actions ($COMPLETED completed, $FAILED failed, $PARTIAL partial)"

# Check for audibles
AUDIBLES=$(_count_matches "^\*\*Audibles:\*\*" "$LOG_FILE")
if [ "$AUDIBLES" -gt 0 ]; then
  echo "**Audibles:** $AUDIBLES logged"
fi

# Check for errors
ERRORS=$(_count_matches "^\*\*Errors:\*\*" "$LOG_FILE")
ERROR_NONE=$(_count_matches "^\*\*Errors:\*\*$\|^\- none" "$LOG_FILE")
REAL_ERRORS=$((ERRORS - ERROR_NONE))
if [ "$REAL_ERRORS" -gt 0 ]; then
  echo "**Errors:** $REAL_ERRORS entries with errors"
fi

# Check for delegations
DELEGATIONS=$(_count_matches "^\*\*Delegations:\*\*" "$LOG_FILE")
if [ "$DELEGATIONS" -gt 0 ]; then
  echo "**Delegations:** $DELEGATIONS logged"
fi
