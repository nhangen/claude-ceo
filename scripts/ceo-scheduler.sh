#!/bin/bash
# ceo-scheduler.sh — Scheduler abstraction for ceo playbook scan + ceo doctor.
# Sourced, not executed. Caller must have already sourced ceo-config.sh
# (provides ceo_detect_os).
#
# Public API:
#   ceo_scheduler_backend       — prints the resolved backend name to stdout;
#                                  returns 1 (with stderr message) on an
#                                  unknown CEO_SCHEDULER value
#   ceo_scheduler_list          — prints the current scheduler state to stdout
#                                  (crontab content on the crontab backend; empty on noop)
#   ceo_scheduler_install <payload>
#                                — replaces the user's schedule with <payload>;
#                                  rc=0 on success, rc=1 on backend error,
#                                  rc=2 on noop-launchd (not yet implemented).
#
# Backend selection priority:
#   1. CEO_SCHEDULER env (explicit override for tests/dev); must be one of
#      the known names — unknown values fail loud rather than fall through
#      (per enum-config-typo-fallback)
#   2. CEO_CRONTAB_BIN env set ⇒ crontab backend (legacy override)
#   3. ceo_detect_os: wsl/linux ⇒ crontab; macos ⇒ noop-launchd

_CEO_SCHEDULER_KNOWN="crontab noop-launchd"

ceo_scheduler_backend() {
  if [ -n "${CEO_SCHEDULER:-}" ]; then
    case " $_CEO_SCHEDULER_KNOWN " in
      *" $CEO_SCHEDULER "*)
        echo "$CEO_SCHEDULER"
        return 0
        ;;
      *)
        echo "ERROR: unknown CEO_SCHEDULER='$CEO_SCHEDULER'; valid: $_CEO_SCHEDULER_KNOWN" >&2
        return 1
        ;;
    esac
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
      : "${HOME:?HOME must be set to resolve scheduler backend on macOS}"
      # A `crontab` resolving under $HOME/.bun/bin/ is a test stub (per
      # test-harness conventions). Real macOS crontab is /usr/bin/crontab,
      # outside $HOME. The narrow path check (not just any-$HOME-prefix)
      # avoids matching unrelated $HOME/bin or asdf/Volta shims a user
      # might legitimately have. Lets ceo-cron.test.sh / ceo-schedule.test.sh
      # exercise the crontab backend on Mac dev hosts without modification.
      local _ct
      _ct="$(command -v crontab 2>/dev/null || true)"
      if [ -n "$_ct" ] && [ "${_ct#"$HOME/.bun/bin/"}" != "$_ct" ]; then
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
  local _backend _rc=0
  _backend="$(ceo_scheduler_backend)" || _rc=$?
  [ "$_rc" -eq 0 ] || return "$_rc"
  case "$_backend" in
    crontab)
      "${CEO_CRONTAB_BIN:-crontab}" -l 2>/dev/null
      ;;
    noop-launchd)
      : # empty schedule
      ;;
    *)
      echo "ERROR: unknown scheduler backend '$_backend'" >&2
      return 1
      ;;
  esac
}

ceo_scheduler_install() {
  local payload="$1"
  local _backend _rc=0
  _backend="$(ceo_scheduler_backend)" || _rc=$?
  [ "$_rc" -eq 0 ] || return "$_rc"
  case "$_backend" in
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
      echo "ERROR: unknown scheduler backend '$_backend'" >&2
      return 1
      ;;
  esac
}
