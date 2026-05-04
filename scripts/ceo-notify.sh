#!/bin/bash
set -euo pipefail

# ceo-notify.sh — Post a Discord notification for cron success/failure.
#
# Usage:
#   ceo-notify.sh success <trigger>
#   ceo-notify.sh failure <trigger> <reason>
#
# Webhook URL lookup order:
#   1. $CEO_DISCORD_WEBHOOK env var (testing convenience)
#   2. ~/.config/claude-ceo/secrets.json -> .discord_webhook
#
# Event filter (controls when notifications fire):
#   $CEO_VAULT/CEO/settings.json -> .notify_events
#     "failures" (default) | "all" | "off"
#
# Silent no-op if:
#   - no webhook configured
#   - notify_events is "off"
#   - notify_events is "failures" and status is "success"
#   - jq or curl missing
#
# Exits 0 always — notification failures must not break the cron pipeline.

STATUS="${1:-}"
TRIGGER="${2:-}"
REASON="${3:-}"

[ -n "$STATUS" ] && [ -n "$TRIGGER" ] || { echo "Usage: ceo-notify.sh <success|failure> <trigger> [reason]" >&2; exit 0; }

case "$STATUS" in
  success|failure) ;;
  *) echo "ceo-notify: unknown status '$STATUS' (expected: success|failure)" >&2; exit 0 ;;
esac

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

SECRETS_FILE="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"

WEBHOOK="${CEO_DISCORD_WEBHOOK:-}"
if [ -z "$WEBHOOK" ] && [ -f "$SECRETS_FILE" ]; then
  WEBHOOK=$(jq -r '.discord_webhook // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
fi
[ -n "$WEBHOOK" ] || exit 0

EVENTS="failures"
SETTINGS_FILE="${CEO_DIR:-$HOME/Documents/Obsidian/CEO}/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  EVENTS=$(jq -r '.notify_events // "failures"' "$SETTINGS_FILE" 2>/dev/null || echo "failures")
fi

case "$EVENTS" in
  off) exit 0 ;;
  failures) [ "$STATUS" = "failure" ] || exit 0 ;;
  all) ;;
  *) echo "ceo-notify: unknown notify_events '$EVENTS' in $SETTINGS_FILE, defaulting to 'failures'" >&2
     EVENTS="failures"
     [ "$STATUS" = "failure" ] || exit 0
     ;;
esac

HOSTNAME_SHORT="${CEO_HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

if [ "$STATUS" = "success" ]; then
  TITLE="🟢 ${TRIGGER} completed"
  COLOR=3066993
  DESCRIPTION="Status: completed"
else
  TITLE="🔴 ${TRIGGER} failed"
  COLOR=15158332
  DESCRIPTION="${REASON:-(no reason captured)}"
fi

PAYLOAD=$(jq -n \
  --arg title "$TITLE" \
  --arg desc  "$DESCRIPTION" \
  --arg trig  "$TRIGGER" \
  --arg host  "$HOSTNAME_SHORT" \
  --arg ts    "$NOW" \
  --argjson color "$COLOR" \
  '{
     username: "CEO Cron",
     embeds: [{
       title: $title,
       description: $desc,
       color: $color,
       fields: [
         { name: "Trigger", value: $trig, inline: true },
         { name: "Host",    value: $host, inline: true },
         { name: "Time",    value: $ts,   inline: false }
       ]
     }]
   }')

curl -s -o /dev/null -X POST \
  -H "Content-Type: application/json" \
  --max-time 10 \
  -d "$PAYLOAD" \
  "$WEBHOOK" \
  >/dev/null 2>&1 || true

exit 0
