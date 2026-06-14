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

HOSTNAME_SHORT="${CEO_HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}"
TODAY="${TODAY:-$(date +%Y-%m-%d)}"

# Post a body to the report webhook, chunked to Discord's per-message limit. The
# first message carries the bold title; continuation chunks are bare. Echoes the
# number of messages sent.
_post_report() {
  local title="$1" body="$2"
  local cdir; cdir=$(mktemp -d)
  printf '%s\n' "$body" | awk -v dir="$cdir" -v max=1800 '
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
  local sent=0 chunk_file chunk message payload
  for chunk_file in "$cdir"/chunk-*.txt; do
    [ -f "$chunk_file" ] || continue
    chunk=$(cat "$chunk_file")
    sent=$((sent + 1))
    if [ "$sent" -eq 1 ]; then
      message="$title

$chunk"
    else
      message="$chunk"
    fi
    payload=$(jq -n --arg content "$message" \
      '{username: "CEO Report", content: $content}')
    curl -sS -o /dev/null -X POST -H "Content-Type: application/json" \
      --max-time 10 -d "$payload" "$WEBHOOK" >/dev/null 2>&1 || true
  done
  rm -rf "$cdir"
  printf '%s' "$sent"
}

total=0
sent=$(_post_report "**CEO full report: ${TRIGGER} — ${TODAY} (${HOSTNAME_SHORT})**" "$CONTENT")
total=$((total + sent))

# Prior-day full report append (morning-brief only by default). The Obsidian
# report keeps its existing front matter and is untouched; the complete prior-day
# report is delivered here, on Discord only. Gate on its own allow-list so other
# report triggers don't carry yesterday's report.
if [ -f "$SETTINGS_FILE" ]; then
  prior_enabled=$(jq -e --arg trig "$TRIGGER" \
    '(.discord_prior_day_report_triggers // ["morning-brief"]) | index($trig) != null' \
    "$SETTINGS_FILE" >/dev/null 2>&1 && echo 1 || echo 0)
else
  [ "$TRIGGER" = "morning-brief" ] && prior_enabled=1 || prior_enabled=0
fi

if [ "$prior_enabled" = "1" ]; then
  report_dir="${CEO_DIR:-$HOME/Documents/Obsidian/CEO}/reports"
  prior_base=""
  if [ -d "$report_dir" ]; then
    # Most recent dated report strictly before today (the glob is lexically sorted
    # and lexical == chronological for YYYY-MM-DD), so a Monday brief surfaces
    # Friday's report, not an empty Sunday.
    shopt -s nullglob
    for _rf in "$report_dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
      _rb=$(basename "$_rf")
      [ "$_rb" \< "${TODAY}.md" ] && prior_base="$_rb"
    done
    shopt -u nullglob
  fi
  if [ -n "$prior_base" ] && [ -s "$report_dir/$prior_base" ]; then
    prior_date="${prior_base%.md}"
    # Strip a leading YAML front-matter block — it is Obsidian metadata, noise on Discord.
    prior_body=$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm {print}' \
      "$report_dir/$prior_base")
    if [ -n "${prior_body//[[:space:]]/}" ]; then
      psent=$(_post_report "**📄 Prior-day full report — ${prior_date}**" "$prior_body")
      total=$((total + psent))
      _dlog "prior-day report posted date=$prior_date chunks=$psent"
    fi
  else
    _dlog "no prior-day report found to append"
  fi
fi

_dlog "posted chunks=$total"
exit 0
