#!/usr/bin/env bash
# ceo-ollama-smoke.sh — runs integration_smoke.sh and updates CEO/alerts/ollama-smoke.md
# Escalate to inbox only on transition to firing.

set -uo pipefail

: "${HOME:?HOME must be set for ceo-ollama-smoke}"
: "${CEO_DIR:?CEO_DIR must be set for ceo-ollama-smoke}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

SMOKE_BIN="${OLLAMA_SMOKE_BIN:-$SCRIPT_DIR/../ollama-agent/tests/integration_smoke.sh}"
if [ ! -x "$SMOKE_BIN" ]; then
  echo "ERROR: integration_smoke.sh not found or not executable at $SMOKE_BIN" >&2
  exit 1
fi

STATE_DIR="$CEO_DIR/alerts"
STATE_FILE="$STATE_DIR/ollama-smoke.md"
mkdir -p "$STATE_DIR"

INBOX_FILE="$CEO_DIR/inbox.md"
HOST="$(hostname -s 2>/dev/null || echo "localhost")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Run integration smoke and capture output
OUTPUT=$(bash "$SMOKE_BIN" 2>&1) || true

# Parse summary line: PASS=N  FAIL=N  SKIP=N
PASS=0; FAIL=0; SKIP=0
if [[ "$OUTPUT" =~ PASS=([0-9]+)[[:space:]]+FAIL=([0-9]+)[[:space:]]+SKIP=([0-9]+) ]]; then
  PASS="${BASH_REMATCH[1]}"
  FAIL="${BASH_REMATCH[2]}"
  SKIP="${BASH_REMATCH[3]}"
else
  # Fallback if summary format differed or script crashed
  FAIL=1
fi

if [ "$FAIL" -gt 0 ]; then
  CURRENT_STATUS="firing"
  STACK_STATUS="failing"
elif [ "$PASS" -gt 0 ]; then
  CURRENT_STATUS="clear"
  STACK_STATUS="present"
else
  CURRENT_STATUS="clear"
  STACK_STATUS="absent"
fi

# Transition / since preservation
PRIOR_STATUS="unknown"
PRIOR_SINCE=""
if [ -f "$STATE_FILE" ]; then
  PRIOR_STATUS=$(awk '/^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }' "$STATE_FILE" 2>/dev/null || echo "unknown")
  PRIOR_SINCE=$(awk '/^since:/ { sub(/^since:[[:space:]]*/, ""); print; exit }' "$STATE_FILE" 2>/dev/null || echo "")
fi

SINCE="$NOW"
if [ "$PRIOR_STATUS" = "$CURRENT_STATUS" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
fi

# Render state file atomically
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  echo "ERROR: mktemp failed for state file" >&2
  exit 1
}

{
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field "pass_count=$PASS" \
    --field "fail_count=$FAIL" \
    --field "skip_count=$SKIP" \
    --field "stack=$STACK_STATUS"
  printf '\n# Ollama Live Stack Smoke Canary\n\n'
  printf '<!-- alert: [[CEO/alerts/ollama-smoke]] -->\n\n'
  printf 'Summary: **%s** (PASS=%d, FAIL=%d, SKIP=%d)\n\n' "$STACK_STATUS" "$PASS" "$FAIL" "$SKIP"
  if [ "$CURRENT_STATUS" = "firing" ]; then
    printf 'Live integration smoke test failed. Run `bash ollama-agent/tests/integration_smoke.sh` to diagnose.\n\n'
  elif [ "$STACK_STATUS" = "absent" ]; then
    printf 'All smoke checks were skipped (stack absent on this host).\n\n'
  else
    printf 'All active smoke checks passed.\n\n'
  fi
  printf '## Output\n\n```\n%s\n```\n' "$OUTPUT"
} > "$STATE_TMP"

mv "$STATE_TMP" "$STATE_FILE"

# Inbox escalation logic (only on transition to firing)
TASK_MARKER="<!-- ollama-smoke -->"
TASK_LINE="- [ ] Investigate local ollama live stack failure — see [[CEO/alerts/ollama-smoke]] $TASK_MARKER"

touch "$INBOX_FILE"

active_task_present() {
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

if [ "$CURRENT_STATUS" = "firing" ]; then
  if ! active_task_present; then
    printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  fi
elif [ "$CURRENT_STATUS" = "clear" ] && [ "$PRIOR_STATUS" = "firing" ]; then
  if active_task_present; then
    tmpfile=$(mktemp)
    awk -v m="$TASK_MARKER" -v r="- [done] Ollama live stack smoke cleared $(date +%Y-%m-%d) $TASK_MARKER" \
      '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$tmpfile"
    mv "$tmpfile" "$INBOX_FILE"
  fi
fi

if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  if [ "$CURRENT_STATUS" = "firing" ] || [ "$PASS" -gt 0 ]; then
    printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
  else
    printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"
  fi
fi

exit 0
