#!/bin/bash
# Self-contained test harness for the ceo-cron.sh script-runner branch.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
CRON="$SCRIPT_DIR/ceo-cron.sh"

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

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/approvals" "$CEO_DIR/reports"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"

  # Stub crontab so playbook scan's cron install can't touch the user's real crontab.
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/crontab" << 'STUB'
#!/bin/bash
# no-op stub for tests
if [ "${1:-}" = "-l" ]; then
  cat "$HOME/.fake-crontab" 2>/dev/null || true
  exit 0
fi
cat > "$HOME/.fake-crontab"
STUB
  chmod +x "$TEST_HOME/bin/crontab"
  : > "$HOME/.fake-crontab"

  # Stub claude on PATH so dispatcher invocations are detectable. Default behavior
  # is success — individual tests override $TEST_HOME/bin/claude to simulate failure.
  cat > "$TEST_HOME/bin/claude" << 'STUB'
#!/bin/bash
echo "claude-fired" > "$HOME/claude-invoked.txt"
echo "ACTION: 1 | read | noop | n/a"
STUB
  chmod +x "$TEST_HOME/bin/claude"

  export PATH="$TEST_HOME/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_runner_script_execs_named_script_and_skips_claude() {
  cat > "$CEO_DIR/playbooks/fake-intake.md" << 'PB'
---
name: fake-intake
description: Test playbook for runner:script
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: fake-intake.sh
---
PB

  cat > "$SCRIPT_DIR/fake-intake.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/script-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/fake-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  CEO_VERBOSE=1 bash "$CRON" fake-intake >/dev/null 2>&1
  assert_file_exists "$TEST_HOME/script-fired.txt" "script must have executed"

  rm -f "$SCRIPT_DIR/fake-intake.sh"
}

test_runner_default_claude_unchanged() {
  cat > "$CEO_DIR/playbooks/fake-claude.md" << 'PB'
---
name: fake-claude
description: Existing-shape playbook
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local entry runner
  entry=$(jq -r '.playbooks[] | select(.name=="fake-claude")' "$CEO_DIR/registry.json")
  runner=$(echo "$entry" | jq -r '.runner // ""')
  # Empty string means "use default" — dispatcher treats unset and empty identically.
  if [ -n "$runner" ] && [ "$runner" != "claude" ]; then
    assert_eq "$runner" "claude" "default runner must be claude or empty"
  fi
}

test_script_failure_increments_fail_count() {
  cat > "$CEO_DIR/playbooks/fail-intake.md" << 'PB'
---
name: fail-intake
description: Test playbook for runner:script failure
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: fail-intake.sh
---
PB

  cat > "$SCRIPT_DIR/fail-intake.sh" << 'SH'
#!/bin/bash
exit 7
SH
  chmod +x "$SCRIPT_DIR/fail-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" fail-intake >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after one script failure"

  rm -f "$SCRIPT_DIR/fail-intake.sh"
}

test_script_success_resets_fail_count() {
  cat > "$CEO_DIR/playbooks/ok-intake.md" << 'PB'
---
name: ok-intake
description: Test playbook for runner:script success
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: ok-intake.sh
---
PB

  cat > "$SCRIPT_DIR/ok-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/ok-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  echo 2 > "$CEO_DIR/log/.fail-count"
  CEO_VERBOSE=1 bash "$CRON" ok-intake >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "0" "FAIL_COUNT_FILE must be 0 after a successful script run"

  rm -f "$SCRIPT_DIR/ok-intake.sh"
}

test_script_success_appends_runs_log() {
  cat > "$CEO_DIR/playbooks/log-intake.md" << 'PB'
---
name: log-intake
description: Test playbook to verify cron-runs.log entry
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: log-intake.sh
---
PB

  cat > "$SCRIPT_DIR/log-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/log-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" log-intake >/dev/null 2>&1 || true

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_contains "$runs_log" "log-intake completed" "cron-runs.log must record successful script run"

  rm -f "$SCRIPT_DIR/log-intake.sh"
}

test_read_tier_failure_increments_fail_count() {
  cat > "$TEST_HOME/bin/claude" << 'STUB'
#!/bin/bash
echo "synthetic stderr from claude stub" >&2
exit 2
STUB
  chmod +x "$TEST_HOME/bin/claude"

  cat > "$CEO_DIR/playbooks/read-tier-fail.md" << 'PB'
---
name: read-tier-fail
description: Read-tier playbook used to exercise claude failure path
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" read-tier-fail >/dev/null 2>&1 || true

  local fails runs_log
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after a read-tier failure"
  if [[ "$runs_log" == *"read-tier-fail completed"* ]]; then
    printf '  FAIL [%s] read-tier failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
}

test_phase3_failure_does_not_log_completed() {
  # Stateful stub: succeeds on Phase-1 (with ACTION line low-stakes-write),
  # fails on Phase-3.
  cat > "$TEST_HOME/bin/claude" << STUB
#!/bin/bash
COUNT_FILE="$TEST_HOME/.claude-call-count"
n=\$(cat "\$COUNT_FILE" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$COUNT_FILE"
if [ "\$n" = "1" ]; then
  echo "ACTION: 1 | low-stakes-write | noop | echo ok"
  exit 0
fi
echo "synthetic phase-3 failure" >&2
exit 3
STUB
  chmod +x "$TEST_HOME/bin/claude"

  cat > "$CEO_DIR/playbooks/phase3-fail.md" << 'PB'
---
name: phase3-fail
description: Low-stakes-write playbook to exercise Phase-3 failure
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: low-stakes-write
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" phase3-fail >/dev/null 2>&1 || true

  local fails runs_log
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after Phase-3 failure"
  if [[ "$runs_log" == *"phase3-fail completed"* ]]; then
    printf '  FAIL [%s] Phase-3 failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
}

test_runner_script_missing_script_field_fails() {
  cat > "$CEO_DIR/playbooks/bad-intake.md" << 'PB'
---
name: bad-intake
description: runner:script without script field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  CEO_VERBOSE=1 bash "$CRON" bad-intake >/dev/null 2>&1
  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "runner:script but no script field" "missing-script error must be logged"
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
