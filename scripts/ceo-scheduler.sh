#!/bin/bash
# ceo-scheduler.sh — Scheduler abstraction for ceo playbook scan + ceo doctor.
# Sourced, not executed. Caller must have already sourced ceo-config.sh
# (provides ceo_detect_os).
#
# Public API:
#   ceo_scheduler_backend       — prints the resolved backend name to stdout
#   ceo_scheduler_list          — prints the current scheduler state to stdout
#                                  (crontab content on the crontab backend; empty on noop)
#   ceo_scheduler_install <payload>
#                                — replaces the user's schedule with <payload>;
#                                  rc=0 on success, rc=1 on backend error,
#                                  rc=2 on noop-launchd (not yet implemented).
#
# Backend selection priority:
#   1. CEO_SCHEDULER env (explicit override for tests/dev)
#   2. CEO_CRONTAB_BIN env set ⇒ crontab backend (legacy override)
#   3. ceo_detect_os: wsl/linux ⇒ crontab; macos ⇒ noop-launchd

ceo_scheduler_backend() {
  if [ -n "${CEO_SCHEDULER:-}" ]; then
    echo "$CEO_SCHEDULER"
    return 0
  fi
  if [ -n "${CEO_CRONTAB_BIN:-}" ]; then
    echo "crontab"
    return 0
  fi
  case "$(ceo_detect_os)" in
    wsl|linux)
      echo "crontab"
      ;;
    macos)
      # A `crontab` resolving under $HOME is a test stub (per test-harness
      # conventions: stubs live under $TEST_HOME/.bun/bin). Real macOS
      # crontab is at /usr/bin/crontab, outside $HOME. The sniffer lets
      # ceo-cron.test.sh / ceo-schedule.test.sh exercise the crontab
      # backend on Mac dev hosts without modification.
      local _ct
      _ct="$(command -v crontab 2>/dev/null || true)"
      if [ -n "$_ct" ] && [ -n "${HOME:-}" ] && [ "${_ct#"$HOME"}" != "$_ct" ]; then
        echo "crontab"
      else
        echo "noop-launchd"
      fi
      ;;
    *)
      echo "noop-launchd"
      ;;
  esac
}

ceo_scheduler_list() {
  case "$(ceo_scheduler_backend)" in
    crontab)
      "${CEO_CRONTAB_BIN:-crontab}" -l 2>/dev/null
      ;;
    noop-launchd)
      : # empty schedule
      ;;
    *)
      return 1
      ;;
  esac
}

ceo_scheduler_install() {
  local payload="$1"
  case "$(ceo_scheduler_backend)" in
    crontab)
      local crontab_bin="${CEO_CRONTAB_BIN:-crontab}"
      local err
      err=$(printf '%s' "$payload" | "$crontab_bin" - 2>&1)
      local rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "ERROR: crontab install failed (rc=$rc): $err" >&2
        return 1
      fi
      return 0
      ;;
    noop-launchd)
      echo "ERROR: launchd backend not yet implemented; install scheduled triggers manually" >&2
      return 2
      ;;
    *)
      echo "ERROR: unknown scheduler backend '$(ceo_scheduler_backend)'" >&2
      return 1
      ;;
  esac
}
