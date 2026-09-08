#!/bin/bash

set -euo pipefail

: "${HOME:?HOME must be set before NoRx bookkeeping can run}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
RUNNER="${NORX_BOOKKEEPING_RUNNER:-$HOME/Library/Application Support/NoRxPeptides/runtime/norx-operations/bin/daily-bookkeeping.sh}"
STATE_DIR="${NORX_BOOKKEEPING_STATE_DIR:-$HOME/.local/state/norx-bookkeeping}"
# Mirrors the runner's own default (NORX_BOOKKEEPING_LOG_DIR in
# daily-bookkeeping.sh). Only used to tell an operator where to look, so a
# mismatch degrades to "log not readable at <path>" rather than to silence.
RUNNER_LOG_DIR="${NORX_BOOKKEEPING_LOG_DIR:-$HOME/Library/Logs/NoRxPeptides}"
DATE_BIN="${NORX_BOOKKEEPING_DATE_BIN:-$(command -v date 2>/dev/null || true)}"
SUCCESS_FILE="$STATE_DIR/ceo-last-success-date"
LOCK_DIR="$STATE_DIR/ceo-wrapper.lock"
DAILY_BOUNDARY_MINUTES=375
LOCK_ACQUIRED=0
marker_tmp=''

if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"
fi

if [ -z "$DATE_BIN" ] || [ ! -x "$DATE_BIN" ]; then
  printf 'ERROR: NoRx bookkeeping date command is unavailable\n' >&2
  exit 1
fi

read -r today hour minute < <("$DATE_BIN" '+%F %H %M')

if [[ ! "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
   [[ ! "$hour" =~ ^[0-9]{2}$ ]] ||
   [[ ! "$minute" =~ ^[0-9]{2}$ ]] ||
   (( 10#$hour > 23 || 10#$minute > 59 )); then
  printf 'ERROR: NoRx bookkeeping clock output is invalid\n' >&2
  exit 1
fi

current_minutes=$((10#$hour * 60 + 10#$minute))
if [ "$current_minutes" -lt "$DAILY_BOUNDARY_MINUTES" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

cleanup() {
  if [ -n "$marker_tmp" ]; then
    rm -f "$marker_tmp"
  fi
  if [ "$LOCK_ACQUIRED" -eq 1 ]; then
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '%s\n' "$$" > "$LOCK_DIR/owner"
  LOCK_ACQUIRED=1
else
  owner=''
  if [ -f "$LOCK_DIR/owner" ]; then
    owner="$(<"$LOCK_DIR/owner")"
  fi
  if [ -z "$owner" ]; then
    printf 'ERROR: NoRx bookkeeping wrapper lock has no owner\n' >&2
    exit 1
  fi
  if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
    owner_command="$(/bin/ps -p "$owner" -o command= 2>/dev/null || true)"
    if [[ "$owner_command" == *"$SCRIPT_PATH"* ]]; then
      exit 0
    fi
    printf 'ERROR: NoRx bookkeeping wrapper lock owner does not match\n' >&2
    exit 1
  fi
  rm -f "$LOCK_DIR/owner"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf 'ERROR: NoRx bookkeeping wrapper lock is unavailable\n' >&2
    exit 1
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/owner"
  LOCK_ACQUIRED=1
fi

if [ -f "$SUCCESS_FILE" ] && [ "$(<"$SUCCESS_FILE")" = "$today" ]; then
  exit 0
fi

if [ ! -x "$RUNNER" ]; then
  printf 'ERROR: NoRx bookkeeping runner is unavailable\n' >&2
  exit 1
fi

# Guarded, and it reports. The runner sends its phase results to its own log and
# writes nothing to stderr on a failure, so an unguarded call under `set -e`
# aborted this wrapper silently — the dispatcher captures a failing script's
# stderr and stdout (ceo-cron.sh), but there was nothing to capture, and the
# recorded failure read `Script exited 1 for norx-bookkeeping` and stopped there.
#
# Measured 2026-09-08: ten failures over three hours, every one of them
# `sync_all_sheets|remote_sheets_sync_failed` with every import phase green. That
# is a one-line diagnosis sitting in a file nothing pointed at, and finding it
# meant reading the wrapper to learn the runner existed, then reading the runner
# to learn where it logs.
RUNNER_EXIT=0
"$RUNNER" --run-once || RUNNER_EXIT=$?
if [ "$RUNNER_EXIT" -ne 0 ]; then
  printf 'ERROR: NoRx bookkeeping runner exited %s\n' "$RUNNER_EXIT" >&2
  # Newest by mtime rather than a date-derived name: this block is diagnostics,
  # and a diagnostic must not be able to change the exit code it is explaining.
  # Deriving the filename meant calling DATE_BIN with a second format, and under
  # `set -e` a DATE_BIN that does not accept it aborts the wrapper with *its*
  # status — which is exactly what happened, turning a runner exit of 9 into 2
  # and breaking the arm that pins the code being preserved.
  runner_log=$(ls -t "$RUNNER_LOG_DIR"/daily-bookkeeping-*.log 2>/dev/null | head -n 1 || true)
  if [ -n "$runner_log" ] && [ -r "$runner_log" ]; then
    printf 'runner log: %s\n' "$runner_log" >&2
    # The failing phases, not the tail: the runner logs one line per phase and
    # the successful ones outnumber the failure, so a plain tail buries it.
    failing=$(grep -v '|success$' "$runner_log" 2>/dev/null | tail -n 3 || true)
    [ -n "$failing" ] && printf 'last failing phases:\n%s\n' "$failing" >&2
  else
    printf 'no readable runner log under %s\n' "$RUNNER_LOG_DIR" >&2
  fi
  exit "$RUNNER_EXIT"
fi

marker_tmp=$(mktemp "$STATE_DIR/.ceo-success.XXXXXX")
printf '%s\n' "$today" > "$marker_tmp"
chmod 600 "$marker_tmp"
mv "$marker_tmp" "$SUCCESS_FILE"
marker_tmp=''
