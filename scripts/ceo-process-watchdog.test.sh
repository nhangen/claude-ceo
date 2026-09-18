#!/bin/bash
# Self-contained test harness for ceo-process-watchdog.sh.

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

  mkdir -p "$TEST_HOME/stubs"
  local user
  user=$(id -un)
  cat > "$TEST_HOME/stubs/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$TEST_HOME"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_HOME/stubs/getent"
  cat > "$TEST_HOME/stubs/curl" << 'STUB'
#!/bin/bash
payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d)
      shift
      payload="$1"
      ;;
  esac
  shift || true
done
printf '%s\n' "$payload" >> "${CURL_CAPTURE_FILE:?CURL_CAPTURE_FILE missing}"
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/curl"
  export PATH="$TEST_HOME/stubs:$PATH"

  export CEO_PROCESS_WATCHDOG_PS_FILE="$TEST_HOME/ps.txt"
  export CEO_PROCESS_WATCHDOG_KILL_LOG="$TEST_HOME/kill.log"
  export CEO_PROCESS_WATCHDOG_NOTIFY_LOG="$TEST_HOME/notify.log"
  export CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS=0
  export CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES=30
  export CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT=20
  : > "$CEO_PROCESS_WATCHDOG_PS_FILE"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
  unset CEO_PROCESS_WATCHDOG_PS_FILE CEO_PROCESS_WATCHDOG_KILL_LOG CEO_PROCESS_WATCHDOG_NOTIFY_LOG
  unset CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT
  unset CEO_PROCESS_WATCHDOG_DRY_RUN CEO_PROCESS_WATCHDOG_MATCH CEO_PROCESS_WATCHDOG_LABEL CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM
  unset CEO_DISCORD_WEBHOOK CURL_CAPTURE_FILE
}

run_watchdog() {
  bash "$WATCHDOG" >/dev/null 2>&1
}

state_file() {
  printf '%s\n' "$CEO_DIR/alerts/process-watchdog-$CEO_HOSTNAME.md"
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" "$(state_file)" | tr -d '[:space:]'
}

test_clear_when_no_matching_processes() {
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
  cat > "$CEO_PROCESS_WATCHDOG_PS_FILE" << 'EOF'
  100     1   01:00:00  75.0 /usr/bin/yes
EOF
  run_watchdog
  assert_eq "$(state_field status)" "clear" "unmatched process must leave alert clear"
  assert_eq "$(state_field killed_count)" "0" "nothing killed"
  assert_fails "clear run must not notify Discord" test -s "$CURL_CAPTURE_FILE"
}

test_kills_only_orphaned_old_hot_matching_processes() {
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
  cat > "$CEO_PROCESS_WATCHDOG_PS_FILE" << 'EOF'
  101     1   02:00:00  75.0 node /opt/homebrew/bin/gitnexus mcp
  102   999   02:00:00  75.0 node /opt/homebrew/bin/gitnexus mcp
  103     1      10:00  75.0 node /opt/homebrew/bin/gitnexus mcp
  104     1   02:00:00   2.0 node /opt/homebrew/bin/gitnexus mcp
  105     1   02:00:00  75.0 node /opt/homebrew/bin/other mcp
EOF
  run_watchdog
  assert_eq "$(state_field status)" "firing" "matching runaway must fire alert"
  assert_eq "$(state_field killed_count)" "1" "exactly one process should be killed"
  assert_contains "$(cat "$CEO_PROCESS_WATCHDOG_KILL_LOG")" "TERM 101" "matching PID gets TERM"
  for untouched in 102 103 104 105; do
    assert_not_contains "$(cat "$CEO_PROCESS_WATCHDOG_KILL_LOG")" "$untouched" "PID $untouched untouched"
  done
  assert_contains "$(cat "$CURL_CAPTURE_FILE")" "process-watchdog killed orphaned process" "kill must notify Discord"
  assert_contains "$(cat "$CURL_CAPTURE_FILE")" "101" "notification names killed PID"
}

test_dry_run_does_not_kill() {
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
  cat > "$CEO_PROCESS_WATCHDOG_PS_FILE" << 'EOF'
  201     1  1-00:00:00  80.0 node /opt/homebrew/bin/gitnexus mcp
EOF
  CEO_PROCESS_WATCHDOG_DRY_RUN=1 run_watchdog
  assert_eq "$(state_field dry_run)" "1" "dry run recorded in alert"
  assert_fails "dry run must not write kill log" test -s "$CEO_PROCESS_WATCHDOG_KILL_LOG"
  assert_fails "dry run must not notify Discord" test -s "$CURL_CAPTURE_FILE"
}

test_alert_does_not_leak_full_command_line() {
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
  cat > "$CEO_PROCESS_WATCHDOG_PS_FILE" << 'EOF'
  301     1   02:00:00  75.0 node /opt/homebrew/bin/gitnexus mcp --token SECRET_TOKEN
EOF
  run_watchdog
  assert_no_match "$(cat "$(state_file)")" "SECRET_TOKEN" "alert must not leak command arguments"
  assert_no_match "$(cat "$CURL_CAPTURE_FILE")" "SECRET_TOKEN" "notification must not leak command arguments"
}

test_notify_events_off_suppresses_kill_notification() {
  export CEO_DISCORD_WEBHOOK="http://127.0.0.1/webhook"
  export CURL_CAPTURE_FILE="$TEST_HOME/curl-payloads.jsonl"
  printf '%s\n' '{"notify_events":"off"}' > "$CEO_DIR/settings.json"
  cat > "$CEO_PROCESS_WATCHDOG_PS_FILE" << 'EOF'
  401     1   02:00:00  75.0 node /opt/homebrew/bin/gitnexus mcp
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
  local status runner script scope artifact
  status=$(jq -r '.playbooks[] | select(.name=="process-watchdog") | .status' "$reg")
  runner=$(jq -r '.playbooks[] | select(.name=="process-watchdog") | .runner' "$reg")
  script=$(jq -r '.playbooks[] | select(.name=="process-watchdog") | .script' "$reg")
  scope=$(jq -r '.playbooks[] | select(.name=="process-watchdog") | .scope' "$reg")
  artifact=$(jq -r '.playbooks[] | select(.name=="process-watchdog") | .artifact' "$reg")

  assert_eq "$status" "active" "status is active"
  assert_eq "$runner" "script" "runner is script"
  assert_eq "$script" "ceo-process-watchdog.sh" "script is ceo-process-watchdog.sh"
  assert_eq "$scope" "each" "scope is each"
  assert_eq "$artifact" "CEO/alerts/process-watchdog-{HOST}.md" "artifact is process-watchdog-{HOST}.md"
}

run_tests "$@"
