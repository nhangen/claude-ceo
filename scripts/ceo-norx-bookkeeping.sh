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
RUN_START_MARK=''

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
  if [ -n "$RUN_START_MARK" ]; then
    rm -f "$RUN_START_MARK"
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
# Touched immediately before the runner call so the block below can ask whether
# the newest log is actually *this* run's. `-nt` compares mtimes with no external
# command, which keeps a diagnostic from calling DATE_BIN with a format it may
# not accept (see the comment on the mtime choice below). A write failure here
# empties the variable rather than aborting: an unwritable state dir must not
# turn a runner failure into a wrapper failure.
RUN_START_MARK="$STATE_DIR/.ceo-run-start"
# Braced: redirections are applied left to right, so a bare `: > "$f" 2>/dev/null`
# reports the failing `>` before the `2>` is in effect — and that message would
# land in the vault-synced cron-stderr.log.
{ : > "$RUN_START_MARK"; } 2>/dev/null || RUN_START_MARK=''
RUNNER_EXIT=0
"$RUNNER" --run-once || RUNNER_EXIT=$?
if [ "$RUNNER_EXIT" -ne 0 ]; then
  printf 'ERROR: NoRx bookkeeping runner exited %s\n' "$RUNNER_EXIT" >&2
  # daily-bookkeeping.sh exits 75 when another copy holds its lock. The mtime
  # check below proves the log moved since this run started, not that *this* run
  # moved it — and on 75 the other copy is by definition the one writing. Quoting
  # it there would attribute a concurrent run's phases to a run that did no work,
  # which is the misdirection the rest of this block exists to prevent.
  RUNNER_LOCK_BUSY_EXIT=75
  # Newest by mtime rather than a date-derived name: this block is diagnostics,
  # and a diagnostic must not be able to change the exit code it is explaining.
  # Deriving the filename meant calling DATE_BIN with a second format, and under
  # `set -e` a DATE_BIN that does not accept it aborts the wrapper with *its*
  # status — which is exactly what happened, turning a runner exit of 9 into 2
  # and breaking the arm that pins the code being preserved.
  # SC2012 (info): `find` is the house pattern, but the runner names these files
  # daily-bookkeeping-<ISO date>.log and nothing else writes here, so the
  # filename hazard `find` exists for cannot arise. `|| true` keeps the pipeline
  # from tripping `pipefail` when the glob matches nothing.
  runner_log=$(ls -t "$RUNNER_LOG_DIR"/daily-bookkeeping-*.log 2>/dev/null | head -n 1 || true)
  if [ "$RUNNER_EXIT" -eq "$RUNNER_LOCK_BUSY_EXIT" ]; then
    printf 'norx-bookkeeping: another copy of the runner holds its lock — this run did no work, so no log is quoted\n' >&2
  elif [ -n "$runner_log" ] && [ -r "$runner_log" ]; then
    printf 'norx-bookkeeping: runner log: %s\n' "$runner_log" >&2
    if [ -z "$RUN_START_MARK" ]; then
      printf 'norx-bookkeeping: cannot tell whether that log is from this run — not quoting it\n' >&2
    elif [ "$RUN_START_MARK" -nt "$runner_log" ]; then
      # Strictly older than the mark, so nothing in it was written by this run.
      # The runner has other non-zero exits that log nothing at all — an
      # unwritable log dir and a failed mktemp — and in both the newest log is a
      # previous run's (exit 75 is handled above, before this check). Quoting it names
      # a cause that is not this failure's, which is worse than saying nothing:
      # silence prompts an investigation, a confident wrong answer ends one.
      printf 'norx-bookkeeping: that log predates this run — it does not explain this failure\n' >&2
    else
      # Scoped to one run id, not the file: the runner appends to a single log per
      # UTC day and this playbook runs hourly, so an unscoped tail attributes an
      # earlier run's failures to this one. On 2026-09-08 that was nine of ten runs.
      # The id is the second pipe field of `ts|run_id|phase|code`, a format owned by
      # daily-bookkeeping.sh — when a line does not carry it, say so and fall back
      # rather than silently degrading into the plain tail this block replaced.
      run_id=''
      case "$(tail -n 1 "$runner_log" 2>/dev/null || true)" in
        *'|'*'|'*) run_id=$(tail -n 1 "$runner_log" 2>/dev/null | cut -d'|' -f2 || true) ;;
      esac
      if [ -n "$run_id" ]; then
        failing=$(grep -F "|$run_id|" "$runner_log" 2>/dev/null | grep -v '|success$' | tail -n 3 || true)
        scope="run $run_id"
      else
        printf 'norx-bookkeeping: log format not recognized — quoting it unscoped\n' >&2
        failing=$(grep -v '|success$' "$runner_log" 2>/dev/null | tail -n 3 || true)
        scope='the whole log'
      fi
      # "non-success", not "failing": the runner also logs benign codes such as
      # stale_lock_recovered, and an operator acts on the label. These lines reach
      # the vault-synced cron-stderr.log unredacted (ceo-cron.sh appends the raw
      # stream; only the recorded failure reason is redacted), which is safe only
      # because every code daily-bookkeeping.sh logs is a literal identifier. If
      # it ever interpolates an error string, this quote becomes a leak path.
      if [ -n "$failing" ]; then
        printf 'norx-bookkeeping: last non-success phases (%s):\n%s\n' "$scope" "$failing" >&2
      else
        printf 'norx-bookkeeping: no non-success phase lines for %s\n' "$scope" >&2
      fi
    fi
  else
    printf 'norx-bookkeeping: no readable runner log under %s\n' "$RUNNER_LOG_DIR" >&2
  fi
  exit "$RUNNER_EXIT"
fi

marker_tmp=$(mktemp "$STATE_DIR/.ceo-success.XXXXXX")
printf '%s\n' "$today" > "$marker_tmp"
chmod 600 "$marker_tmp"
mv "$marker_tmp" "$SUCCESS_FILE"
marker_tmp=''
