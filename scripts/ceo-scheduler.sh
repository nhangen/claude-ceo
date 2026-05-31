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
#   ceo_scheduler_loaded_count   — prints the count of currently-loaded ceo
#                                  jobs (launchd only — queries `launchctl
#                                  print gui/$uid` for com.ceo.* lines). For
#                                  the crontab backend the concept doesn't
#                                  apply: prints "n/a" and returns 0. Lets
#                                  `ceo doctor` flag drift between on-disk
#                                  plist files and what launchd actually
#                                  has loaded.
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

# XML-escape one string for safe interpolation into a plist body.
# Order matters: & first so subsequent literal entities don't double-escape.
_ceo_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# Expand one cron field to a space-separated list of concrete integers.
# Supports: integer, list "1,3", range "1-5", step "*/N", named weekdays
# SUN-SAT (cron 0-6, launchd 0-6).
# Echoes "*" verbatim to signal "no constraint" (caller decides what that means).
# Returns 1 with stderr diagnostic on: step <= 0, integer outside range,
# reversed range (lo > hi), or any non-integer garbage.
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
      sub="$(_ceo_cron_field_expand "$item" "$range_start" "$range_end")" || return 1
      out="$out $sub"
    done
    echo "$out" | tr ' ' '\n' | grep -v '^$' | sort -nu | tr '\n' ' ' | sed 's/ $//'
    return 0
  fi
  # Step "*/N" → range_start..range_end stepping by N
  if [[ "$field" == */* ]]; then
    local step="${field##*/}"
    if ! [[ "$step" =~ ^[0-9]+$ ]] || [ "$step" -le 0 ]; then
      echo "ERROR: invalid cron step '$step' in field '$field' (must be positive integer)" >&2
      return 1
    fi
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
    if ! [[ "$lo" =~ ^[0-9]+$ ]] || ! [[ "$hi" =~ ^[0-9]+$ ]]; then
      echo "ERROR: invalid cron range '$field' (non-integer bound)" >&2
      return 1
    fi
    if [ "$lo" -gt "$hi" ]; then
      echo "ERROR: reversed cron range '$field' ($lo > $hi)" >&2
      return 1
    fi
    if [ "$lo" -lt "$range_start" ] || [ "$hi" -gt "$range_end" ]; then
      echo "ERROR: cron range '$field' outside valid bounds [$range_start..$range_end]" >&2
      return 1
    fi
    local i="$lo"
    while [ "$i" -le "$hi" ]; do
      out="$out $i"
      i=$((i + 1))
    done
    echo "${out# }"
    return 0
  fi
  # Plain integer — validate against allowed range
  if ! [[ "$field" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid cron field '$field' (not an integer)" >&2
    return 1
  fi
  if [ "$field" -lt "$range_start" ] || [ "$field" -gt "$range_end" ]; then
    echo "ERROR: cron field '$field' outside valid bounds [$range_start..$range_end]" >&2
    return 1
  fi
  echo "$field"
}

# Emit one plist body for a (label, minute, hour, weekday, command) tuple.
# weekday="*" omits the Weekday key (fires every day).
_ceo_launchd_plist_body() {
  local label="$1" minute="$2" hour="$3" weekday="$4" cmd="$5"
  local label_esc cmd_esc
  label_esc="$(_ceo_xml_escape "$label")"
  cmd_esc="$(_ceo_xml_escape "$cmd")"
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label_esc}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${cmd_esc}</string>
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
    # Split into 5 cron fields + remaining command. DOM and Month are
    # accepted on input for crontab-style parity but ignored — launchd's
    # StartCalendarInterval Day/Month keys are not encoded in this backend
    # (documented limitation).
    local _dom _mon
    read -r m h _dom _mon dow cmd_rest <<< "$schedule_and_cmd"
    if [ -z "$cmd_rest" ]; then
      continue
    fi
    local minutes hours weekdays
    minutes="$(_ceo_cron_field_expand "$m" 0 59)" || continue
    hours="$(_ceo_cron_field_expand "$h" 0 23)" || continue
    weekdays="$(_ceo_cron_field_expand "$dow" 0 6)" || continue
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
# ceo_scheduler_list. Uses `plutil -extract <key> raw -o - <file>` to read
# fields, so reformatting/whitespace-shifting the plist (Apple's xml1 ↔ binary1
# canonical reformat) can't silently produce empty fields that get defaulted
# to midnight. Required fields (Label, Minute, Hour, command) failing extract
# → skip the line entirely rather than fabricating a wrong trigger time.
# Optional Weekday → "*" when absent.
_ceo_launchd_plist_to_cron_line() {
  local plist="$1"
  [ -f "$plist" ] || return 0
  local plutil_bin="${CEO_PLUTIL_BIN:-plutil}"
  command -v "$plutil_bin" >/dev/null 2>&1 || return 0
  local label minute hour weekday cmd
  label=$("$plutil_bin" -extract Label raw -o - "$plist" 2>/dev/null) || return 0
  minute=$("$plutil_bin" -extract StartCalendarInterval.Minute raw -o - "$plist" 2>/dev/null) || return 0
  hour=$("$plutil_bin" -extract StartCalendarInterval.Hour raw -o - "$plist" 2>/dev/null) || return 0
  weekday=$("$plutil_bin" -extract StartCalendarInterval.Weekday raw -o - "$plist" 2>/dev/null) || weekday="*"
  # ProgramArguments is `["/bin/bash", "-lc", "<cmd>"]` — the third element is
  # the command we shipped.
  cmd=$("$plutil_bin" -extract ProgramArguments.2 raw -o - "$plist" 2>/dev/null) || return 0
  local name="${label#com.ceo.}"
  name="${name%-*}"
  printf '%s %s * * %s %s  # ceo:%s\n' "$minute" "$hour" "$weekday" "$cmd" "$name"
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

      # Resolve the GUI domain uid. Don't fall back to 0 on failure — that
      # silently targets root's launchd domain (per shell-required-env-vars).
      local uid
      uid="$(id -u 2>/dev/null)"
      : "${uid:?id -u failed; cannot resolve launchd GUI domain}"

      # Phase 1: render every plist as $target.tmp. No launchctl calls yet.
      # If any tuple fails to render, abort before mutating the live set.
      local kept_labels=" "
      local rendered=""
      local label minute hour weekday cmd name
      while IFS=$'\t' read -r label minute hour weekday cmd name; do
        [ -n "$label" ] || continue
        local target="$dir/$label.plist"
        if ! _ceo_launchd_plist_body "$label" "$minute" "$hour" "$weekday" "$cmd" > "$target.tmp"; then
          echo "ERROR: failed to render plist for $label" >&2
          rm -f "$target.tmp"
          for _r in $rendered; do rm -f "$dir/$_r.plist.tmp"; done
          return 1
        fi
        rendered="$rendered $label"
        kept_labels="$kept_labels$label "
      done < <(_ceo_launchd_tuples_from_payload "$payload")

      # Phase 2: commit each rendered .tmp to its final path, then bootout +
      # bootstrap. On bootstrap failure, roll back: bootout everything we
      # installed in this run, restore-via-delete the newly-committed plists,
      # leaving the prior live set untouched.
      local installed=""
      local _r _r_target
      for _r in $rendered; do
        _r_target="$dir/$_r.plist"
        mv "$_r_target.tmp" "$_r_target"
        # bootout-before-bootstrap is the supported reload pattern on modern
        # macOS (12+). bootout on a not-yet-loaded label errors — suppress.
        "$launchctl_bin" bootout "gui/$uid" "$_r_target" 2>/dev/null || true
        if ! "$launchctl_bin" bootstrap "gui/$uid" "$_r_target" 2>/dev/null; then
          echo "ERROR: launchctl bootstrap failed for $_r; rolling back this install" >&2
          local _rb
          for _rb in $installed; do
            "$launchctl_bin" bootout "gui/$uid" "$dir/$_rb.plist" 2>/dev/null || true
            rm -f "$dir/$_rb.plist"
          done
          rm -f "$_r_target"
          for _rb in $rendered; do rm -f "$dir/$_rb.plist.tmp"; done
          return 1
        fi
        installed="$installed $_r"
      done

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

ceo_scheduler_loaded_count() {
  local _backend _rc=0
  _backend="$(ceo_scheduler_backend)" || _rc=$?
  [ "$_rc" -eq 0 ] || return "$_rc"
  case "$_backend" in
    crontab)
      # cron entries don't "load" — they run on schedule. Doctor's plist-
      # vs-loaded drift check doesn't apply.
      echo "n/a"
      return 0
      ;;
    launchd)
      local uid
      uid="$(id -u 2>/dev/null)"
      : "${uid:?id -u failed; cannot resolve launchd GUI domain}"
      local launchctl_bin="${CEO_LAUNCHCTL_BIN:-launchctl}"
      # Capture launchctl stdout separately so we can distinguish "ran ok,
      # 0 com.ceo jobs loaded" from "couldn't query launchd at all". Real
      # `launchctl print gui/$uid` references each label across multiple
      # sections (services / endpoints / executable path), so count UNIQUE
      # labels — not lines — to avoid double-counting.
      local out rc
      out="$("$launchctl_bin" print "gui/$uid" 2>/dev/null)"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "unknown"
        return 0
      fi
      # Labels are `com.ceo.<name>-<idx>`; the suffix has no internal dots.
      # Excluding `.` from the character class avoids matching the trailing
      # `.plist` of `executable = .../com.ceo.foo-0.plist` as part of the label.
      printf '%s\n' "$out" \
        | grep -oE 'com\.ceo\.[A-Za-z0-9_-]+' \
        | sort -u \
        | wc -l \
        | tr -d ' '
      return 0
      ;;
    *)
      echo "ERROR: unknown scheduler backend '$_backend'" >&2
      return 1
      ;;
  esac
}
