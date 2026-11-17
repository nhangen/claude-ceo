#!/bin/bash
# gargoyl-checker-cutover.sh — one-time, human-run cutover of the dev.gargoyl.monitor
# watchdog from the standalone launchd LaunchAgent (dev.nhangen.gargoyl.checker,
# StartInterval 300) to the ceo-schedulerd/cronbird registry (#653). The PR does
# not touch launchd itself; a human runs this.
#
# Steps:
#   1. ceo playbook scan                   (registers the cronbird job in the
#                                          host registry ~/.ceo/registry.json)
#   2. ceo playbook enable gargoyl-checker (each-scope enablement on this host)
#   3. retire the legacy timer: bootout dev.nhangen.gargoyl.checker and remove
#      ~/Library/LaunchAgents/dev.nhangen.gargoyl.checker.plist
#
# Flags: --dry-run (print actions, change nothing), --retire-only (step 3 only,
# for staged cutovers and for testing). Safe to re-run: every step is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
PLIST_LABEL="dev.nhangen.gargoyl.checker"

DRY_RUN=0
RETIRE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --retire-only) RETIRE_ONLY=1 ;;
    *) echo "ERROR: unknown flag '$1' (expected: --dry-run, --retire-only)" >&2; exit 2 ;;
  esac
  shift
done

: "${HOME:?HOME must be set}"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LAUNCHCTL_BIN="${GARGOYL_LAUNCHCTL_BIN:-launchctl}"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] would run: %s\n' "$*"
  else
    "$@"
  fi
}

retire_launchd() {
  if [ -f "$PLIST" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] would run: %s bootout gui/%s/%s\n' "$LAUNCHCTL_BIN" "$(id -u)" "$PLIST_LABEL"
      printf '[dry-run] would remove: %s\n' "$PLIST"
    else
      # bootout fails when the job is not currently loaded; removing the plist
      # is what stops it loading again, so a bootout miss is noted and ignored.
      if ! "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null; then
        echo "NOTE: $PLIST_LABEL was not loaded (bootout said no); removing the plist anyway"
      fi
      rm -f "$PLIST"
      echo "retired: $PLIST_LABEL (bootout done, plist removed)"
    fi
  else
    echo "no legacy plist at $PLIST; nothing to retire"
  fi
}

if [ "$RETIRE_ONLY" = "0" ]; then
  run "$CEO_CLI" playbook scan
  run "$CEO_CLI" playbook enable gargoyl-checker
fi
retire_launchd
if [ "$DRY_RUN" = "0" ]; then
  echo "cutover complete: gargoyl-checker is dispatched by ceo-schedulerd (cronbird) every 5 minutes"
fi
