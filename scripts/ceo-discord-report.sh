#!/bin/bash
set -euo pipefail

# ceo-discord-report.sh — Post a full CEO report entry to a dedicated Discord webhook.
#
# Usage:
#   ceo-discord-report.sh <trigger> [content]
#   echo "content" | ceo-discord-report.sh <trigger>
#
# Webhook URL lookup order:
#   1. $CEO_DISCORD_REPORT_WEBHOOK env var
#   2. ~/.config/claude-ceo/secrets.json -> .discord_report_webhook
#
# Trigger filter:
#   $CEO_DIR/settings.json -> .discord_report_triggers
#     Defaults to ["morning-brief"] when unset. Set [] to disable.
#
# Exits 0 always after argument validation; report delivery must not break cron.

TRIGGER="${1:-}"
CONTENT="${2:-}"

[ -n "$TRIGGER" ] || {
  echo "Usage: ceo-discord-report.sh <trigger> [content]" >&2
  exit 0
}

if [ -z "$CONTENT" ] && [ ! -t 0 ]; then
  CONTENT=$(cat)
fi

[ -n "$CONTENT" ] || exit 0

_dlog() {
  local log="${CEO_DISCORD_REPORT_DEBUG_LOG:-/tmp/ceo-discord-report-debug.log}"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TRIGGER" "$*" \
    >> "$log" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
  _dlog "jq not on PATH, bailing 0"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  _dlog "curl not on PATH, bailing 0"
  exit 0
fi

SETTINGS_FILE="${CEO_DIR:-$HOME/Documents/Obsidian/CEO}/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  enabled=$(jq -e --arg trig "$TRIGGER" \
    '(.discord_report_triggers // ["morning-brief"]) | index($trig) != null' \
    "$SETTINGS_FILE" >/dev/null 2>&1 && echo 1 || echo 0)
else
  [ "$TRIGGER" = "morning-brief" ] && enabled=1 || enabled=0
fi
[ "$enabled" = "1" ] || {
  _dlog "trigger not enabled for full report delivery"
  exit 0
}

SECRETS_FILE="${CEO_SECRETS_FILE:-$HOME/.config/claude-ceo/secrets.json}"
WEBHOOK="${CEO_DISCORD_REPORT_WEBHOOK:-}"
if [ -z "$WEBHOOK" ] && [ -f "$SECRETS_FILE" ]; then
  WEBHOOK=$(jq -r '.discord_report_webhook // ""' "$SECRETS_FILE" 2>/dev/null || echo "")
fi
[ -n "$WEBHOOK" ] || {
  _dlog "report webhook unresolved, bailing 0"
  exit 0
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

printf '%s\n' "$CONTENT" | awk -v dir="$tmp_dir" -v max=1800 '
  function flush() {
    if (chunk != "") {
      n += 1
      file = sprintf("%s/chunk-%04d.txt", dir, n)
      printf "%s", chunk > file
      close(file)
      chunk = ""
    }
  }
  {
    line = $0 "\n"
    if (length(chunk) + length(line) > max) {
      flush()
    }
    while (length(line) > max) {
      n += 1
      file = sprintf("%s/chunk-%04d.txt", dir, n)
      printf "%s", substr(line, 1, max) > file
      close(file)
      line = substr(line, max + 1)
    }
    chunk = chunk line
  }
  END { flush() }
'

HOSTNAME_SHORT="${CEO_HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}"
TODAY="${TODAY:-$(date +%Y-%m-%d)}"
sent=0

for chunk_file in "$tmp_dir"/chunk-*.txt; do
  [ -f "$chunk_file" ] || continue
  chunk=$(cat "$chunk_file")
  sent=$((sent + 1))
  if [ "$sent" -eq 1 ]; then
    message="**CEO full report: ${TRIGGER} — ${TODAY} (${HOSTNAME_SHORT})**

$chunk"
  else
    message="$chunk"
  fi

  payload=$(jq -n --arg content "$message" \
    '{username: "CEO Report", content: $content}')
  curl -sS -o /dev/null -X POST -H "Content-Type: application/json" \
    --max-time 10 -d "$payload" "$WEBHOOK" >/dev/null 2>&1 || true
done

_dlog "posted chunks=$sent"
exit 0
