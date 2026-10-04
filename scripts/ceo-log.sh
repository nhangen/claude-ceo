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

# grep -c prints 0 and exits 1 on no match, so "|| echo 0" appended a second
# zero (#600). Exit 2 is a read error: abort rather than report it as 0.
_count_matches() {
  local count rc=0
  count=$(grep -c "$1" "$2") || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ceo-log: could not read $2 (grep rc=$rc)" >&2
    return 2
  fi
  printf '%s' "$count"
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
# The writer templates ask the model for "- {any errors, or 'none'}", so an
# Errors section holding a none variant ("None.", "no errors") is not an error.
ERRORS=$(awk '
function is_none(s,   q) {
  q = sprintf("%c%c", 34, 39)
  s = tolower(s)
  sub(/^[[:space:]]*-?[[:space:]]*/, "", s)
  gsub("[" q "]", "", s)
  sub(/[[:space:]]*[.!]*[[:space:]]*$/, "", s)
  return s == "none" || s == "no errors" || s == "no error"
}
/^\*\*Errors:\*\*/ {
  rest = $0
  sub(/^\*\*Errors:\*\*/, "", rest)
  if (rest ~ /^[[:space:]]*$/) {
    pending = 1
  } else {
    pending = 0
    if (!is_none(rest)) count++
  }
  next
}
pending && /^[[:space:]]*$/ { next }
pending && /^(\*\*[^*]+:\*\*|#+ )/ { pending = 0; next }
pending {
  pending = 0
  if (!is_none($0)) count++
}
END { print count+0 }
' "$LOG_FILE")
if [ "$ERRORS" -gt 0 ]; then
  echo "**Errors:** $ERRORS entries with errors"
fi

# Check for delegations
DELEGATIONS=$(_count_matches "^\*\*Delegations:\*\*" "$LOG_FILE")
if [ "$DELEGATIONS" -gt 0 ]; then
  echo "**Delegations:** $DELEGATIONS logged"
fi
