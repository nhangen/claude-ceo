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
# Prior-day full report append (after the brief, morning-brief only by default):
#   $CEO_DIR/settings.json -> .discord_prior_day_report_triggers
#     Defaults to ["morning-brief"] when unset. Set [] to disable.
#
# Exits 0 always after argument validation; report delivery must not break cron.

# Sourced for _ceo_state_migrate and _ceo_registry_path: the delivery stamp below,
# the registry, and `ceo doctor`'s staleness check that reads them must resolve
# the same paths, and shared definitions are the only way to keep that true (#394, #401).
_DR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ceo-config.sh
source "$_DR_DIR/ceo-config.sh"

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

# Resolve a boolean delivery flag for $TRIGGER from the host-local registry
# (see _ceo_registry_path), written from playbook frontmatter by
# `ceo playbook scan`. Echoes `true`, `false`, or `absent`. `absent` covers a
# missing registry, a missing entry, or an entry that predates the flag field —
# in all three the caller falls back to the settings.json allow-list. Making the
# flag travel with the playbook is what stops a trigger rename from silently
# orphaning delivery (settings.json is hand-maintained and never synced to names).
_registry_report_flag() {
  local field="$1"
  local reg; reg="$(_ceo_registry_path)"
  if [ ! -f "$reg" ]; then
    # Field-qualified because both call sites reach here in one run; without it
    # the log holds two identical lines and reads as a retry loop.
    _dlog "registry file not found for $field ($reg)"
    echo absent
    return
  fi
  local val rc=0 errf
  errf=$(mktemp)
  trap 'rm -f "$errf"' RETURN
  # Deliberately avoid jq's `//` here: `false // "absent"` returns "absent"
  # because jq treats false as empty, which would collapse an explicit
  # discord_report:false into the settings fallback. Branch on array length and
  # an explicit null check instead so false stays distinct from absent.
  val=$(jq -r --arg t "$TRIGGER" --arg f "$field" \
    '[.playbooks[]? | select(.name==$t) | .[$f]] as $v
     | if ($v | length) == 0 then "absent"
       elif ($v[0] == null) then "absent"
       else ($v[0] | tostring) end' \
    "$reg" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # jq's own message, or a parse error and an EACCES look identical here and
    # have different repairs. Same reasoning as _registry_diag in ceo-cron.sh.
    # Returning absent fails open: an unparseable registry cannot be trusted to
    # mean suppression, so an explicit false collapses into the settings
    # fallback and this line is what makes that collapse auditable.
    _dlog "registry jq query failed for $field ($reg): $(head -1 "$errf")"
    echo absent
    return
  fi
  case "$val" in
    true|false) echo "$val" ;;
    *) echo absent ;;
  esac
}

_settings_report_flag() {
  local key="$1"
  local settings_file="${SETTINGS_FILE:-${CEO_DIR:-$HOME/Documents/Obsidian/CEO}/settings.json}"
  if [ ! -f "$settings_file" ]; then
    echo unset
    return
  fi
  local rc=0 out errf
  errf=$(mktemp)
  trap 'rm -f "$errf"' RETURN
  out=$(jq -r --arg trig "$TRIGGER" --arg key "$key" \
    '((.[$key] // ["morning-brief"]) | (index($trig) != null))' \
    "$settings_file" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    _dlog "settings jq query failed for $key ($settings_file): $(head -1 "$errf")"
    echo error
    return
  fi
  if [ -z "$out" ]; then
    _dlog "settings jq query produced no output for $key ($settings_file)"
    echo error
    return
  fi
  case "$out" in
    true)  echo 1 ;;
    false) echo 0 ;;
    *)
      _dlog "settings jq query produced unexpected output for $key ($settings_file): $out"
      echo error
      ;;
  esac
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
enabled=0
report_flag=$(_registry_report_flag discord_report)
case "$report_flag" in
  true)  enabled=1; _dlog "delivery enabled by registry discord_report flag" ;;
  false) enabled=0; _dlog "delivery disabled by registry discord_report flag" ;;
  absent)
    # Backward-compat fallback: no per-playbook flag in the registry, so honor
    # the hand-maintained settings.json allow-list (default: morning-brief only).
    case "$(_settings_report_flag discord_report_triggers)" in
      1) enabled=1 ;;
      0) enabled=0 ;;
      unset|error|*)
        [ "$TRIGGER" = "morning-brief" ] && enabled=1 || enabled=0
        ;;
    esac
    ;;
esac
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
  # Guarantee cleanup even if a command between here and the tail aborts under
  # set -e (RETURN fires on any function exit, unlike the prior bare tail rm).
  trap 'rm -rf "$cdir"' RETURN
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
  local sent=0 idx=0 chunk_file chunk message payload http_code
  for chunk_file in "$cdir"/chunk-*.txt; do
    [ -f "$chunk_file" ] || continue
    chunk=$(cat "$chunk_file")
    idx=$((idx + 1))
    if [ "$idx" -eq 1 ]; then
      message="$title

$chunk"
    else
      message="$chunk"
    fi
    payload=$(jq -n --arg content "$message" \
      '{username: "CEO Report", content: $content}')
    http_code=$(curl -sS -X POST -H "Content-Type: application/json" \
      --max-time 10 -w '%{http_code}' -o /dev/null -d "$payload" "$WEBHOOK" 2>/dev/null) || http_code=000
    if [[ $http_code =~ ^2[0-9]{2}$ ]]; then
      sent=$((sent + 1))
    else
      _dlog "post FAILED chunk=$idx status=$http_code"
    fi
  done
  printf '%s' "$sent"
}

total=0
sent=$(_post_report "**CEO full report: ${TRIGGER} — ${TODAY} (${HOSTNAME_SHORT})**" "$CONTENT")
total=$((total + sent))

# Delivery-success signal for `ceo doctor`: we passed the enabled-gate and posted
# the main report, so record when this trigger last DELIVERED. If the gate had
# blocked us (the allow-list bug that silently killed the morning report for a
# week), we'd have exited above and this timestamp would go stale — which is
# exactly what doctor watches for.
#
# Host-local, like the cooldown stamp doctor reads beside it: whether *this*
# machine delivered says nothing about whether another did. It lived under
# CEO/log/ with no shared.stignore entry at all, so it has been replicating
# between hosts — one host's delivery marking another's as fresh, which is the
# same defect this stamp exists to detect. Moved with the rest in #394.
if [ "$total" -gt 0 ]; then
  # The status is deliberately ignored here. It reports a state dir that could not
  # be created or a legacy file that could not be moved; either way this script
  # degrades to fresh state, and its own writes are already guarded. Only the cron
  # dispatcher refuses to run on rc=2, because only it half-applies bookkeeping.
  _deliver_stamp=$(_ceo_state_migrate ".last-deliver-${TRIGGER}") || true
  date +%s > "$_deliver_stamp" 2>/dev/null || true
fi

# Prior-day full report append (morning-brief only by default). The Obsidian
# report keeps its existing front matter and is untouched; the complete prior-day
# report is delivered here, on Discord only. Gate on its own allow-list so other
# report triggers don't carry yesterday's report.
prior_enabled=0
prior_flag=$(_registry_report_flag discord_prior_day_report)
case "$prior_flag" in
  true)  prior_enabled=1 ;;
  false) prior_enabled=0 ;;
  absent)
    case "$(_settings_report_flag discord_prior_day_report_triggers)" in
      1) prior_enabled=1 ;;
      0) prior_enabled=0 ;;
      unset|error|*)
        [ "$TRIGGER" = "morning-brief" ] && prior_enabled=1 || prior_enabled=0
        ;;
    esac
    ;;
esac

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
    else
      _dlog "prior-day report empty after front-matter strip date=$prior_date"
    fi
  else
    _dlog "no prior-day report found to append"
  fi
fi

_dlog "posted chunks=$total"
exit 0
