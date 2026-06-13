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
# Runner field:
#   One "Runner" embed field describing what the harness actually ran, built
#   from four env vars exported by ceo-cron.sh:
#     $CEO_RUNNER          harness: claude | ollama | script | skill
#     $CEO_MODEL           the model
#     $CEO_MODEL_SOURCE    "invoked" (claude/ollama drove the model) |
#                          "declared" (script/skill frontmatter claim — the
#                          harness drives no model itself)
#     $CEO_RUNNER_ARTIFACT script file / skill name the harness executed
#   Rendering:
#     claude/ollama (invoked)  -> "claude (opus-4.8)", "ollama (gemma4:12b-it-qat)"
#     script/skill (declared)  -> "script: ticket-triage-autopilot.sh (opus, declared)",
#                                 "skill: weekly-synthesis (opus, declared)"
#     script/skill, no model   -> "script: disk-monitor.sh", "skill: workload-report"
#   The "declared" marker keeps a frontmatter model claim from reading as an
#   observed fact. On the rate-limit fallback path $CEO_MODEL reflects the local
#   model actually invoked. The field is omitted only when runner, model, and
#   artifact are all unset (e.g. an early failure before the runner is resolved).
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
RUNNER="${CEO_RUNNER:-}"
MODEL="${CEO_MODEL:-}"
ARTIFACT="${CEO_RUNNER_ARTIFACT:-}"
MODEL_SOURCE="${CEO_MODEL_SOURCE:-}"
_dlog "runner='${RUNNER:-(unset)}' model='${MODEL:-(unset)}' source='${MODEL_SOURCE:-(unset)}' artifact='${ARTIFACT:-(unset)}'"

# Harness label, naming the script/skill artifact when the harness drove one.
RUNNER_LABEL="$RUNNER"
if [ -n "$ARTIFACT" ]; then
  if [ -n "$RUNNER" ]; then
    RUNNER_LABEL="$RUNNER: $ARTIFACT"
  else
    RUNNER_LABEL="$ARTIFACT"
  fi
fi

# A model the harness actually invoked (claude/ollama) renders bare; a
# frontmatter-declared model on a script/skill runner is marked "declared" so
# it reads as a claim, not an observed fact. Empty source (early/unknown path)
# renders bare; a non-empty value that is neither "invoked" nor "declared" is a
# caller bug — render bare (the weaker claim, can't falsely upgrade to declared)
# and log a diagnostic rather than silently coercing (enum-config-typo-fallback).
MODEL_SUFFIX=""
if [ -n "$MODEL" ]; then
  case "$MODEL_SOURCE" in
    declared)   MODEL_SUFFIX=" ($MODEL, declared)" ;;
    invoked|"") MODEL_SUFFIX=" ($MODEL)" ;;
    *)          _dlog "unrecognized CEO_MODEL_SOURCE='$MODEL_SOURCE' (expected invoked|declared) — rendering model bare"
                MODEL_SUFFIX=" ($MODEL)" ;;
  esac
fi

if [ -n "$RUNNER_LABEL" ]; then
  RUNNER_FIELD_VALUE="${RUNNER_LABEL}${MODEL_SUFFIX}"
else
  RUNNER_FIELD_VALUE="$MODEL"
fi

RUNNER_FIELD_PRESENT=0
if [ -n "$RUNNER" ] || [ -n "$MODEL" ] || [ -n "$ARTIFACT" ]; then
  RUNNER_FIELD_PRESENT=1
fi

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
  --arg trig   "$TRIGGER" \
  --arg host   "$HOSTNAME_SHORT" \
  --arg runnerfield "$RUNNER_FIELD_VALUE" \
  --arg haverunner  "$RUNNER_FIELD_PRESENT" \
  --arg ts     "$NOW" \
  --argjson color "$COLOR" \
  '{
     username: "CEO Cron",
     embeds: [{
       title: $title,
       description: $desc,
       color: $color,
       fields: (
         [ { name: "Trigger", value: $trig, inline: true } ]
         + (if $haverunner == "1"
            then [ { name: "Runner", value: $runnerfield, inline: true } ]
            else [] end)
         + [ { name: "Host", value: $host, inline: true },
             { name: "Time", value: $ts,   inline: false } ]
       )
     }]
   }')

_dlog "POSTing to Discord (payload bytes=${#PAYLOAD})"
CURL_OUT=$(curl -sS -o /dev/null -w '%{http_code} time=%{time_total}s' \
  -X POST -H "Content-Type: application/json" --max-time 10 \
  -d "$PAYLOAD" "$WEBHOOK" 2>&1) || CURL_OUT="curl-failed: $CURL_OUT"
_dlog "curl result: $CURL_OUT"

exit 0
