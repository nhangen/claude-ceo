#!/bin/bash
# Self-contained test harness for ceo-disk-monitor.sh — verifies the state
# machine, idempotency, and measurement/parse failure invariants.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/ceo-disk-monitor.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [[ ! -f "$path" ]]; then
    printf '  FAIL [%s] %s\n    expected file: %q\n' "$CURRENT_TEST" "$msg" "$path"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    forbidden: %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR"
  touch "$CEO_DIR/inbox.md"  # satisfy ceo_validate_vault

  # Stub paths the script measures. Inject via env so the script does not
  # require a real /mnt/c.
  export CEO_DISK_WSL_CRASHES_PATH="$TEST_HOME/fake-crashes"
  export CEO_DISK_C_MOUNT="$TEST_HOME/fake-c-mount"
  mkdir -p "$CEO_DISK_WSL_CRASHES_PATH" "$CEO_DISK_C_MOUNT"

  # Stubs for du, df, getent. Tests override DUMP_GB_STUB / C_FREE_GB_STUB
  # before calling the script.
  mkdir -p "$TEST_HOME/stubs"
  cat > "$TEST_HOME/stubs/du" << 'STUB'
#!/bin/bash
if [ -n "${DUMP_GB_STUB_FAIL:-}" ]; then
  exit 1
fi
printf '%sG\t%s\n' "${DUMP_GB_STUB:-0}" "${@: -1}"
STUB
  cat > "$TEST_HOME/stubs/df" << 'STUB'
#!/bin/bash
if [ -n "${C_FREE_GB_STUB_FAIL:-}" ]; then
  exit 1
fi
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n'
printf '/dev/sda 100G 0G %sG 0%% /\n' "${C_FREE_GB_STUB:-999}"
STUB
  chmod +x "$TEST_HOME/stubs/du" "$TEST_HOME/stubs/df"

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

  export PATH="$TEST_HOME/stubs:$PATH"
  # Defaults — tests override per-case.
  export DUMP_GB_STUB="0"
  export C_FREE_GB_STUB="999"
  unset DUMP_GB_STUB_FAIL C_FREE_GB_STUB_FAIL
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
  unset CEO_DISK_WSL_CRASHES_PATH CEO_DISK_C_MOUNT
  unset DUMP_GB_STUB C_FREE_GB_STUB DUMP_GB_STUB_FAIL C_FREE_GB_STUB_FAIL
}

run_monitor() {
  bash "$MONITOR" >/dev/null 2>&1
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" "$CEO_DIR/alerts/disk-$CEO_HOSTNAME.md" | tr -d '[:space:]'
}

# ---------- tests ----------

test_first_run_clear_creates_state_file() {
  DUMP_GB_STUB="0" C_FREE_GB_STUB="999" run_monitor
  assert_file_exists "$CEO_DIR/alerts/disk-$CEO_HOSTNAME.md" "state file should exist"
  assert_eq "$(state_field status)" "clear" "first run with low usage should be clear"
  if [ -f "$CEO_DIR/inbox/testhost.md" ] && [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] clear first run must not write inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_first_run_firing_appends_one_inbox_task() {
  DUMP_GB_STUB="20" C_FREE_GB_STUB="999" run_monitor
  assert_eq "$(state_field status)" "firing" "high dump should fire"
  local count
  count=$(grep -c -F "Clean wsl-crashes on testhost" "$CEO_DIR/inbox/testhost.md")
  assert_eq "$count" "1" "first firing run must append exactly one task"
}

test_steady_state_firing_does_not_re_append() {
  # The regression this PR fixes: 64 identical appends. Two firing runs
  # with no transition must leave exactly one task line.
  DUMP_GB_STUB="20" run_monitor
  DUMP_GB_STUB="20" run_monitor
  local count
  count=$(grep -c -F "Clean wsl-crashes on testhost" "$CEO_DIR/inbox/testhost.md")
  assert_eq "$count" "1" "steady-state firing must not re-append"
}

test_firing_to_clear_flips_task_and_appends_resolution() {
  DUMP_GB_STUB="20" run_monitor
  DUMP_GB_STUB="0" run_monitor
  assert_eq "$(state_field status)" "clear" "second run with clear measurement should be clear"
  local body
  body=$(cat "$CEO_DIR/inbox/testhost.md")
  assert_contains "$body" "- [done] Cleaned wsl-crashes on testhost" "task line must be flipped to [done]"
  assert_contains "$body" "disk monitor cleared" "resolution note must be appended"
  if grep -qF -- "- [ ] Clean wsl-crashes on testhost" "$CEO_DIR/inbox/testhost.md"; then
    printf '  FAIL [%s] original unchecked task must no longer be present\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_measurement_failure_preserves_prior_firing() {
  # Invariant: du/df failure must NOT silently clear a firing alert.
  DUMP_GB_STUB="20" run_monitor   # firing
  local inbox_before
  inbox_before=$(cat "$CEO_DIR/inbox/testhost.md")
  DUMP_GB_STUB_FAIL=1 run_monitor # measurement fails
  assert_eq "$(state_field status)" "firing" "measurement failure must preserve prior firing"
  local inbox_after
  inbox_after=$(cat "$CEO_DIR/inbox/testhost.md")
  assert_eq "$inbox_after" "$inbox_before" "measurement failure must not mutate inbox"
}

test_measurement_failure_on_clear_does_not_flip_to_firing() {
  DUMP_GB_STUB="0" run_monitor    # clear
  DUMP_GB_STUB_FAIL=1 run_monitor # measurement fails
  assert_eq "$(state_field status)" "clear" "measurement failure on clear stays clear"
  if [ -f "$CEO_DIR/inbox/testhost.md" ] && [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] measurement-failed run after clear must not write inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_missing_wsl_crashes_path_is_measurement_failure() {
  rm -rf "$CEO_DISK_WSL_CRASHES_PATH"
  DUMP_GB_STUB="20" run_monitor  # would fire if measurement succeeded
  DUMP_GB_STUB="20" run_monitor  # second run to ensure no transition triggered
  # Path missing on a firing measurement should not flip clear→firing.
  if [ -f "$CEO_DIR/inbox/testhost.md" ] && [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] missing measurement path must not escalate inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_corrupted_prior_status_does_not_mutate_inbox() {
  # Write a state file with an unknown status value.
  mkdir -p "$CEO_DIR/alerts"
  cat > "$CEO_DIR/alerts/disk-$CEO_HOSTNAME.md" << 'EOF'
---
status: frring
since: 2026-05-12T00:00:00-0400
last_check: 2026-05-12T00:00:00-0400
host: testhost
---
EOF
  DUMP_GB_STUB="0" run_monitor  # would clear, but prior is unknown → refuse to mutate inbox
  if [ -f "$CEO_DIR/inbox/testhost.md" ] && [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] unknown prior status must not trigger inbox flip\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_corrupted_prior_status_emits_warning() {
  mkdir -p "$CEO_DIR/alerts"
  cat > "$CEO_DIR/alerts/disk-$CEO_HOSTNAME.md" << 'EOF'
---
status: frring
since: 2026-05-12T00:00:00-0400
last_check: 2026-05-12T00:00:00-0400
host: testhost
---
EOF
  local stderr
  stderr=$(bash "$MONITOR" 2>&1 >/dev/null) || true
  assert_contains "$stderr" "unknown prior status" "unknown enum value must log to stderr"
}

test_sustained_firing_re_pokes_after_user_checkoff() {
  # Sustained-firing branch fires only when the [ ] task line has been
  # checked off but the alert still fires.
  DUMP_GB_STUB="20" run_monitor                    # clear→firing, task appended
  sed -i.bak 's/^- \[ \]/- [x]/' "$CEO_DIR/inbox/testhost.md"
  rm -f "$CEO_DIR/inbox/testhost.md.bak"
  # Force prior since to >24h ago so the SUSTAINED branch fires.
  sed -i.bak "s/^since: .*/since: 2026-01-01T00:00:00-0500/" "$CEO_DIR/alerts/disk-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/disk.md.bak"
  DUMP_GB_STUB="20" run_monitor
  local count
  count=$(grep -c -F -- "- [ ] Clean wsl-crashes on testhost" "$CEO_DIR/inbox/testhost.md")
  assert_eq "$count" "1" "sustained firing past 24h after checkoff must re-append one task"
}

test_two_hosts_write_disjoint_state_files() {
  CEO_HOSTNAME="alpha" DUMP_GB_STUB="20" run_monitor
  CEO_HOSTNAME="beta"  DUMP_GB_STUB="0"  run_monitor
  assert_file_exists "$CEO_DIR/alerts/disk-alpha.md" "alpha state file"
  assert_file_exists "$CEO_DIR/alerts/disk-beta.md"  "beta state file"
  local alpha_status beta_status
  alpha_status=$(awk '/^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }' "$CEO_DIR/alerts/disk-alpha.md" | tr -d '[:space:]')
  beta_status=$(awk '/^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }' "$CEO_DIR/alerts/disk-beta.md" | tr -d '[:space:]')
  assert_eq "$alpha_status" "firing" "alpha must be firing"
  assert_eq "$beta_status" "clear" "beta must be clear (no overwrite from alpha)"
}

test_user_reformat_does_not_duplicate_task() {
  # User reformats the task line text but leaves the HTML-comment marker.
  # Steady-state firing must NOT append a second active task.
  DUMP_GB_STUB="20" run_monitor
  local marker="<!-- disk-monitor:testhost -->"
  # Reformat the line: keep marker, change everything else.
  sed -i.bak "s|^- \[ \] Clean wsl-crashes.*|- [ ] custom translated message $marker|" "$CEO_DIR/inbox/testhost.md"
  rm -f "$CEO_DIR/inbox/testhost.md.bak"
  DUMP_GB_STUB="20" run_monitor
  local count
  count=$(grep -c -F -- "$marker" "$CEO_DIR/inbox/testhost.md")
  assert_eq "$count" "1" "reformatted line with marker must not be duplicated"
  if grep -qF -- "Clean wsl-crashes on testhost — see" "$CEO_DIR/inbox/testhost.md"; then
    printf '  FAIL [%s] reformat was overwritten — original wording reappeared\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_log_append_failure_emits_warning() {
  if [ "$(id -u)" = "0" ]; then
    return 0
  fi
  DUMP_GB_STUB="0" run_monitor
  local log_file="$CEO_DIR/log/disk-monitor/$(date +%Y-%m).md"
  chmod 0400 "$log_file"
  local stderr
  stderr=$(DUMP_GB_STUB="0" bash "$MONITOR" 2>&1 >/dev/null) || true
  chmod 0600 "$log_file"
  assert_contains "$stderr" "failed to append log line" "read-only log file must surface a warning to stderr"
}

test_inbox_rewrite_handles_host_with_regex_chars() {
  # HOST is interpolated into inbox-rewrite logic — must not break on regex
  # metacharacters or shell special chars.
  CEO_HOSTNAME='odd.host[1]'
  DUMP_GB_STUB="20" run_monitor
  DUMP_GB_STUB="0" run_monitor
  assert_eq "$(state_field status)" "clear" "regex-meta host must still resolve"
  local body
  body=$(cat "$CEO_DIR/inbox/odd.host[1].md")
  assert_contains "$body" "[done] Cleaned wsl-crashes on odd.host[1]" "host with regex chars must flip cleanly"
}

run_tests() {
  local count=0
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST="$fn"
    setup
    "$fn"
    teardown
    count=$((count + 1))
  done
  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}

run_tests
