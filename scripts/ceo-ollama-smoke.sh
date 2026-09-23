#!/usr/bin/env bash
# ceo-ollama-smoke.sh — weekly live-stack canary (#276). Runs
# ollama-agent/tests/integration_smoke.sh and keeps CEO/alerts/ollama-smoke.md
# as a state machine: overwrite with current state, escalate to the inbox only
# on a transition into firing, resolve the task only on a fully verified pass.
#
# Invoked by ceo-cron.sh when the ollama-smoke playbook (runner:script) fires.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_augment_path

CEO_DIR="$CEO_VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s 2>/dev/null)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

SMOKE_BIN="${OLLAMA_SMOKE_BIN:-$SCRIPT_DIR/../ollama-agent/tests/integration_smoke.sh}"
if [ ! -x "$SMOKE_BIN" ]; then
  echo "ERROR: integration_smoke.sh not found or not executable at $SMOKE_BIN" >&2
  exit 1
fi

ALERTS_DIR="$CEO_DIR/alerts"
INBOX_DIR="$CEO_DIR/inbox"
STATE_FILE="$ALERTS_DIR/ollama-smoke.md"
INBOX_FILE="$INBOX_DIR/ollama-smoke.md"
mkdir -p "$ALERTS_DIR" "$INBOX_DIR" || { echo "ERROR: cannot create $ALERTS_DIR or $INBOX_DIR" >&2; exit 1; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Prior state. rc=1 (file present, status missing) or an unrecognized value is
# corruption: we still write the current state, but never touch the inbox on it.
PRIOR_STATUS=""
_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *)
        printf 'WARN: ceo-ollama-smoke: unrecognized prior status %q in %s; refusing inbox mutation\n' \
          "$PRIOR_STATUS" "$STATE_FILE" >&2
        PRIOR_STATUS="unknown"
        ;;
    esac
    ;;
  1)
    printf 'WARN: ceo-ollama-smoke: %s has no status field; refusing inbox mutation\n' "$STATE_FILE" >&2
    PRIOR_STATUS="unknown"
    ;;
  2) PRIOR_STATUS="clear" ;;
esac
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since 2>/dev/null) || PRIOR_SINCE=""

# The smoke drives `claude -p` and `oll-code -p` with no cap of its own, and the
# script runner holds the global cron lock, so a hung model call would stall
# every playbook on the host.
SMOKE_TIMEOUT="${OLLAMA_SMOKE_TIMEOUT:-900}"
# The smoke defaults to gpt-oss:20b; the owner host may serve a different model.
if [ -n "${OLLAMA_SMOKE_MODEL:-}" ]; then
  export OLL_MODEL="$OLLAMA_SMOKE_MODEL"
fi
ceo_resolve_timeout_bin
SMOKE_RC=0
if [ -n "$CEO_TIMEOUT_BIN" ]; then
  OUTPUT=$("$CEO_TIMEOUT_BIN" "$SMOKE_TIMEOUT" bash "$SMOKE_BIN" 2>&1) || SMOKE_RC=$?
else
  echo "warning: no timeout or gtimeout on PATH; running the smoke with no ${SMOKE_TIMEOUT}s cap" >&2
  OUTPUT=$(bash "$SMOKE_BIN" 2>&1) || SMOKE_RC=$?
fi
OUTPUT=$(printf '%s' "$OUTPUT" | sed $'s/\033\\[[0-9;]*m//g')

PASS="?"; FAIL="?"; SKIP="?"
HARNESS_ERROR=""
if [ "$SMOKE_RC" -eq 124 ]; then
  HARNESS_ERROR="timed out after ${SMOKE_TIMEOUT}s"
elif [ "$SMOKE_RC" -ne 0 ] && [ "$SMOKE_RC" -ne 1 ]; then
  HARNESS_ERROR="harness exited $SMOKE_RC"
elif [[ "$OUTPUT" =~ PASS=([0-9]+)[[:space:]]+FAIL=([0-9]+)[[:space:]]+SKIP=([0-9]+) ]]; then
  PASS="${BASH_REMATCH[1]}"; FAIL="${BASH_REMATCH[2]}"; SKIP="${BASH_REMATCH[3]}"
  if [ "$SMOKE_RC" -eq 1 ] && [ "$FAIL" -eq 0 ]; then
    HARNESS_ERROR="harness exited 1 but reported FAIL=0"
  fi
else
  HARNESS_ERROR="no PASS/FAIL/SKIP summary line (rc=$SMOKE_RC)"
fi

# This playbook is scope:single on the host that owns the stack, so a skipped
# check means a component is down, not absent by design. Only a run with zero
# skips and zero failures is healthy.
if [ -n "$HARNESS_ERROR" ]; then
  STACK_STATUS="harness-error"
elif [ "$FAIL" -gt 0 ]; then
  STACK_STATUS="failing"
elif [ "$PASS" -eq 0 ]; then
  STACK_STATUS="absent"
elif [ "$SKIP" -gt 0 ]; then
  STACK_STATUS="degraded"
else
  STACK_STATUS="present"
fi
if [ "$STACK_STATUS" = "present" ]; then CURRENT_STATUS="clear"; else CURRENT_STATUS="firing"; fi

if [ "$CURRENT_STATUS" = "$PRIOR_STATUS" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
fi

STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || { echo "ERROR: mktemp failed for $STATE_FILE" >&2; exit 1; }
trap 'rm -f "$STATE_TMP"' EXIT

# The brace group's status is only its last command's, so the frontmatter call
# exits on its own failure rather than relying on the `if !`.
if ! {
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field "stack=$STACK_STATUS" \
    --field "pass_count=$PASS" \
    --field "fail_count=$FAIL" \
    --field "skip_count=$SKIP" || { echo "ERROR: invalid alert frontmatter; existing state preserved" >&2; exit 1; }
  printf '\n# Ollama Live Stack Smoke Canary\n\n'
  printf '<!-- alert: [[CEO/alerts/ollama-smoke]] -->\n\n'
  printf 'Stack: **%s** (PASS=%s, FAIL=%s, SKIP=%s)\n\n' "$STACK_STATUS" "$PASS" "$FAIL" "$SKIP"
  case "$STACK_STATUS" in
    present)       printf 'Every smoke check ran and passed.\n\n' ;;
    failing)       printf 'At least one live check failed.\n\n' ;;
    degraded)      printf 'Some checks were skipped: a stack component is down or missing on the owner host.\n\n' ;;
    absent)        printf 'Every check was skipped: the local model stack is down on the owner host.\n\n' ;;
    harness-error) printf 'The smoke harness did not complete: %s.\n\n' "$HARNESS_ERROR" ;;
  esac
  printf 'Rerun by hand: `bash ollama-agent/tests/integration_smoke.sh`\n\n## Output\n\n~~~~\n%s\n~~~~\n' "$OUTPUT"
} > "$STATE_TMP"; then
  echo "ERROR: failed to render $STATE_FILE; existing state preserved" >&2
  exit 1
fi
mv "$STATE_TMP" "$STATE_FILE" || { echo "ERROR: failed to replace $STATE_FILE" >&2; exit 1; }
trap - EXIT

TASK_MARKER="<!-- ollama-smoke -->"
TASK_LINE="- [ ] Investigate local ollama stack ($STACK_STATUS) — see [[CEO/alerts/ollama-smoke]] $TASK_MARKER"

active_task_present() {
  [ -f "$INBOX_FILE" ] || return 1
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

INBOX_CHANGED=0
if [ "$PRIOR_STATUS" != "unknown" ]; then
  if [ "$CURRENT_STATUS" = "firing" ] && [ "$PRIOR_STATUS" != "firing" ]; then
    if ! active_task_present; then
      printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE" || { echo "ERROR: failed to append to $INBOX_FILE" >&2; exit 1; }
      INBOX_CHANGED=1
    fi
  elif [ "$CURRENT_STATUS" = "clear" ] && [ "$PRIOR_STATUS" = "firing" ] && active_task_present; then
    INBOX_TMP=$(mktemp "${INBOX_FILE}.XXXXXX") || { echo "ERROR: mktemp failed for $INBOX_FILE" >&2; exit 1; }
    trap 'rm -f "$INBOX_TMP"' EXIT
    awk -v m="$TASK_MARKER" -v r="- [done] Ollama live stack smoke cleared $(date +%Y-%m-%d) $TASK_MARKER" \
      '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$INBOX_TMP" \
      || { echo "ERROR: failed to rewrite $INBOX_FILE" >&2; exit 1; }
    mv "$INBOX_TMP" "$INBOX_FILE" || { echo "ERROR: failed to replace $INBOX_FILE" >&2; exit 1; }
    trap - EXIT
    INBOX_CHANGED=1
  fi
fi

if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  if [ "$INBOX_CHANGED" -eq 1 ]; then
    printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
  else
    printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"
  fi
fi

exit 0
