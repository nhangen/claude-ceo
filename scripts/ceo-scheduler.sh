#!/bin/bash
# ceo-scheduler.sh — Scheduler abstraction for ceo playbook scan + ceo doctor.
# Sourced, not executed. Caller must have already sourced ceo-config.sh
# (provides ceo_detect_os).
#
# Public API:
#   ceo_scheduler_backend       — prints the resolved backend name to stdout;
#                                  returns 1 (with stderr message) on an
#                                  unknown CEO_SCHEDULER value
#   ceo_scheduler_list          — prints the current schedule state to stdout
#                                  in a uniform "MIN HOUR D M W CMD  # ceo:NAME"
#                                  format (crontab content for crontab backend;
#                                  reconstructed lines per plist for launchd)
#   ceo_scheduler_install <payload>
#                                — replaces the user's schedule with <payload>;
#                                  rc=0 on success, rc=1 on backend error.
#
# Backend selection priority:
#   1. CEO_SCHEDULER env (explicit override for tests/dev); must be one of
#      the known names — unknown values fail loud rather than fall through
#      (per enum-config-typo-fallback)
#   2. CEO_CRONTAB_BIN env set ⇒ crontab backend (legacy override)
#   3. ceo_detect_os: wsl/linux ⇒ crontab; macos ⇒ launchd
#
# Launchd backend env overrides (for tests):
#   CEO_LAUNCHD_DIR     — directory holding com.ceo.*.plist (default ~/Library/LaunchAgents)
#   CEO_LAUNCHCTL_BIN   — path to launchctl (default launchctl on PATH)

_CEO_SCHEDULER_KNOWN="crontab launchd"

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
        echo "launchd"
      fi
      ;;
    *)
      echo "launchd"
      ;;
  esac
}

# Expand one cron field to a space-separated list of concrete integers.
# Supports: integer, list "1,3", range "1-5", step "*/N", named weekdays
# SUN-SAT (cron 0-6, launchd 0-6).
# Echoes "*" verbatim to signal "no constraint" (caller decides what that means).
_ceo_cron_field_expand() {
  local field="$1" range_start="$2" range_end="$3"
  if [ "$field" = "*" ]; then
    echo "*"
    return 0
  fi
  # Named weekday → integer (only valid in weekday field)
  case "$field" in
    SUN|sun) echo 0; return 0 ;;
    MON|mon) echo 1; return 0 ;;
    TUE|tue) echo 2; return 0 ;;
    WED|wed) echo 3; return 0 ;;
    THU|thu) echo 4; return 0 ;;
    FRI|fri) echo 5; return 0 ;;
    SAT|sat) echo 6; return 0 ;;
  esac
  local out=""
  local item
  # List "1,3" → recurse per element
  if [[ "$field" == *,* ]]; then
    IFS=',' read -ra _items <<< "$field"
    for item in "${_items[@]}"; do
      local sub
      sub="$(_ceo_cron_field_expand "$item" "$range_start" "$range_end")"
      out="$out $sub"
    done
    echo "$out" | tr ' ' '\n' | grep -v '^$' | sort -nu | tr '\n' ' ' | sed 's/ $//'
    return 0
  fi
  # Step "*/N" → range_start..range_end stepping by N
  if [[ "$field" == */* ]]; then
    local step="${field##*/}"
    local i="$range_start"
    while [ "$i" -le "$range_end" ]; do
      out="$out $i"
      i=$((i + step))
    done
    echo "${out# }"
    return 0
  fi
  # Range "1-5" → consecutive integers
  if [[ "$field" == *-* ]]; then
    local lo="${field%-*}" hi="${field#*-}"
    local i="$lo"
    while [ "$i" -le "$hi" ]; do
      out="$out $i"
      i=$((i + 1))
    done
    echo "${out# }"
    return 0
  fi
  # Plain integer
  echo "$field"
}

# Emit one plist body for a (label, minute, hour, weekday, command) tuple.
# weekday="*" omits the Weekday key (fires every day).
_ceo_launchd_plist_body() {
  local label="$1" minute="$2" hour="$3" weekday="$4" cmd="$5"
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${cmd}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key>
    <integer>${minute}</integer>
    <key>Hour</key>
    <integer>${hour}</integer>
XML
  if [ "$weekday" != "*" ]; then
    printf '    <key>Weekday</key>\n    <integer>%s</integer>\n' "$weekday"
  fi
  cat <<'XML'
  </dict>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
XML
}

# Generate the set of (label, minute, hour, weekday, command, ceo_name) tuples
# from a crontab-style payload. Emits one TSV-delimited row per tuple:
#   label<TAB>minute<TAB>hour<TAB>weekday<TAB>cmd<TAB>ceo_name
# Skips marker lines, blank lines, and any line that doesn't match the
# "MIN HOUR DOM MON DOW CMD  # ceo:NAME" shape.
_ceo_launchd_tuples_from_payload() {
  local payload="$1"
  printf '%s\n' "$payload" | while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # Extract ceo:NAME tag
    local name="${line##*# ceo:}"
    if [ "$name" = "$line" ]; then
      # No ceo: tag — skip
      continue
    fi
    name="${name%%[[:space:]]*}"
    local schedule_and_cmd="${line%%#*}"
    schedule_and_cmd="${schedule_and_cmd%"${schedule_and_cmd##*[![:space:]]}"}"  # rtrim
    # Split into 5 cron fields + remaining command
    read -r m h dom mon dow cmd_rest <<< "$schedule_and_cmd"
    if [ -z "$cmd_rest" ]; then
      continue
    fi
    local minutes hours weekdays
    minutes="$(_ceo_cron_field_expand "$m" 0 59)"
    hours="$(_ceo_cron_field_expand "$h" 0 23)"
    weekdays="$(_ceo_cron_field_expand "$dow" 0 6)"
    local idx=0
    local mi hi wi
    # Disable filename globbing so a bare `*` from _ceo_cron_field_expand
    # doesn't expand against the cwd. The sentinel is rendered back to `*`
    # downstream (means "no constraint" — Weekday key omitted in the plist).
    set -f
    for mi in $minutes; do
      for hi in $hours; do
        for wi in $weekdays; do
          local label="com.ceo.${name}-${idx}"
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mi" "$hi" "$wi" "$cmd_rest" "$name"
          idx=$((idx + 1))
        done
      done
    done
    set +f
  done
}

# Reconstruct an approximate crontab-style line from a plist file for use in
# ceo_scheduler_list. Keeps the "ceo-cron.sh" substring that ceo doctor greps
# for, plus the "# ceo:NAME" tag. One line per plist (since one plist == one
# concrete trigger time).
_ceo_launchd_plist_to_cron_line() {
  local plist="$1"
  if [ ! -f "$plist" ]; then
    return 0
  fi
  local label minute hour weekday cmd
  label="$(grep -A1 '<key>Label</key>' "$plist" | tail -1 | sed -E 's|.*<string>(.*)</string>.*|\1|')"
  minute="$(grep -A1 '<key>Minute</key>' "$plist" | tail -1 | sed -E 's|.*<integer>([0-9]+)</integer>.*|\1|')"
  hour="$(grep -A1 '<key>Hour</key>' "$plist" | tail -1 | sed -E 's|.*<integer>([0-9]+)</integer>.*|\1|')"
  weekday="$(grep -A1 '<key>Weekday</key>' "$plist" 2>/dev/null | tail -1 | sed -nE 's|.*<integer>([0-9]+)</integer>.*|\1|p')"
  # Last <string> inside ProgramArguments array is the command.
  cmd="$(awk '/<key>ProgramArguments<\/key>/,/<\/array>/' "$plist" | grep '<string>' | tail -1 | sed -E 's|.*<string>(.*)</string>.*|\1|')"
  local name="${label#com.ceo.}"
  name="${name%-*}"
  printf '%s %s * * %s %s  # ceo:%s\n' "${minute:-0}" "${hour:-0}" "${weekday:-*}" "$cmd" "$name"
}

ceo_scheduler_list() {
  local _backend _rc=0
  _backend="$(ceo_scheduler_backend)" || _rc=$?
  [ "$_rc" -eq 0 ] || return "$_rc"
  case "$_backend" in
    crontab)
      "${CEO_CRONTAB_BIN:-crontab}" -l 2>/dev/null
      ;;
    launchd)
      local dir="${CEO_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
      [ -d "$dir" ] || return 0
      local plist
      for plist in "$dir"/com.ceo.*.plist; do
        [ -f "$plist" ] || continue
        _ceo_launchd_plist_to_cron_line "$plist"
      done
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
    launchd)
      local dir="${CEO_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
      local launchctl_bin="${CEO_LAUNCHCTL_BIN:-launchctl}"
      mkdir -p "$dir"

      local uid
      uid="$(id -u 2>/dev/null || echo 0)"
      # Track written labels as a space-separated string (bash 3.2 compatible —
      # no associative arrays). Anchored with leading and trailing spaces so
      # substring match doesn't false-positive on label prefixes.
      local kept_labels=" "

      # Render and write new plists from the payload.
      local label minute hour weekday cmd name
      while IFS=$'\t' read -r label minute hour weekday cmd name; do
        [ -n "$label" ] || continue
        local target="$dir/$label.plist"
        _ceo_launchd_plist_body "$label" "$minute" "$hour" "$weekday" "$cmd" > "$target.tmp"
        mv "$target.tmp" "$target"
        # Reload: bootout then bootstrap is the supported pattern on modern
        # macOS (12+). Errors from bootout on a not-yet-loaded label are
        # expected on first install — suppress.
        "$launchctl_bin" bootout "gui/$uid" "$target" 2>/dev/null || true
        if ! "$launchctl_bin" bootstrap "gui/$uid" "$target" 2>/dev/null; then
          echo "ERROR: launchctl bootstrap failed for $label" >&2
          return 1
        fi
        kept_labels="$kept_labels$label "
      done < <(_ceo_launchd_tuples_from_payload "$payload")

      # Stale-plist cleanup: anything matching com.ceo.*.plist that wasn't
      # written above is no longer in the registry — bootout + delete.
      local existing_plist existing_label
      for existing_plist in "$dir"/com.ceo.*.plist; do
        [ -f "$existing_plist" ] || continue
        existing_label="$(basename "$existing_plist" .plist)"
        case "$kept_labels" in
          *" $existing_label "*) ;;
          *)
            "$launchctl_bin" bootout "gui/$uid" "$existing_plist" 2>/dev/null || true
            rm -f "$existing_plist"
            ;;
        esac
      done
      return 0
      ;;
    *)
      echo "ERROR: unknown scheduler backend '$_backend'" >&2
      return 1
      ;;
  esac
}
