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
  # Bypass the ollama daemon HTTP probe in tests (the stubbed ollama binary
  # has no daemon backing it). Production runs leave this unset.
  export CEO_OLLAMA_SKIP_PROBE=1

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/approvals" "$CEO_DIR/reports"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"

  # Stub crontab so playbook scan's cron install can't touch the user's real crontab.
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" << 'STUB'
#!/bin/bash
# no-op stub for tests
if [ "${1:-}" = "-l" ]; then
  cat "$HOME/.fake-crontab" 2>/dev/null || true
  exit 0
fi
cat > "$HOME/.fake-crontab"
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  : > "$HOME/.fake-crontab"

  # Stub claude on PATH so dispatcher invocations are detectable. Default behavior
  # is success — individual tests override $TEST_HOME/.bun/bin/claude to simulate failure.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "claude-fired" > "$HOME/claude-invoked.txt"
echo "ACTION: 1 | read | noop | n/a"
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  # Stub ollama on PATH for runner:ollama / runner:ollama-think tests. Captures
  # the model argument so tests can assert which model was dispatched.
  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "run" ]; then
  echo "$2" > "$HOME/ollama-invoked-model.txt"
  cat > "$HOME/ollama-invoked-prompt.txt"
  echo "ollama-stub-response"
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  # macOS lacks `timeout` from GNU coreutils; the dispatcher uses
  # `timeout N claude ...`. Stub it as a transparent passthrough.
  if ! command -v timeout >/dev/null 2>&1; then
    cat > "$TEST_HOME/.bun/bin/timeout" << 'STUB'
#!/bin/bash
shift  # discard the duration arg
exec "$@"
STUB
    chmod +x "$TEST_HOME/.bun/bin/timeout"
  fi

  export PATH="$TEST_HOME/.bun/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR TEST_HOME HOME_BACKUP PATH_BACKUP CEO_REPO_PLAYBOOK_DIR CEO_OLLAMA_SKIP_PROBE
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
  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude was invoked but the script-runner branch must skip it\n' \
      "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  rm -f "$SCRIPT_DIR/fake-intake.sh"
}

test_runner_default_invokes_claude() {
  cat > "$CEO_DIR/playbooks/fake-claude.md" << 'PB'
---
name: fake-claude
description: Default-runner playbook
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
  CEO_VERBOSE=1 bash "$CRON" fake-claude >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "default runner must invoke claude"
}

test_v_safe_under_set_e() {
  cat > "$CEO_DIR/playbooks/v-test.md" << 'PB'
---
name: v-test
description: Exercises _v under set -e with CEO_VERBOSE unset
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: v-test.sh
---
PB

  cat > "$SCRIPT_DIR/v-test.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/v-test-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/v-test.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  unset CEO_VERBOSE
  bash "$CRON" v-test >/dev/null 2>&1
  assert_file_exists "$TEST_HOME/v-test-fired.txt" \
    "script must run end-to-end with CEO_VERBOSE unset (regression guard for a528fde)"

  rm -f "$SCRIPT_DIR/v-test.sh"
}

test_script_stderr_redirected_to_log() {
  cat > "$CEO_DIR/playbooks/stderr-intake.md" << 'PB'
---
name: stderr-intake
description: Test playbook to verify script stderr is captured
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: stderr-intake.sh
---
PB

  cat > "$SCRIPT_DIR/stderr-intake.sh" << 'SH'
#!/bin/bash
echo "synthetic-script-stderr-sentinel" >&2
exit 4
SH
  chmod +x "$SCRIPT_DIR/stderr-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" stderr-intake >/dev/null 2>&1 || true

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "synthetic-script-stderr-sentinel" \
    "script stderr must be appended to cron-stderr.log"

  rm -f "$SCRIPT_DIR/stderr-intake.sh"
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

test_disk_monitor_success_suppresses_success_notification() {
  cat > "$CEO_DIR/playbooks/disk-monitor.md" << 'PB'
---
name: disk-monitor
description: Test disk-monitor notification suppression
trigger: cron
schedule: "0 */6 * * *"
preflight: none
tier: read
status: active
runner: script
script: disk-monitor-test.sh
---
PB

  cat > "$SCRIPT_DIR/disk-monitor-test.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/disk-monitor-test.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" CEO_VERBOSE=1 bash "$CRON" disk-monitor >/dev/null 2>&1 || true

  local notify_log
  notify_log=$(cat "$TEST_HOME/notify-debug.log" 2>/dev/null || echo "")
  if [[ "$notify_log" == *"[success/disk-monitor]"* ]]; then
    printf '  FAIL [%s] disk-monitor success must not invoke success notification\n    log: %q\n' "$CURRENT_TEST" "$notify_log"
    FAILS=$((FAILS + 1))
  fi

  rm -f "$SCRIPT_DIR/disk-monitor-test.sh"
}

test_read_tier_failure_increments_fail_count() {
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "synthetic stderr from claude stub" >&2
exit 2
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

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
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
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
  chmod +x "$TEST_HOME/.bun/bin/claude"

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

test_runner_unknown_value_skipped_at_scan() {
  cat > "$CEO_DIR/playbooks/typo-runner.md" << 'PB'
---
name: typo-runner
description: Playbook with a typo in the runner field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: scrpt
script: typo-runner.sh
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  assert_contains "$scan_out" "unknown runner: 'scrpt'" "scan must skip unknown runner with diagnostic"

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="typo-runner")' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  assert_eq "$entry" "" "skipped playbook must not appear in registry.json"
}

test_runner_unknown_value_rejected_at_dispatch() {
  cat > "$CEO_DIR/playbooks/forced-typo.md" << 'PB'
---
name: forced-typo
description: Valid playbook
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq '(.playbooks[] | select(.name=="forced-typo") | .runner) |= "scrpt"' \
    "$CEO_DIR/registry.json" > "$CEO_DIR/registry.json.tmp"
  mv "$CEO_DIR/registry.json.tmp" "$CEO_DIR/registry.json"

  local rc=0
  CEO_VERBOSE=1 bash "$CRON" forced-typo >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "dispatcher must reject unknown runner with exit 1"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Unknown runner 'scrpt'" "skips log must record unknown-runner rejection"
}

test_runner_ollama_accepted_at_scan() {
  cat > "$CEO_DIR/playbooks/ollama-ok.md" << 'PB'
---
name: ollama-ok
description: Playbook with runner:ollama
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  if [[ "$scan_out" == *"unknown runner: 'ollama'"* ]]; then
    printf '  FAIL [%s] runner:ollama must be accepted at scan\n    scan_out: %q\n' \
      "$CURRENT_TEST" "$scan_out"
    FAILS=$((FAILS + 1))
  fi

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="ollama-ok") | .runner' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  assert_eq "$entry" "ollama" "ollama playbook must be registered with runner:ollama"
}

test_runner_ollama_invokes_ollama_and_skips_claude() {
  cat > "$CEO_DIR/playbooks/ollama-dispatch.md" << 'PB'
---
name: ollama-dispatch
description: Routes to ollama
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-dispatch >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 on ollama success"

  assert_file_exists "$HOME/ollama-invoked-model.txt" "ollama must have been invoked"
  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude was invoked but the ollama-runner branch must skip it\n' \
      "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "mistral-small3.2:24b" "runner:ollama default must be mistral-small3.2:24b"
}

test_runner_ollama_think_uses_gpt_oss_default() {
  cat > "$CEO_DIR/playbooks/ollama-think-dispatch.md" << 'PB'
---
name: ollama-think-dispatch
description: Routes to ollama-think
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama-think
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-think-dispatch >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 on ollama-think success"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "gpt-oss:20b" "runner:ollama-think default must be gpt-oss:20b"
}

test_runner_ollama_explicit_model_overrides_default() {
  cat > "$CEO_DIR/playbooks/ollama-explicit.md" << 'PB'
---
name: ollama-explicit
description: Explicit model override
trigger: cron
schedule: "0 9 * * *"
model: qwen3:14b
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-explicit >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 with explicit ollama model"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "qwen3:14b" "explicit model: tag must override runner default"
}

test_runner_ollama_failure_increments_fail_count() {
  cat > "$CEO_DIR/playbooks/ollama-fail.md" << 'PB'
---
name: ollama-fail
description: ollama exits non-zero
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  # Override the default ollama stub for this test to simulate failure.
  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
echo "ollama-error-sentinel" >&2
exit 9
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-fail >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after ollama failure"

  # Pin: failure must come from the ollama branch specifically. cron-runs.log must
  # NOT contain a completion line for this playbook — that's what proves the
  # ollama branch (not an earlier preflight/schema/missing-file path) failed.
  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-fail completed"* ]]; then
    printf '  FAIL [%s] ollama failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "ollama-error-sentinel" "ollama stderr must be appended to cron-stderr.log"
}

test_runner_ollama_think_accepted_at_scan() {
  cat > "$CEO_DIR/playbooks/ollama-think-ok.md" << 'PB'
---
name: ollama-think-ok
description: Playbook with runner:ollama-think
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama-think
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  if [[ "$scan_out" == *"unknown runner: 'ollama-think'"* ]]; then
    printf '  FAIL [%s] runner:ollama-think must be accepted at scan\n    scan_out: %q\n' \
      "$CURRENT_TEST" "$scan_out"
    FAILS=$((FAILS + 1))
  fi

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="ollama-think-ok") | .runner' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  assert_eq "$entry" "ollama-think" "ollama-think playbook must be registered with runner:ollama-think"
}

test_runner_ollama_model_sonnet_passes_literal() {
  cat > "$CEO_DIR/playbooks/ollama-sonnet.md" << 'PB'
---
name: ollama-sonnet
description: Misconfigured — model:sonnet on ollama runner
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-sonnet >/dev/null 2>&1 || true

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "sonnet" "explicit model:sonnet on runner:ollama must pass literally (not silently coerce to mistral default)"
}

test_runner_ollama_daemon_unreachable_records_failure() {
  cat > "$CEO_DIR/playbooks/ollama-noprobe.md" << 'PB'
---
name: ollama-noprobe
description: Daemon probe enabled, curl fails
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
exit 7
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  env -u CEO_OLLAMA_SKIP_PROBE CEO_VERBOSE=1 bash "$CRON" ollama-noprobe >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "unreachable ollama daemon must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked when daemon probe fails\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_runner_ollama_empty_output_records_failure() {
  cat > "$CEO_DIR/playbooks/ollama-empty.md" << 'PB'
---
name: ollama-empty
description: ollama exits 0 but emits nothing
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-empty >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "empty ollama output must increment FAIL_COUNT_FILE (alert threshold relies on this)"

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-empty completed"* ]]; then
    printf '  FAIL [%s] empty ollama output must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
}

test_runner_ollama_works_under_stripped_path() {
  cat > "$CEO_DIR/playbooks/ollama-strip.md" << 'PB'
---
name: ollama-strip
description: ollama dispatch under stripped PATH (proves ceo_augment_path reaches branch)
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" ollama-strip >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ollama branch must resolve ollama via ceo_augment_path under stripped PATH"
  assert_file_exists "$HOME/ollama-invoked-model.txt" "ollama stub must fire under stripped PATH"
}

test_ceo_augment_path_prepends_user_tool_prefixes() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_augment_path
    echo "$PATH"
  ')
  assert_contains "$out" "/fake/.bun/bin"  "PATH must include ~/.bun/bin"
  assert_contains "$out" "/opt/homebrew/bin" "PATH must include Homebrew prefix"
  assert_contains "$out" "/usr/local/bin"   "PATH must include /usr/local/bin"
  assert_contains "$out" "/fake/.local/bin"  "PATH must include ~/.local/bin"
  assert_contains "$out" "/usr/bin"         "original PATH must be preserved"

  local first_segment="${out%%:*}"
  assert_eq "$first_segment" "/fake/.bun/bin" "augmented prefix must be FIRST on PATH"
}

test_ceo_augment_path_idempotent() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_augment_path; first="$PATH"
    ceo_augment_path; second="$PATH"
    [ "$first" = "$second" ] && echo idempotent || echo diverged
  ')
  assert_eq "$out" "idempotent" "ceo_augment_path must not drift PATH on repeated calls"
}

test_ceo_augment_path_empty_home_aborts() {
  local rc=0
  HOME="" bash -c '
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_augment_path
  ' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] expected non-zero rc with HOME="", got 0\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_ceo_cron_invokes_ceo_augment_path_at_dispatch() {
  cat > "$CEO_DIR/playbooks/path-strip.md" << 'PB'
---
name: path-strip
description: stripped-PATH wiring guard
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" path-strip >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo-cron must invoke ceo_augment_path so dispatcher resolves binaries under stripped PATH"
  assert_file_exists "$HOME/claude-invoked.txt" "claude stub must fire (proves PATH augmentation reached dispatcher)"
}

test_playbook_scan_writes_schema_version_2() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: schema-version regression seed
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local v
  v=$(jq -r '.schema_version // "missing"' "$CEO_DIR/registry.json")
  assert_eq "$v" "2" "playbook scan must write schema_version=2 into registry.json"
}

test_playbook_scan_refuses_newer_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: schema-version downgrade guard
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  printf '{"schema_version":99,"future_field":"must-stay","playbooks":[]}\n' \
    > "$CEO_DIR/registry.json"
  local before
  before=$(cat "$CEO_DIR/registry.json")

  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook scan must refuse to overwrite newer registry schema"

  local after
  after=$(cat "$CEO_DIR/registry.json")
  assert_eq "$after" "$before" "newer registry content must remain unchanged"
}

test_cron_skips_on_missing_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq 'del(.schema_version)' "$CEO_DIR/registry.json" > "$CEO_DIR/registry.json.tmp"
  mv "$CEO_DIR/registry.json.tmp" "$CEO_DIR/registry.json"

  local rc=0
  bash "$CRON" example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cron must exit 1 when registry has no schema_version"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "schema_version" "cron-skips.log must record schema_version reason"

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "schema gate failure must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude must NOT fire when schema gate trips\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_cron_skips_on_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq '.schema_version = 1' "$CEO_DIR/registry.json" > "$CEO_DIR/registry.json.tmp"
  mv "$CEO_DIR/registry.json.tmp" "$CEO_DIR/registry.json"

  local rc=0
  bash "$CRON" example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cron must exit 1 when registry schema_version is below current"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "schema_version" "cron-skips.log must record schema_version reason"

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "schema gate failure must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude must NOT fire when schema gate trips\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_list_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$CEO_DIR/registry.json" > "$CEO_DIR/registry.json.tmp"
  mv "$CEO_DIR/registry.json.tmp" "$CEO_DIR/registry.json"

  local rc=0
  bash "$CEO_CLI" playbook list >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook list must reject old registry schema"
}

test_playbook_info_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$CEO_DIR/registry.json" > "$CEO_DIR/registry.json.tmp"
  mv "$CEO_DIR/registry.json.tmp" "$CEO_DIR/registry.json"

  local rc=0
  bash "$CEO_CLI" playbook info example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook info must reject old registry schema"
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

  local rc=0
  CEO_VERBOSE=1 bash "$CRON" bad-intake >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "missing-script field must exit 1"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "runner:script but no script field" "missing-script error must be logged"
}

test_playbook_scan_blocks_non_primary_host() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0 out
  out=$(CEO_HOSTNAME=beta bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "non-primary host must be refused"
  assert_contains "$out" "primary host" "error must mention primary host gating"
  if [ -f "$CEO_DIR/registry.json" ]; then
    printf '  FAIL [%s] non-primary host wrote registry.json (must not)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_scan_succeeds_on_primary_host() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0
  CEO_HOSTNAME=alpha bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "primary host must be allowed to scan"
  assert_file_exists "$CEO_DIR/registry.json" "registry must be written by primary host"
}

test_playbook_scan_unrestricted_when_primary_host_unset() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{}\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0
  CEO_HOSTNAME=anyhost bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "no primary_host setting → backward-compatible (any host can scan)"
  assert_file_exists "$CEO_DIR/registry.json" "registry must be written when no gate is configured"
}

test_playbook_scan_typoed_primary_host_field_emits_warning() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"promary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0 out
  out=$(CEO_HOSTNAME=beta bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "0" "typo'd key falls through to no-gate (backward-compat) but must warn"
  assert_contains "$out" "unknown key 'promary_host'" "typo'd key must surface a warning so operator notices"
  assert_file_exists "$CEO_DIR/registry.json" "scan continues despite typo (gate is not configured from parser's view)"
}

test_playbook_scan_malformed_settings_json_fails_loud() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf 'not valid json\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0 out
  out=$(CEO_HOSTNAME=anyhost bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "malformed settings.json must fail loud, not silently fall through"
  assert_contains "$out" "not valid JSON" "error must name the JSON parse failure"
  if [ -f "$CEO_DIR/registry.json" ]; then
    printf '  FAIL [%s] registry written despite malformed settings.json\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_scan_missing_jq_with_settings_fails_loud() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$CEO_DIR/registry.json"

  local rc=0 out
  out=$(CEO_JQ_BIN=jq-deliberately-missing-for-test CEO_HOSTNAME=anyhost \
        bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing jq with settings.json must fail loud"
  assert_contains "$out" "jq is not installed" "error must name the missing dependency"
  if [ -f "$CEO_DIR/registry.json" ]; then
    printf '  FAIL [%s] registry written despite missing-jq error\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_scan_preserves_user_installed_bins() {
  mkdir -p "$HOME/.local/bin"
  ln -s "$SCRIPT_DIR/count-blessings.sh" "$HOME/.local/bin/count-blessings"
  ln -s "$SCRIPT_DIR/ceo" "$HOME/.local/bin/ceo"

  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: regression seed — no bin declared
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] playbook scan removed user-installed count-blessings symlink\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ ! -L "$HOME/.local/bin/ceo" ]; then
    printf '  FAIL [%s] playbook scan removed user-installed ceo symlink\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_scan_creates_and_prunes_declared_bin() {
  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: declares a bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
bin: count-blessings.sh
---
PB
  mkdir -p "$HOME/.local/bin"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] declared bin should be symlinked\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
    return
  fi

  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: dropped the bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] previously-managed bin should be pruned when playbook drops it\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_playbook_scan_prunes_dropped_bin_but_keeps_user_bins() {
  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: declares a bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
bin: count-blessings.sh
---
PB
  mkdir -p "$HOME/.local/bin"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] declared bin should be symlinked on first scan\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
    return
  fi

  ln -s "$SCRIPT_DIR/ceo" "$HOME/.local/bin/ceo"

  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: dropped the bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] manifest-driven prune should remove dropped bin\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ ! -L "$HOME/.local/bin/ceo" ]; then
    printf '  FAIL [%s] user-installed ceo symlink should survive prune\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

_write_pending_drip_registry() {
  cat > "$CEO_DIR/playbooks/pending-drip.md" << 'PB'
---
name: pending-drip
description: Test pending drip
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: has_pending_items
tier: read
status: active
---
PB
  cat > "$CEO_DIR/registry.json" << JSON
{"schema_version":2,"playbooks":[{"name":"pending-drip","file":"$CEO_DIR/playbooks/pending-drip.md","model":"haiku","preflight":"has_pending_items","trigger":"cron","tier":"read","status":"active"}]}
JSON
  printf -- '- [ ] pending approval sentinel\n' > "$CEO_DIR/approvals/pending.md"
}

_stub_claude_log_entry() {
  local status="$1"
  local output="$2"
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
#!/bin/bash
cat >/dev/null
cat <<'OUT'
LOG_ENTRY:
## 12:00 - pending-drip
**Status:** $status
**Playbook:** pending-drip.md
**Output:**
$output
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}

test_pending_drip_success_appends_host_inbox_not_report() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local inbox report
  inbox="$CEO_DIR/inbox/testhost.md"
  report="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  assert_file_exists "$inbox" "pending-drip must append to per-host inbox"
  local body
  body=$(cat "$inbox" 2>/dev/null)
  assert_contains "$body" "- [ ] Review pending drip for" "pending-drip inbox item must be unchecked"
  assert_contains "$body" "<!-- pending-drip:" "pending-drip inbox item must include dedupe marker"
  assert_contains "$body" "What is the pending question?" "pending-drip inbox item must include question context"
  if [ -f "$report" ]; then
    printf '  FAIL [%s] successful pending-drip must not append to daily report\n    report: %q\n' "$CURRENT_TEST" "$report"
    FAILS=$((FAILS + 1))
  fi
}

test_pending_drip_rerun_is_idempotent() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true
  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local count
  count=$(grep -c -F "<!-- pending-drip:" "$CEO_DIR/inbox/testhost.md" 2>/dev/null || echo 0)
  assert_eq "$count" "1" "same-day pending-drip rerun must not append duplicate inbox item"
}

test_pending_drip_append_preserves_task_start_after_missing_newline() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"
  mkdir -p "$CEO_DIR/inbox"
  printf -- '- [done] prior item without newline' > "$CEO_DIR/inbox/testhost.md"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local task_count
  task_count=$(grep -c '^- \[ \] Review pending drip' "$CEO_DIR/inbox/testhost.md" 2>/dev/null || echo 0)
  assert_eq "$task_count" "1" "pending-drip append must start on a new line"
}

test_pending_drip_failed_entry_uses_report_not_inbox() {
  _write_pending_drip_registry
  _stub_claude_log_entry "failed" "Something failed"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local inbox report report_body
  inbox="$CEO_DIR/inbox/testhost.md"
  report="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  if [ -s "$inbox" ]; then
    printf '  FAIL [%s] failed pending-drip must not create inbox task\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$inbox")"
    FAILS=$((FAILS + 1))
  fi
  assert_file_exists "$report" "failed pending-drip must use normal report path"
  report_body=$(cat "$report" 2>/dev/null)
  assert_contains "$report_body" "Something failed" "failed pending-drip report must include failure output"
}

test_pending_drip_no_relevant_questions_suppresses_inbox() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "No relevant [ask] questions today."

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  if [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] no-relevant pending-drip must not create inbox task\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox/testhost.md")"
    FAILS=$((FAILS + 1))
  fi
}

# --- inputs: per-playbook injection filter (0.11.0) ---

# Helper: stub claude to capture stdin (the SINGLE_PROMPT) for inspection.
# Removes any prior capture file so a stale read can't pass an assertion if
# the run errors out before the stub fires.
_stub_claude_capture_stdin() {
  rm -f "$HOME/claude-stdin.txt" "$HOME/claude-invoked.txt"
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat > "$HOME/claude-stdin.txt"
echo "claude-fired" > "$HOME/claude-invoked.txt"
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}

test_inputs_absent_injects_all_blocks() {
  cat > "$CEO_DIR/playbooks/inputs-default.md" << 'PB'
---
name: inputs-default
description: No inputs field — should get all blocks
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-default >/dev/null 2>&1 || true

  assert_file_exists "$HOME/claude-stdin.txt" "claude must have been invoked"
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "Pending approvals:" "default-all: pending_count line present"
  assert_contains "$prompt" "PRs requesting review:" "default-all: pr_data line present"
  assert_contains "$prompt" "Briefing-specific training" "default-all: briefings_training block present"
  assert_contains "$prompt" "Active Domains priority order" "default-all: active_domains block present"
}

test_inputs_empty_array_excludes_all_blocks() {
  cat > "$CEO_DIR/playbooks/inputs-empty.md" << 'PB'
---
name: inputs-empty
description: inputs:[] explicitly opts out of all gather blocks
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs: []
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-empty >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  if [[ "$prompt" == *"Pending approvals:"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress pending_count line\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Briefing-specific training"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress briefings_training block\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"PRs requesting review:"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress pr_data lines\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_inputs_subset_includes_only_listed() {
  cat > "$CEO_DIR/playbooks/inputs-subset.md" << 'PB'
---
name: inputs-subset
description: Only pr_data and blessings — others must be absent
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs:
  - pr_data
  - blessings
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-subset >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "PRs requesting review:" "subset: pr_data line present"
  if [[ "$prompt" == *"Briefing-specific training"* ]]; then
    printf '  FAIL [%s] subset: briefings_training must be absent (not in inputs list)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Pending approvals:"* ]]; then
    printf '  FAIL [%s] subset: pending_count must be absent (not in inputs list)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Active Domains priority order"* ]]; then
    printf '  FAIL [%s] subset: active_domains must be absent\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

test_inputs_unknown_key_warns_at_scan() {
  cat > "$CEO_DIR/playbooks/inputs-typo.md" << 'PB'
---
name: inputs-typo
description: Has a typo'd input key
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs:
  - pr_data
  - bogus_key
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "unknown key" "scan must warn on typo'd input key"
  assert_contains "$out" "bogus_key" "warning must name the offending key"
}

test_inputs_non_array_warns_and_defaults_to_all() {
  cat > "$CEO_DIR/playbooks/inputs-scalar.md" << 'PB'
---
name: inputs-scalar
description: Inputs is a scalar — should warn and default to all
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs: pr_data
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be an array" "scan must warn when inputs is not an array"

  # Default-all behavior should hold — verify by running and checking the prompt
  _stub_claude_capture_stdin
  CEO_VERBOSE=1 bash "$CRON" inputs-scalar >/dev/null 2>&1 || true
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "Briefing-specific training" "non-array inputs must default to all (briefings present)"
  assert_contains "$prompt" "PRs requesting review:" "non-array inputs must default to all (pr_data present)"
}

test_repo_playbook_auto_registers_with_absolute_file_path() {
  local repo_dir="$TEST_HOME/repo-pb"
  local repo_pb="$repo_dir/_test-repo-pb.md"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"
  cat > "$repo_pb" << 'PB'
---
name: _test-repo-pb
description: Repo-side playbook for scan test
trigger: chat
preflight: none
tier: read
status: active
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "ADD   _test-repo-pb" "repo playbook must be picked up by scan"

  local file_field
  file_field=$(jq -r '.playbooks[] | select(.name=="_test-repo-pb") | .file' "$CEO_DIR/registry.json")
  assert_eq "${file_field:0:1}" "/" "repo playbook .file must be absolute"
  assert_contains "$file_field" "_test-repo-pb.md" "repo playbook .file must point at repo path"
}

test_vault_playbook_shadows_repo_playbook_with_same_name() {
  local repo_dir="$TEST_HOME/repo-pb"
  local repo_pb="$repo_dir/_test-shadow.md"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"
  cat > "$repo_pb" << 'PB'
---
name: _test-shadow
description: Repo version
trigger: chat
preflight: none
tier: read
status: active
---
PB

  cat > "$CEO_DIR/playbooks/_test-shadow.md" << 'PB'
---
name: _test-shadow
description: Vault override
trigger: chat
preflight: none
tier: read
status: inactive
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "SHADOW" "scan must report shadowing"

  local desc status
  desc=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .description' "$CEO_DIR/registry.json")
  status=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .status' "$CEO_DIR/registry.json")
  assert_eq "$desc" "Vault override" "vault entry must win on collision"
  assert_eq "$status" "inactive" "vault status must override repo status"
}

test_repo_internal_duplicate_logs_dup_not_shadow() {
  local repo_dir="$TEST_HOME/repo-pb"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"

  cat > "$repo_dir/_test-twin-a.md" << 'PB'
---
name: _test-twin
description: First repo file
trigger: chat
preflight: none
tier: read
status: active
---
PB
  cat > "$repo_dir/_test-twin-b.md" << 'PB'
---
name: _test-twin
description: Second repo file
trigger: chat
preflight: none
tier: read
status: active
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "DUP" "two repo files with same name must log DUP"
  if [[ "$out" == *"SHADOW"* ]]; then
    printf '  FAIL [%s] repo-internal dup must NOT log SHADOW (no vault override exists)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
}

run_tests() {
  local count=0
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if [ -n "${TEST_FILTER:-}" ] && [[ "$fn" != *"$TEST_FILTER"* ]]; then
      continue
    fi
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
