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
#
# Observability:
#   Every decision point (and curl outcome) writes to
#   ${CEO_NOTIFY_DEBUG_LOG:-/tmp/ceo-notify-debug.log} so silent bailouts
#   are recoverable. Set CEO_NOTIFY_DEBUG_LOG=/dev/null to suppress.

NOTIFY_LOG="${CEO_NOTIFY_DEBUG_LOG:-/tmp/ceo-notify-debug.log}"
_dlog() {
  printf '%s [%s/%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${STATUS:-?}" "${TRIGGER:-?}" "$*" \
    >> "$NOTIFY_LOG" 2>/dev/null || true
}

STATUS="${1:-}"
TRIGGER="${2:-}"
REASON="${3:-}"

_dlog "invoked rc-args=($#) HOME='${HOME:-}' PWD='$(pwd 2>/dev/null || echo ?)' PATH-prefix='${PATH:0:80}…'"

[ -n "$STATUS" ] && [ -n "$TRIGGER" ] || {
  _dlog "missing args, exiting 0"
  echo "Usage: ceo-notify.sh <success|failure> <trigger> [reason]" >&2
  exit 0
}

case "$STATUS" in
  success|failure) ;;
  *) _dlog "unknown status '$STATUS', exiting 0"
     echo "ceo-notify: unknown status '$STATUS' (expected: success|failure)" >&2; exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  _dlog "jq not on PATH, bailing 0"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  _dlog "curl not on PATH, bailing 0"
  exit 0
fi

SECRETS_FILE="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"
_dlog "secrets file: '$SECRETS_FILE' exists=$([ -f "$SECRETS_FILE" ] && echo 1 || echo 0)"

WEBHOOK="${CEO_DISCORD_WEBHOOK:-}"
if [ -z "$WEBHOOK" ] && [ -f "$SECRETS_FILE" ]; then
  WEBHOOK=$(jq -r '.discord_webhook // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
fi
if [ -z "$WEBHOOK" ]; then
  _dlog "webhook unresolved (env empty AND file missing/key absent), bailing 0"
  exit 0
fi
_dlog "webhook resolved length=${#WEBHOOK} prefix='${WEBHOOK:0:32}…'"

EVENTS="failures"
SETTINGS_FILE="${CEO_DIR:-$HOME/Documents/Obsidian/CEO}/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  EVENTS=$(jq -r '.notify_events // "failures"' "$SETTINGS_FILE" 2>/dev/null || echo "failures")
fi
_dlog "events='$EVENTS' settings='$SETTINGS_FILE' exists=$([ -f "$SETTINGS_FILE" ] && echo 1 || echo 0)"

case "$EVENTS" in
  off) _dlog "events=off, bailing 0"; exit 0 ;;
  failures)
    if [ "$STATUS" != "failure" ]; then
      _dlog "events=failures + status=$STATUS, bailing 0 (filtered)"
      exit 0
    fi
    ;;
  all) ;;
  *) _dlog "events='$EVENTS' unknown, defaulting to failures"
     echo "ceo-notify: unknown notify_events '$EVENTS' in $SETTINGS_FILE, defaulting to 'failures'" >&2
     EVENTS="failures"
     if [ "$STATUS" != "failure" ]; then
       _dlog "filtered (status=$STATUS), bailing 0"
       exit 0
     fi
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

_dlog "POSTing to Discord (payload bytes=${#PAYLOAD})"
CURL_OUT=$(curl -sS -o /dev/null -w '%{http_code} time=%{time_total}s' \
  -X POST -H "Content-Type: application/json" --max-time 10 \
  -d "$PAYLOAD" "$WEBHOOK" 2>&1) || CURL_OUT="curl-failed: $CURL_OUT"
_dlog "curl result: $CURL_OUT"

exit 0
