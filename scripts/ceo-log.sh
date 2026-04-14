#!/bin/bash
set -euo pipefail

# ceo-log.sh — Display CEO execution log for a given date.
# Usage: ceo-log.sh [date|yesterday|today]
# Called by the /ceo:log skill to avoid an AI call for pure file display.

VAULT="${CEO_VAULT:-$HOME/Documents/Obsidian}"
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
cat "$LOG_FILE" | tail -n +8  # Skip frontmatter (first 7 lines: ---, date, type, ---, blank, # heading, blank)
echo ""

# Summary stats
TOTAL=$(grep -c "^\*\*Status:\*\*" "$LOG_FILE" 2>/dev/null || echo 0)
COMPLETED=$(grep -c "^\*\*Status:\*\* completed" "$LOG_FILE" 2>/dev/null || echo 0)
FAILED=$(grep -c "^\*\*Status:\*\* failed" "$LOG_FILE" 2>/dev/null || echo 0)
PARTIAL=$(grep -c "^\*\*Status:\*\* partial" "$LOG_FILE" 2>/dev/null || echo 0)

echo "---"
echo "**Summary:** $TOTAL actions ($COMPLETED completed, $FAILED failed, $PARTIAL partial)"

# Check for audibles
AUDIBLES=$(grep -c "^\*\*Audibles:\*\*" "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$AUDIBLES" -gt 0 ]; then
  echo "**Audibles:** $AUDIBLES logged"
fi

# Check for errors
ERRORS=$(grep -c "^\*\*Errors:\*\*" "$LOG_FILE" 2>/dev/null || echo 0)
ERROR_NONE=$(grep -c "^\*\*Errors:\*\*$\|^\- none" "$LOG_FILE" 2>/dev/null || echo 0)
REAL_ERRORS=$((ERRORS - ERROR_NONE))
if [ "$REAL_ERRORS" -gt 0 ]; then
  echo "**Errors:** $REAL_ERRORS entries with errors"
fi

# Check for delegations
DELEGATIONS=$(grep -c "^\*\*Delegations:\*\*" "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$DELEGATIONS" -gt 0 ]; then
  echo "**Delegations:** $DELEGATIONS logged"
fi
