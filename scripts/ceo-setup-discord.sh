#!/bin/bash
set -euo pipefail

# ceo-setup-discord.sh — Configure Discord notifications interactively.

SECRETS_FILE="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"

# Try to resolve CEO_DIR if not exported
if [ -z "${CEO_DIR:-}" ]; then
  CONFIG_FILE="${CEO_CONFIG_FILE:-$HOME/.ceo/config}"
  if [ -f "$CONFIG_FILE" ]; then
    VAULT=$(jq -r '.vault // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    [ -n "$VAULT" ] && CEO_DIR="$VAULT/CEO"
  fi
  # Fallback to a safe default if still unresolved
  if [ -z "${CEO_DIR:-}" ]; then
    CEO_DIR="$HOME/Documents/Obsidian/CEO"
  fi
fi
SETTINGS_FILE="${CEO_DIR}/settings.json"

echo "=== Claude CEO Discord Setup ==="
echo ""

read -p "Enable Discord notifications? [y/N]: " ENABLED
if [[ ! "$ENABLED" =~ ^[Yy]$ ]]; then
  echo "Disabling notifications..."
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  if [ -f "$SETTINGS_FILE" ]; then
    TMP_SET=$(mktemp)
    jq '.notify_events = "off"' "$SETTINGS_FILE" > "$TMP_SET" && mv "$TMP_SET" "$SETTINGS_FILE"
  else
    echo '{"notify_events": "off"}' > "$SETTINGS_FILE"
  fi
  echo "Wrote notify_events=\"off\" to $SETTINGS_FILE"
  exit 0
fi

while true; do
  read -p "Webhook URL: " WEBHOOK
  if [[ "$WEBHOOK" =~ ^https://discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
    break
  fi
  echo "Invalid Discord webhook URL format. Must match ^https://discord.com/api/webhooks/..."
done

echo "Configuring webhook..."
mkdir -p "$(dirname "$SECRETS_FILE")"
chmod 0700 "$(dirname "$SECRETS_FILE")"
if [ -f "$SECRETS_FILE" ]; then
  TMP_SEC=$(mktemp)
  jq --arg w "$WEBHOOK" '.discord_webhook = $w' "$SECRETS_FILE" > "$TMP_SEC"
  mv "$TMP_SEC" "$SECRETS_FILE"
else
  jq -n --arg w "$WEBHOOK" '{discord_webhook: $w}' > "$SECRETS_FILE"
fi
chmod 0600 "$SECRETS_FILE"
echo "Saved webhook to $SECRETS_FILE (mode 0600)"

read -p "Notify on: (f)ailures only / (a)ll / (o)ff [f]: " NOTIFY_PREF
case "$NOTIFY_PREF" in
  [Aa]*) EVENT_VAL="all" ;;
  [Oo]*) EVENT_VAL="off" ;;
  *)     EVENT_VAL="failures" ;;
esac

mkdir -p "$(dirname "$SETTINGS_FILE")"
if [ -f "$SETTINGS_FILE" ]; then
  TMP_SET=$(mktemp)
  jq --arg e "$EVENT_VAL" '.notify_events = $e' "$SETTINGS_FILE" > "$TMP_SET"
  mv "$TMP_SET" "$SETTINGS_FILE"
else
  jq -n --arg e "$EVENT_VAL" '{notify_events: $e}' > "$SETTINGS_FILE"
fi
echo "Saved notify_events=\"$EVENT_VAL\" to $SETTINGS_FILE"

if [ "$EVENT_VAL" = "off" ]; then
  echo "Notifications are off; skipping test POST."
  exit 0
fi

echo ""
echo "Firing test POST..."
export CEO_NOTIFY_DEBUG_LOG="/tmp/ceo-notify-debug.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/ceo-notify.sh" failure setup-test "setup test"

LAST_LOG=$(tail -n 1 "$CEO_NOTIFY_DEBUG_LOG" 2>/dev/null || echo "")
echo "Result: $LAST_LOG"

if [[ "$LAST_LOG" != *"200"* && "$LAST_LOG" != *"204"* ]]; then
  echo "ERROR: Test POST failed. Double check the webhook URL."
  exit 1
fi

echo "Test POST succeeded!"
