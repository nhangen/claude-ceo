#!/bin/bash
# ceo-disk-monitor.sh — Hourly disk-state check on ML-1 (WSL2).
# State machine, not signal generator. Writes one state file (overwrite),
# one log line (append), and only touches the inbox on state transitions
# or sustained firing.
#
# Invoked by ceo-cron.sh when the disk-monitor playbook (runner:script) fires.
# Replaces the prior /home/nhang/disk-monitor.sh which appended to
# CEO/inbox/disk-alert.md unconditionally every hour.

set -euo pipefail

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
STATE_FILE="$ALERTS_DIR/disk.md"
LOG_FILE="$LOG_DIR/$(date +%Y-%m).md"
INBOX_FILE="$INBOX_DIR/$HOST.md"

mkdir -p "$ALERTS_DIR" "$LOG_DIR" "$INBOX_DIR"

# Thresholds
WSL_CRASHES_PATH="/mnt/c/Users/nhang/AppData/Local/Temp/wsl-crashes"
DUMP_THRESHOLD_GB=5
FREE_THRESHOLD_GB=50

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)
TODAY=$(date +%Y-%m-%d)

# --- Measure current state ---
# Use safe defaults so a read error doesn't false-clear an alert.
DUMP_GB=0
if [ -d "$WSL_CRASHES_PATH" ]; then
  DUMP_GB=$(du -sBG "$WSL_CRASHES_PATH" 2>/dev/null | awk '{sub(/G$/, "", $1); print int($1)}') || DUMP_GB=0
fi

C_FREE_GB=999
if [ -d "/mnt/c" ]; then
  C_FREE_GB=$(df -BG /mnt/c 2>/dev/null | awk 'NR==2 {sub(/G$/, "", $4); print int($4)}') || C_FREE_GB=999
fi

REASONS=()
[ "$DUMP_GB" -gt "$DUMP_THRESHOLD_GB" ] && REASONS+=("wsl-crashes ${DUMP_GB}G > ${DUMP_THRESHOLD_GB}G")
[ "$C_FREE_GB" -lt "$FREE_THRESHOLD_GB" ] && REASONS+=("C: free ${C_FREE_GB}G < ${FREE_THRESHOLD_GB}G")

if [ "${#REASONS[@]}" -gt 0 ]; then
  CURRENT_STATUS="firing"
else
  CURRENT_STATUS="clear"
fi

# --- Read prior state from state file frontmatter ---
PRIOR_STATUS="clear"
PRIOR_SINCE=""
if [ -f "$STATE_FILE" ]; then
  PRIOR_STATUS=$(awk -F': *' '/^status:/ {print $2; exit}' "$STATE_FILE" | tr -d '[:space:]')
  PRIOR_SINCE=$(awk -F': *' '/^since:/ {print $2; exit}' "$STATE_FILE" | tr -d '[:space:]')
  [ -z "$PRIOR_STATUS" ] && PRIOR_STATUS="clear"
fi

if [ "$CURRENT_STATUS" = "firing" ]; then
  SINCE="${PRIOR_SINCE:-$NOW}"
  [ "$PRIOR_STATUS" = "clear" ] && SINCE="$NOW"
else
  SINCE="$NOW"
fi

# --- Write state file (overwrite) ---
{
  printf -- '---\n'
  printf 'status: %s\n' "$CURRENT_STATUS"
  printf 'since: %s\n' "$SINCE"
  printf 'last_check: %s\n' "$NOW"
  printf 'host: %s\n' "$HOST"
  printf 'dump_folder_gb: %s\n' "$DUMP_GB"
  printf 'c_free_gb: %s\n' "$C_FREE_GB"
  printf -- '---\n\n'
  printf '# Disk Monitor — %s\n\n' "$HOST"
  if [ "$CURRENT_STATUS" = "firing" ]; then
    printf 'Firing since %s.\n\n' "$SINCE"
    printf '## Reasons\n\n'
    for r in "${REASONS[@]}"; do printf -- '- %s\n' "$r"; done
    printf '\n## Largest dumps\n\n```\n'
    if [ -d "$WSL_CRASHES_PATH" ]; then
      ls -laSh "$WSL_CRASHES_PATH" 2>/dev/null | head -10 || echo "(unable to list)"
    fi
    printf '```\n\n## Resolution\n\nDelete unwanted dumps:\n\n```bash\nrm /mnt/c/Users/nhang/AppData/Local/Temp/wsl-crashes/*.dmp\n```\n'
  else
    printf 'No active disk pressure. C: free %sG, wsl-crashes %sG.\n' "$C_FREE_GB" "$DUMP_GB"
  fi
} > "$STATE_FILE"

# --- Append log line ---
printf '%s status=%s dump=%sG free=%sG reasons="%s"\n' \
  "$NOW" "$CURRENT_STATUS" "$DUMP_GB" "$C_FREE_GB" "${REASONS[*]:-}" >> "$LOG_FILE"

# --- Inbox escalation rules ---
TASK_LINE="- [ ] Clean wsl-crashes on $HOST — see [[CEO/alerts/disk]]"
DONE_NOTE="- [done] disk monitor cleared $(date +%Y-%m-%d) — wsl-crashes ${DUMP_GB}G, C: ${C_FREE_GB}G free"

touch "$INBOX_FILE"

# Sustained-firing check: if firing for >24h AND task line not present, append it.
SUSTAINED=0
if [ "$CURRENT_STATUS" = "firing" ]; then
  if [ -n "$PRIOR_SINCE" ]; then
    SINCE_EPOCH=$(date -d "$PRIOR_SINCE" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    if [ "$SINCE_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - SINCE_EPOCH)) -gt 86400 ]; then
      SUSTAINED=1
    fi
  fi
fi

if [ "$PRIOR_STATUS" = "clear" ] && [ "$CURRENT_STATUS" = "firing" ]; then
  # Transition: clear → firing. Idempotent — only append if not already there.
  if ! grep -qF -- "$TASK_LINE" "$INBOX_FILE"; then
    printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  fi
elif [ "$SUSTAINED" -eq 1 ]; then
  # Sustained firing — same idempotency.
  if ! grep -qF -- "$TASK_LINE" "$INBOX_FILE"; then
    printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  fi
elif [ "$PRIOR_STATUS" = "firing" ] && [ "$CURRENT_STATUS" = "clear" ]; then
  # Transition: firing → clear. Flip the task and append a resolution note.
  if grep -qF -- "$TASK_LINE" "$INBOX_FILE"; then
    # Replace the - [ ] task with - [done]. Use a temp file because sed -i differs across platforms.
    tmpfile=$(mktemp)
    sed "s|^- \[ \] Clean wsl-crashes on $HOST.*|- [done] Cleaned wsl-crashes on $HOST $(date +%Y-%m-%d)|" "$INBOX_FILE" > "$tmpfile"
    mv "$tmpfile" "$INBOX_FILE"
    printf '%s\n' "$DONE_NOTE" >> "$INBOX_FILE"
  fi
fi

exit 0
