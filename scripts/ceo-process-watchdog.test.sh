#!/bin/bash
# Self-contained test harness for ceo-process-watchdog.sh.
#
# `ps` is stubbed on PATH and the signal primitive through
# CEO_PROCESS_WATCHDOG_KILL_BIN, so terminate_pid's real branches run: the
# identity re-checks, TERM grace, KILL escalation, and failure reporting. No
# real process is ever signalled.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/ceo-process-watchdog.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR"
  touch "$CEO_DIR/inbox.md"

  local stubs="$TEST_HOME/stubs"
  mkdir -p "$stubs"
  local user
  user=$(id -un)
  cat > "$stubs/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$TEST_HOME"
  exit 0
fi
exit 1
EOF

  # curl: capture the posted payload, answer with STUB_HTTP_CODE.
  cat > "$stubs/curl" << 'STUB'
#!/bin/bash
payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) shift; payload="$1" ;;
  esac
  shift || true
done
printf '%s\n' "$payload" >> "${CURL_CAPTURE_FILE:?CURL_CAPTURE_FILE missing}"
printf '%s' "${STUB_HTTP_CODE:-204}"
STUB

  # ps: `-axo …` prints the fixture table; `-p PID -o …` prints that PID's
  # identity columns. A PID listed in $STUB_STATE/swapped now belongs to another
# command; one in $STUB_STATE/adopted has the same command under a live parent.
  cat > "$stubs/ps" << 'STUB'
#!/bin/bash
case "$1" in
  -axo)
    [ -z "${STUB_PS_FAIL:-}" ] || exit 1
    cat "$STUB_PS_TABLE"
    ;;
  -p)
    pid="$2"
    grep -qx "$pid" "$STUB_STATE/alive" 2>/dev/null || exit 1
    grep -qx "$pid" "$STUB_STATE/blind" 2>/dev/null && exit 1
    if grep -qx "$pid" "$STUB_STATE/swapped" 2>/dev/null; then
      printf '%s 1 /usr/bin/unrelated-daemon\n' "$pid"
      exit 0
    fi
    if grep -qx "$pid" "$STUB_STATE/adopted" 2>/dev/null; then
      awk -v pid="$pid" '$1 == pid { cmd = $0; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", cmd); print $1, 4242, cmd }' "$STUB_PS_TABLE"
      exit 0
    fi
    awk -v pid="$pid" '$1 == pid { cmd = $0; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", cmd); print $1, $2, cmd; found = 1 } END { exit !found }' "$STUB_PS_TABLE"
    ;;
  *) echo "ps stub: unexpected argv: $*" >&2; exit 99 ;;
esac
STUB

  # kill: log each signal; model liveness in $STUB_STATE/alive.
  #   term-ignore   PIDs that survive TERM
  #   kill-ignore   PIDs that survive KILL
  #   term-fails    PIDs whose TERM returns non-zero
  #   swap-on-term  PIDs reused by another process right after TERM
#   blind-on-term PIDs that stay alive but `ps -p` stops answering for
  cat > "$stubs/fake-kill" << 'STUB'
#!/bin/bash
[ $# -eq 2 ] || { echo "kill stub: unexpected argv: $*" >&2; exit 99; }
sig="${1#-}" pid="$2" st="$STUB_STATE"
in_set() { grep -qx "$pid" "$st/$1" 2>/dev/null; }
drop() { grep -vx "$pid" "$st/alive" > "$st/alive.tmp"; mv "$st/alive.tmp" "$st/alive"; }
case "$sig" in
  0) in_set alive; exit ;;
  TERM)
    echo "TERM $pid" >> "$st/signals"
    in_set term-fails && exit 1
    if in_set swap-on-term; then echo "$pid" >> "$st/swapped"; exit 0; fi
    if in_set blind-on-term; then echo "$pid" >> "$st/blind"; exit 0; fi
    in_set term-ignore || drop
    ;;
  KILL)
    echo "KILL $pid" >> "$st/signals"
    in_set kill-ignore || drop
    ;;
  *) echo "kill stub: unexpected signal $sig" >&2; exit 99 ;;
esac
STUB
  chmod +x "$stubs"/*
  export PATH="$stubs:$PATH"

  export STUB_STATE="$TEST_HOME/stub-state"
  export STUB_PS_TABLE="$TEST_HOME/ps.txt"
  mkdir -p "$STUB_STATE"
  : > "$STUB_PS_TABLE"
  export CEO_PROCESS_WATCHDOG_KILL_BIN="$stubs/fake-kill"
  export CEO_PROCESS_WATCHDOG_NOTIFY_LOG="$TEST_HOME/notify.log"
  export CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS=0
  export CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES=30
  export CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT=20
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
  unset STUB_STATE STUB_PS_TABLE STUB_PS_FAIL STUB_HTTP_CODE CEO_REPO_PLAYBOOK_DIR
  unset CEO_PROCESS_WATCHDOG_KILL_BIN CEO_PROCESS_WATCHDOG_NOTIFY_LOG
  unset CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT
  unset CEO_PROCESS_WATCHDOG_DRY_RUN CEO_PROCESS_WATCHDOG_MATCH CEO_PROCESS_WATCHDOG_LABEL CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM
  unset CEO_DISCORD_WEBHOOK CURL_CAPTURE_FILE
}

# Writes the ps fixture from stdin and marks every PID in it alive.
ps_table() {
  cat > "$STUB_PS_TABLE"
  awk '{ print $1 }' "$STUB_PS_TABLE" > "$STUB_STATE/alive"
}

stub_set() {
  local name="$1"; shift
  printf '%s\n' "$@" >> "$STUB_STATE/$name"
}

signals() {
  cat "$STUB_STATE/signals" 2>/dev/null
}

run_watchdog() {
  bash "$WATCHDOG" "$@" > "$TEST_HOME/stdout" 2> "$TEST_HOME/stderr"
}

state_file() {
  printf '%s\n' "$CEO_DIR/alerts/process-watchdog-$CEO_HOSTNAME.md"
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" "$(state_file)" | tr -d '[:space:]'
}

row_result() {
  awk -F '|' -v pid="$1" '$2 ~ "^ *" pid " *$" { gsub(/ /, "", $6); print $6 }' "$(state_file)"
}

HOT='node /opt/homebrew/bin/gitnexus mcp'

test_clear_when_no_matching_processes() {
  ps_table << 'EOF'
  100     1   01:00:00  75.0 /usr/bin/yes
EOF
  run_watchdog
  assert_eq "$?" "0" "clear run exits 0"
  assert_eq "$(state_field status)" "clear" "unmatched process must leave alert clear"
  assert_eq "$(state_field killed_count)" "0" "nothing killed"
  assert_fails "clear run must not signal anything" test -s "$STUB_STATE/signals"
  assert_fails "clear run must not notify Discord" test -s "$CURL_CAPTURE_FILE"
}

test_kills_only_orphaned_old_hot_matching_processes() {
  ps_table << EOF
  101     1   02:00:00  75.0 $HOT
  102   999   02:00:00  75.0 $HOT
  103     1      10:00  75.0 $HOT
  104     1   02:00:00   2.0 $HOT
  105     1   02:00:00  75.0 node /opt/homebrew/bin/other mcp
EOF
  run_watchdog
  assert_eq "$?" "0" "successful kill exits 0"
  assert_eq "$(state_field status)" "firing" "matching runaway must fire alert"
  assert_eq "$(state_field candidate_count)" "1" "only the orphaned old hot match is a candidate"
  assert_eq "$(state_field killed_count)" "1" "exactly one process should be killed"
  assert_eq "$(signals)" "TERM 101" "only the matching PID is signalled, and TERM was enough"
  assert_eq "$(row_result 101)" "killed" "PID 101 recorded killed"
  assert_eq "$(jq -r '.embeds[0].fields[] | select(.name=="PIDs") | .value' "$CURL_CAPTURE_FILE")" "101" \
    "notification names exactly the killed PID"
}

test_escalates_to_kill_when_term_is_ignored() {
  ps_table << EOF
  111     1   02:00:00  90.0 $HOT
EOF
  stub_set term-ignore 111
  run_watchdog
  assert_eq "$?" "0" "escalated kill exits 0"
  assert_eq "$(signals)" "$(printf 'TERM 111\nKILL 111')" "TERM then KILL"
  assert_eq "$(row_result 111)" "killed" "escalated PID recorded killed"
}

test_survivor_with_kill_disabled_is_a_failure_not_a_kill() {
  ps_table << EOF
  121     1   02:00:00  90.0 $HOT
EOF
  stub_set term-ignore 121
  CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM=0 run_watchdog
  assert_eq "$?" "1" "a surviving runaway exits 1"
  assert_eq "$(signals)" "TERM 121" "no KILL when KILL_AFTER_TERM=0"
  assert_eq "$(state_field killed_count)" "0" "survivor is not counted killed"
  assert_eq "$(state_field failed_count)" "1" "survivor is counted failed"
  assert_eq "$(row_result 121)" "survived-term" "row names the survival"
  assert_fails "no kill notification for a survivor" test -s "$CURL_CAPTURE_FILE"
}

test_process_surviving_kill_is_a_failure() {
  ps_table << EOF
  131     1   02:00:00  90.0 $HOT
EOF
  stub_set term-ignore 131
  stub_set kill-ignore 131
  run_watchdog
  assert_eq "$?" "1" "unkillable process exits 1"
  assert_eq "$(row_result 131)" "failed" "row records failure"
}

test_signal_error_is_a_failure() {
  ps_table << EOF
  141     1   02:00:00  90.0 $HOT
EOF
  stub_set term-fails 141
  run_watchdog
  assert_eq "$?" "1" "a failed TERM exits 1"
  assert_eq "$(state_field failed_count)" "1" "failed TERM counted"
  assert_eq "$(row_result 141)" "failed" "row records failure"
}

test_pid_gone_before_signal_is_not_signalled() {
  ps_table << EOF
  151     1   02:00:00  90.0 $HOT
EOF
  : > "$STUB_STATE/alive"
  run_watchdog
  assert_eq "$?" "0" "a process that exited on its own is not an error"
  assert_fails "no signal sent to a PID that no longer matches" test -s "$STUB_STATE/signals"
  assert_eq "$(state_field killed_count)" "0" "not counted killed"
  assert_eq "$(row_result 151)" "gone-before-signal" "row says it was gone"
  assert_eq "$(state_field status)" "clear" "nothing left to report"
}

test_process_no_longer_orphaned_is_not_signalled() {
  ps_table << EOF
  156     1   02:00:00  90.0 $HOT
EOF
  stub_set adopted 156
  run_watchdog
  assert_fails "a process that now has a live parent gets no signal" test -s "$STUB_STATE/signals"
  assert_eq "$(row_result 156)" "gone-before-signal" "row says it no longer matched"
}

test_pid_reused_after_term_never_gets_kill() {
  ps_table << EOF
  161     1   02:00:00  90.0 $HOT
EOF
  stub_set swap-on-term 161
  run_watchdog
  assert_eq "$(signals)" "TERM 161" "KILL must not reach the process that reused the PID"
  assert_eq "$(row_result 161)" "killed" "the original process is gone"
}

test_unconfirmed_identity_after_term_is_a_failure() {
  ps_table << EOF
  166     1   02:00:00  90.0 $HOT
EOF
  stub_set blind-on-term 166
  run_watchdog
  assert_eq "$?" "1" "a live process ps cannot identify exits 1"
  assert_eq "$(signals)" "TERM 166" "no KILL without a confirmed identity"
  assert_eq "$(row_result 166)" "failed" "not reported killed"
  assert_fails "no kill notification" test -s "$CURL_CAPTURE_FILE"
}

test_failed_process_listing_is_not_reported_clear() {
  ps_table << EOF
  171     1   02:00:00  90.0 $HOT
EOF
  STUB_PS_FAIL=1 run_watchdog
  assert_eq "$?" "1" "ps failure exits 1"
  assert_fails "ps failure must not write a clear alert" test -f "$(state_file)"
  assert_contains "$(cat "$TEST_HOME/stderr")" "ps returned no process table" "ps failure is reported"
}

test_dry_run_reports_would_kill_without_signalling() {
  ps_table << EOF
  201     1  1-00:00:00  80.0 $HOT
EOF
  for mode in env flag; do
    rm -f "$(state_file)"
    if [ "$mode" = env ]; then CEO_PROCESS_WATCHDOG_DRY_RUN=1 run_watchdog; else run_watchdog --dry-run; fi
    assert_eq "$(state_field dry_run)" "1" "$mode: dry run recorded in alert"
    assert_eq "$(state_field candidate_count)" "1" "$mode: the day-old process is a candidate"
    assert_eq "$(state_field killed_count)" "0" "$mode: dry run kills nothing"
    assert_eq "$(row_result 201)" "would-kill" "$mode: row says would-kill"
  done
  assert_fails "dry run must not signal" test -s "$STUB_STATE/signals"
  assert_fails "dry run must not notify Discord" test -s "$CURL_CAPTURE_FILE"
}

test_thresholds_are_inclusive() {
  ps_table << EOF
  211     1   00:30:00  20.0 $HOT
  212     1      45:00  50.0 $HOT
  213     1      29:59  50.0 $HOT
  214     1   01:00:00  19.9 $HOT
EOF
  run_watchdog
  assert_eq "$(state_field candidate_count)" "2" "exactly 30m and 20% qualify; 29:59 and 19.9% do not"
  assert_eq "$(row_result 211)" "killed" "boundary process killed"
  assert_eq "$(row_result 212)" "killed" "MM:SS elapsed over 30m qualifies"
}

test_since_holds_across_runs_and_resets_on_transition() {
  ps_table << EOF
  221     1   02:00:00  90.0 $HOT
EOF
  stub_set term-ignore 221
  stub_set kill-ignore 221
  run_watchdog
  local first
  first=$(state_field since)
  sleep 1
  run_watchdog
  assert_eq "$(state_field since)" "$first" "since stays at the first firing observation"
  echo "1 0 1-00:00:00 0.0 /sbin/launchd" > "$STUB_PS_TABLE"
  sleep 1
  run_watchdog
  assert_eq "$(state_field status)" "clear" "cleared"
  assert_fails "since resets when the status changes" test "$(state_field since)" = "$first"
}

test_invalid_overrides_are_refused() {
  ps_table << EOF
  231     1   02:00:00  90.0 $HOT
EOF
  local spec var val
  for spec in MIN_AGE_MINUTES=abc TERM_GRACE_SECONDS=-1 KILL_AFTER_TERM=2 MIN_CPU_PERCENT=1e3; do
    var="CEO_PROCESS_WATCHDOG_${spec%%=*}" val="${spec#*=}"
    env "$var=$val" bash "$WATCHDOG" > /dev/null 2>&1
    assert_eq "$?" "1" "$spec is refused"
  done
  run_watchdog --bogus
  assert_eq "$?" "1" "unknown flag is refused"
  assert_fails "refused config writes no alert" test -f "$(state_file)"
  assert_fails "refused config signals nothing" test -s "$STUB_STATE/signals"
}

test_failed_notification_is_reported() {
  ps_table << EOF
  241     1   02:00:00  90.0 $HOT
EOF
  STUB_HTTP_CODE=404 run_watchdog
  assert_eq "$?" "0" "the kill still succeeded"
  assert_contains "$(cat "$TEST_HOME/stderr")" "kill notification failed (HTTP 404)" "HTTP error is surfaced"
  assert_contains "$(cat "$CEO_PROCESS_WATCHDOG_NOTIFY_LOG")" "post_failed=1 status=404" "HTTP error is logged"
}

test_alert_does_not_leak_full_command_line() {
  ps_table << EOF
  301     1   02:00:00  75.0 $HOT --token SECRET_TOKEN
EOF
  run_watchdog
  assert_eq "$(state_field killed_count)" "1" "process with arguments is still matched"
  assert_no_match "$(cat "$(state_file)")" "SECRET_TOKEN" "alert must not leak command arguments"
  assert_no_match "$(cat "$CURL_CAPTURE_FILE")" "SECRET_TOKEN" "notification must not leak command arguments"
}

test_notify_events_off_suppresses_kill_notification() {
  printf '%s\n' '{"notify_events":"off"}' > "$CEO_DIR/settings.json"
  ps_table << EOF
  401     1   02:00:00  75.0 $HOT
EOF
  run_watchdog
  assert_eq "$(state_field killed_count)" "1" "kill still happens when notifications are off"
  assert_fails "notify_events=off must suppress kill notification" test -s "$CURL_CAPTURE_FILE"
}

test_playbook_scan_registers_process_watchdog() {
  local ceo_cli="$SCRIPT_DIR/ceo"
  mkdir -p "$CEO_DIR/playbooks"
  cp "$SCRIPT_DIR/../docs/playbooks/process-watchdog.md" "$CEO_DIR/playbooks/process-watchdog.md"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"

  bash "$ceo_cli" playbook scan >/dev/null 2>&1
  local reg="$HOME/.ceo/registry.json"
  assert_file_exists "$reg" "registry must exist after scan"
  local sel='.playbooks[] | select(.name=="process-watchdog")'
  assert_eq "$(jq -r "$sel | .status" "$reg")" "active" "status is active"
  assert_eq "$(jq -r "$sel | .runner" "$reg")" "script" "runner is script"
  assert_eq "$(jq -r "$sel | .script" "$reg")" "ceo-process-watchdog.sh" "script is ceo-process-watchdog.sh"
  assert_eq "$(jq -r "$sel | .scope" "$reg")" "each" "scope is each"
  assert_eq "$(jq -r "$sel | .schedule" "$reg")" "*/10 * * * *" "schedule is every ten minutes"
  assert_eq "$(jq -r "$sel | .artifact" "$reg")" "CEO/alerts/process-watchdog-{HOST}.md" "artifact is process-watchdog-{HOST}.md"
}

run_tests "$@"
