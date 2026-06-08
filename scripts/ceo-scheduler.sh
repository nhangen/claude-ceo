#!/bin/bash
# ceo-scheduler.sh — Scheduler abstraction for ceo playbook scan + ceo doctor.
# Sourced, not executed. Caller must have already sourced ceo-config.sh
# (provides ceo_detect_os).
#
# As of #144 (Phase 2 of #136) the macOS per-playbook launchd backend is
# retired: on macOS the Bun daemon `ceo-schedulerd` (lib/scheduler/) owns cron
# matching and reads CEO/registry.json directly, kept alive by ONE launchd agent
# (com.ceo.schedulerd — install template at lib/scheduler/deploy/). The OS no
# longer holds per-playbook schedules on macOS. Linux/WSL still uses crontab.
#
# Public API:
#   ceo_scheduler_backend       — prints the resolved backend name to stdout
#                                  ("crontab" | "daemon"); returns 1 (with stderr
#                                  message) on an unknown CEO_SCHEDULER value
#   ceo_scheduler_list          — prints the current schedule state to stdout in
#                                  a uniform "MIN HOUR D M W CMD  # ceo:NAME"
#                                  format (crontab content for the crontab
#                                  backend; nothing for the daemon backend, which
#                                  holds no per-playbook OS entries)
#   ceo_scheduler_install <payload>
#                                — crontab backend: replaces the user's crontab
#                                  with <payload>. daemon backend: no OS writes —
#                                  prints guidance (the daemon reads the registry;
#                                  the keep-alive agent is installed manually).
#                                  rc=0 on success, rc=1 on backend error.
#   ceo_scheduler_legacy_launchd_plists
#                                — lists any retired per-playbook com.ceo.*.plist
#                                  files (excluding com.ceo.schedulerd) so
#                                  `ceo doctor` can warn about orphans that would
#                                  double-fire alongside the daemon. Prints one
#                                  absolute path per line; empty when clean.
#
# Backend selection priority:
#   1. CEO_SCHEDULER env (explicit override for tests/dev); must be one of the
#      known names — unknown values fail loud (per enum-config-typo-fallback)
#   2. CEO_CRONTAB_BIN env set ⇒ crontab backend (legacy override)
#   3. ceo_detect_os: wsl/linux ⇒ crontab; macos ⇒ daemon
#
# Env overrides (for tests):
#   CEO_LAUNCHD_DIR  — directory holding com.ceo.*.plist (default ~/Library/LaunchAgents)

_CEO_SCHEDULER_KNOWN="crontab daemon"

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
        echo "daemon"
      fi
      ;;
    *)
      echo "daemon"
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
    daemon)
      # The daemon holds no per-playbook OS entries — scheduling lives in
      # registry.json, which it reads directly. Nothing to list.
      return 0
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
    daemon)
      # No per-playbook OS install on macOS: ceo-schedulerd reads the registry
      # directly. The single keep-alive agent is installed by hand (it runs the
      # user's vault, so it can't be a scan side effect). Surface that loudly so
      # a macOS scan doesn't look like it silently scheduled nothing.
      echo "macOS: scheduling is handled by the ceo-schedulerd daemon — no per-playbook OS entries are installed."
      echo "       Ensure the keep-alive agent is running: see lib/scheduler/deploy/com.ceo.schedulerd.plist (and 'ceo doctor')."
      return 0
      ;;
    *)
      echo "ERROR: unknown scheduler backend '$_backend'" >&2
      return 1
      ;;
  esac
}

# List retired per-playbook launchd plists (the #98 backend wrote
# com.ceo.<name>-<idx>.plist). These are NOT the daemon's keep-alive agent
# (com.ceo.schedulerd) and, if still loaded, would dispatch playbooks in
# parallel with the daemon — a double-fire. `ceo doctor` warns when any exist so
# the operator can bootout + rm them. Prints one absolute path per line.
ceo_scheduler_legacy_launchd_plists() {
  local dir="${CEO_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
  [ -d "$dir" ] || return 0
  local plist base
  for plist in "$dir"/com.ceo.*.plist; do
    [ -f "$plist" ] || continue
    base="$(basename "$plist" .plist)"
    [ "$base" = "com.ceo.schedulerd" ] && continue
    printf '%s\n' "$plist"
  done
}

# Linux sibling of ceo_scheduler_legacy_launchd_plists (#159). The Phase-1
# per-playbook CEO crontab block and the Phase-1.5 ceo-schedulerd systemd
# daemon each dispatch every playbook independently; running both fires
# everything twice. Detect the conflict by combining two signals:
#   - the CEO crontab block is live  → ceo_scheduler_list emits ceo-cron.sh lines
#   - the systemd user unit is active → `systemctl --user is-active ceo-schedulerd`
# Prints the conflicting cron-trigger count (a non-empty marker for the caller)
# when BOTH hold; prints nothing (clean) otherwise — including when systemctl is
# absent (macOS) or the unit is inactive. `ceo doctor` warns on a non-empty
# result so the operator removes the crontab block once the daemon is adopted.
#   CEO_SYSTEMCTL_BIN — systemctl binary (default "systemctl"); test override.
ceo_scheduler_crontab_daemon_conflict() {
  local systemctl_bin="${CEO_SYSTEMCTL_BIN:-systemctl}"
  command -v "$systemctl_bin" >/dev/null 2>&1 || return 0
  local _state
  _state="$("$systemctl_bin" --user is-active ceo-schedulerd 2>/dev/null || true)"
  [ "$_state" = "active" ] || return 0
  local _count
  _count="$(ceo_scheduler_list 2>/dev/null | grep -c 'ceo-cron\.sh' || true)"
  [ "${_count:-0}" -gt 0 ] || return 0
  printf '%s\n' "$_count"
}
