#!/bin/bash
# ceo-disk-monitor.sh — Hourly disk-state check on ML-1 (WSL2).
# State machine, not signal generator. Writes one state file (overwrite),
# one log line (append), and only touches the inbox on state transitions
# or sustained firing.
#
# Invoked by ceo-cron.sh when the disk-monitor playbook (runner:script) fires.
# Replaces the prior /home/nhang/disk-monitor.sh which appended to
# CEO/inbox/disk-alert.md unconditionally every hour.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

ALERTS_DIR="$CEO_DIR/alerts"
LOG_DIR="$CEO_DIR/log/disk-monitor"
INBOX_DIR="$CEO_DIR/inbox"
STATE_FILE="$ALERTS_DIR/disk-$HOST.md"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).md"
INBOX_FILE="$INBOX_DIR/$HOST.md"

mkdir -p "$ALERTS_DIR" "$LOG_DIR" "$INBOX_DIR"

# Paths are overridable so the test harness can drive without a real /mnt/c.
WSL_CRASHES_PATH="${CEO_DISK_WSL_CRASHES_PATH:-/mnt/c/Users/nhang/AppData/Local/Temp/wsl-crashes}"
C_MOUNT="${CEO_DISK_C_MOUNT:-/mnt/c}"
DUMP_THRESHOLD_GB=5
FREE_THRESHOLD_GB=50

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

# Read prior state from state file frontmatter.
# Exit code semantics (see ceo_read_alert_field):
#   rc=0  field present  → consume value
#   rc=1  file exists but field absent  → corruption, refuse to mutate inbox
#   rc=2  no state file (first run)     → empty PRIOR_STATUS = "clear"
PRIOR_STATUS=""
PRIOR_SINCE=""
_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *)
        printf 'WARN: ceo-disk-monitor: unrecognized prior status %q in %s; refusing inbox mutation\n' \
          "$PRIOR_STATUS" "$STATE_FILE" >&2
        PRIOR_STATUS="unknown"
        ;;
    esac
    ;;
  1)
    printf 'WARN: ceo-disk-monitor: state file %s present but missing status field; refusing inbox mutation\n' \
      "$STATE_FILE" >&2
    PRIOR_STATUS="unknown"
    ;;
  2)
    PRIOR_STATUS="clear"
    ;;
esac
# PRIOR_SINCE is optional: absent on first run (rc=2) or for a "clear" alert
# without a recorded transition. rc=1 (file exists, since field missing) is
# tolerated for mutation purposes — PRIOR_STATUS already determines whether we
# mutate — but the helper's stderr diagnostic is preserved so the operator
# sees the corruption signal alongside the PRIOR_STATUS warning above.
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since) || PRIOR_SINCE=""

# Measure. Any unreadable path or non-zero exit from du/df is
# MEASUREMENT_FAILED — we must NOT silently downgrade to clear.
MEASUREMENT_FAILED=0
DUMP_GB="?"
C_FREE_GB="?"

if [ -d "$WSL_CRASHES_PATH" ]; then
  _du_out=$(du -sBG "$WSL_CRASHES_PATH" 2>/dev/null) && _du_rc=0 || _du_rc=$?
  if [ "$_du_rc" -eq 0 ] && [ -n "$_du_out" ]; then
    DUMP_GB=$(printf '%s\n' "$_du_out" | awk '{sub(/G$/, "", $1); print int($1); exit}')
    [ -z "$DUMP_GB" ] && { MEASUREMENT_FAILED=1; DUMP_GB="?"; }
  else
    MEASUREMENT_FAILED=1
  fi
else
  MEASUREMENT_FAILED=1
fi

if [ -d "$C_MOUNT" ]; then
  _df_out=$(df -BG "$C_MOUNT" 2>/dev/null) && _df_rc=0 || _df_rc=$?
  if [ "$_df_rc" -eq 0 ] && [ -n "$_df_out" ]; then
    C_FREE_GB=$(printf '%s\n' "$_df_out" | awk 'NR==2 {sub(/G$/, "", $4); print int($4); exit}')
    [ -z "$C_FREE_GB" ] && { MEASUREMENT_FAILED=1; C_FREE_GB="?"; }
  else
    MEASUREMENT_FAILED=1
  fi
else
  MEASUREMENT_FAILED=1
fi

REASONS=()
if [ "$MEASUREMENT_FAILED" -eq 0 ]; then
  [ "$DUMP_GB" -gt "$DUMP_THRESHOLD_GB" ] && REASONS+=("wsl-crashes ${DUMP_GB}G > ${DUMP_THRESHOLD_GB}G")
  [ "$C_FREE_GB" -lt "$FREE_THRESHOLD_GB" ] && REASONS+=("C: free ${C_FREE_GB}G < ${FREE_THRESHOLD_GB}G")
fi

# Resolve CURRENT_STATUS.
# Measurement failure preserves PRIOR_STATUS so a transient du/df error
# cannot flip a firing alert to clear.
if [ "$MEASUREMENT_FAILED" -eq 1 ]; then
  printf 'WARN: ceo-disk-monitor: measurement failed; preserving prior status %q\n' "$PRIOR_STATUS" >&2
  case "$PRIOR_STATUS" in
    firing|clear) CURRENT_STATUS="$PRIOR_STATUS" ;;
    *)            CURRENT_STATUS="unknown" ;;
  esac
elif [ "${#REASONS[@]}" -gt 0 ]; then
  CURRENT_STATUS="firing"
else
  CURRENT_STATUS="clear"
fi

# SINCE only resets on a real transition into firing.
if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
fi

# Atomic write: render to a tmp file, rename on success. A failed
# ceo_write_alert_frontmatter (returns 1 on validation error) would otherwise
# leave $STATE_FILE half-truncated under the brace-group redirect.
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  printf 'ERROR: ceo-disk-monitor: mktemp failed for %s\n' "$STATE_FILE" >&2
  exit 1
}
trap 'rm -f "$STATE_TMP"' EXIT

if ! {
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field dump_folder_gb="$DUMP_GB" \
    --field c_free_gb="$C_FREE_GB" \
    --field measurement_failed="$MEASUREMENT_FAILED"
  printf '\n# Disk Monitor — %s\n\n' "$HOST"
  printf '<!-- alert: [[CEO/alerts/disk-%s]] -->\n\n' "$HOST"
  if [ "$CURRENT_STATUS" = "firing" ]; then
    printf 'Firing since %s.\n\n' "$SINCE"
    if [ "$MEASUREMENT_FAILED" -eq 1 ]; then
      printf 'Status preserved from prior run (measurement failed).\n\n'
    else
      printf '## Reasons\n\n'
      for r in "${REASONS[@]}"; do printf -- '- %s\n' "$r"; done
      printf '\n## Largest dumps\n\n```\n'
      [ -d "$WSL_CRASHES_PATH" ] && (ls -laSh "$WSL_CRASHES_PATH" 2>/dev/null | head -10 || echo "(unable to list)")
      printf '```\n\n## Resolution\n\nDelete unwanted dumps:\n\n```bash\nrm /mnt/c/Users/nhang/AppData/Local/Temp/wsl-crashes/*.dmp\n```\n'
    fi
  elif [ "$CURRENT_STATUS" = "clear" ]; then
    printf 'No active disk pressure. C: free %sG, wsl-crashes %sG.\n' "$C_FREE_GB" "$DUMP_GB"
  else
    printf 'Status unknown — measurement failed and no prior state available.\n'
  fi
} > "$STATE_TMP"; then
  printf 'ERROR: ceo-disk-monitor: failed to render state for %s; existing state preserved\n' "$STATE_FILE" >&2
  exit 1
fi

mv "$STATE_TMP" "$STATE_FILE"
trap - EXIT

if ! printf '%s status=%s dump=%sG free=%sG reasons="%s"\n' \
    "$NOW" "$CURRENT_STATUS" "$DUMP_GB" "$C_FREE_GB" "${REASONS[*]:-}" >> "$LOG_FILE" 2>/dev/null; then
  printf 'WARN: ceo-disk-monitor: failed to append log line to %s\n' "$LOG_FILE" >&2
fi

# Inbox escalation. Unknown prior or current status, or any measurement
# failure, suppresses all inbox mutation — we never escalate or clear on
# uncertain state.
#
# Dedupe and rewrite key off TASK_MARKER, an HTML comment embedded in the
# task line. The marker survives user reformats (translating the message,
# editing wording, adding context) so the same alert never produces two
# active task lines.
TASK_MARKER="<!-- disk-monitor:$HOST -->"
TASK_LINE="- [ ] Clean wsl-crashes on $HOST — see [[CEO/alerts/disk-$HOST]] $TASK_MARKER"
DONE_NOTE="- [done] disk monitor cleared $(date +%Y-%m-%d) — wsl-crashes ${DUMP_GB}G, C: ${C_FREE_GB}G free $TASK_MARKER"

touch "$INBOX_FILE"

active_task_present() {
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

if [ "$MEASUREMENT_FAILED" -eq 0 ] && [ "$PRIOR_STATUS" != "unknown" ] && [ "$CURRENT_STATUS" != "unknown" ]; then
  SUSTAINED=0
  if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" = "firing" ] && [ -n "$PRIOR_SINCE" ]; then
    SINCE_EPOCH=$(date -d "$PRIOR_SINCE" +%s 2>/dev/null \
      || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$PRIOR_SINCE" +%s 2>/dev/null \
      || echo 0)
    NOW_EPOCH=$(date +%s)
    if [ "$SINCE_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - SINCE_EPOCH)) -gt 86400 ]; then
      SUSTAINED=1
    fi
  fi

  if [ "$PRIOR_STATUS" = "clear" ] && [ "$CURRENT_STATUS" = "firing" ]; then
    active_task_present || printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  elif [ "$SUSTAINED" -eq 1 ]; then
    # Re-poke fires only if the prior unchecked task has been checked off
    # — `active_task_present` is false once the `[ ]` becomes `[x]` or
    # `[done]`, allowing the append.
    active_task_present || printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  elif [ "$PRIOR_STATUS" = "firing" ] && [ "$CURRENT_STATUS" = "clear" ]; then
    if active_task_present; then
      tmpfile=$(mktemp) || { echo "ERROR: ceo-disk-monitor: mktemp failed for inbox rewrite" >&2; exit 1; }
      trap 'rm -f "$tmpfile"' EXIT
      _done_replacement="- [done] Cleaned wsl-crashes on $HOST $(date +%Y-%m-%d) $TASK_MARKER"
      awk -v m="$TASK_MARKER" -v r="$_done_replacement" \
        '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$tmpfile"
      if ! mv "$tmpfile" "$INBOX_FILE"; then
        echo "ERROR: ceo-disk-monitor: failed to rewrite $INBOX_FILE" >&2
        exit 1
      fi
      trap - EXIT
      printf '%s\n' "$DONE_NOTE" >> "$INBOX_FILE"
    fi
  fi
fi

exit 0
