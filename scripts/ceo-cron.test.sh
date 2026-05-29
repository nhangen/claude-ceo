#!/bin/bash
# Self-contained test harness for the ceo-cron.sh script-runner branch.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
CRON="$SCRIPT_DIR/ceo-cron.sh"

source "$SCRIPT_DIR/test-harness.sh"

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

  # Isolate cron lock to this test invocation
  export CEO_LOCK_FILE="$TEST_HOME/ceo-cron.lock"

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/approvals" "$CEO_DIR/reports"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"
  echo "- [ ] test task" > "$CEO_DIR/approvals/pending.md"

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
  unset CEO_VAULT CEO_DIR TEST_HOME HOME_BACKUP PATH_BACKUP CEO_REPO_PLAYBOOK_DIR CEO_OLLAMA_SKIP_PROBE CEO_LOCK_FILE
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_tier_posts_full_report_to_discord_report_webhook() {
  cat > "$CEO_DIR/playbooks/morning-brief.md" << 'PB'
---
name: morning-brief
description: Morning brief
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — morning-brief
**Status:** completed
**Playbook:** playbooks/morning-brief.md
**Output:**
Full morning body from the model.
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$HOME/.bun/bin/claude"

  mkdir -p "$TEST_HOME/curl"
  export CURL_CAPTURE_DIR="$TEST_HOME/curl"
  cat > "$HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
out="$CURL_CAPTURE_DIR/payload.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      shift
      printf '%s' "$1" > "$out"
      ;;
  esac
  shift || true
done
exit 0
STUB
  chmod +x "$HOME/.bun/bin/curl"

  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' \
    > "$HOME/.config/claude-ceo/secrets.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" morning-brief >/dev/null 2>&1

  local payload
  payload=$(cat "$CURL_CAPTURE_DIR/payload.json" 2>/dev/null || echo "")
  assert_contains "$payload" "CEO full report: morning-brief" \
    "cron must post a full-report Discord message for morning-brief"
  assert_contains "$payload" "Full morning body from the model." \
    "Discord payload must include the parsed LOG_ENTRY body"

  unset CURL_CAPTURE_DIR
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_skips_preamble_files() {
  cat > "$CEO_DIR/playbooks/ollama-preamble.md" << 'PB'
---
name: ollama-preamble
description: Assert AGENTS/IDENTITY omitted
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# my-playbook-body
PB

  echo "SENTINEL_AGENT_CONTENT" > "$CEO_DIR/AGENTS.md"
  echo "SENTINEL_IDENTITY_CONTENT" > "$CEO_DIR/IDENTITY.md"
  echo "SENTINEL_TRAINING_CONTENT" > "$CEO_DIR/TRAINING.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-preamble >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/ollama-invoked-prompt.txt" 2>/dev/null || echo "")

  if [[ "$prompt" == *"SENTINEL_AGENT_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain AGENTS.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"SENTINEL_IDENTITY_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain IDENTITY.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"SENTINEL_TRAINING_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain TRAINING.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$prompt" "my-playbook-body" "ollama prompt must contain the playbook body"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_read_tier_includes_pre_gathered_data() {
  # Seed approvals/pending.md with three unchecked items so PENDING_COUNT=3
  # (per ceo-gather.sh's `grep -c "^- \[ \]" approvals/pending.md`). The
  # sentinel value lets us prove the gathered count reached the ollama prompt.
  cat > "$CEO_DIR/approvals/pending.md" << 'PENDING'
# Pending

- [ ] sentinel-pending-item-A
- [ ] sentinel-pending-item-B
- [ ] sentinel-pending-item-C
PENDING

  cat > "$CEO_DIR/playbooks/ollama-pregather.md" << 'PB'
---
name: ollama-pregather
description: Verify pre-gathered data injection on ollama+tier:read
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# ollama-pregather-playbook-body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-pregather >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/ollama-invoked-prompt.txt" 2>/dev/null || echo "")
  assert_contains "$prompt" "PRE-GATHERED DATA" "ollama+tier:read prompt must include PRE-GATHERED DATA section"
  assert_contains "$prompt" "ollama-pregather-playbook-body" "ollama prompt must include playbook body"
  assert_contains "$prompt" "PLAYBOOK (ollama-pregather)" "ollama prompt must label the playbook"
  # Sentinel pin: the seeded inbox count must reach the prompt body. A revert
  # of the SINGLE_PROMPT_BODY split (so ollama got only the playbook file)
  # would not surface PENDING_COUNT — the literal "3 pending" disappears.
  assert_contains "$prompt" "3 pending" "pre-gathered PENDING_COUNT (sentinel: 3) must reach ollama prompt"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_prompt_exceeds_budget_fails() {
  cat > "$CEO_DIR/playbooks/ollama-toolarge.md" << 'PB'
---
name: ollama-toolarge
description: Tests CEO_OLLAMA_MAX_PROMPT_BYTES budget enforcement
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# ollama-toolarge-body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_OLLAMA_MAX_PROMPT_BYTES=100 CEO_VERBOSE=1 bash "$CRON" ollama-toolarge >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "oversized prompt must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked when prompt exceeds budget\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "exceeds budget (" "skips log must record oversized-prompt reason with byte counts"

  # Forensic capture: the offending prompt context lands in cron-raw.log so a
  # human investigating "why is morning-brief over budget on Tuesdays" has an
  # artifact to inspect (mirrors the claude failure-path capture).
  local raw_log
  raw_log=$(cat "$CEO_DIR/log/cron-raw.log" 2>/dev/null || echo "")
  assert_contains "$raw_log" "Prompt exceeds budget" "cron-raw.log must capture budget-exceeded events"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_rejects_non_read_tier() {
  cat > "$CEO_DIR/playbooks/ollama-writetier.md" << 'PB'
---
name: ollama-writetier
description: ollama on non-read tier must reject before any dispatch
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: low-stakes-write
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-writetier >/dev/null 2>&1 || rc=$?

  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] ollama with non-read tier must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked for non-read tier\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "ollama runner requires tier:read" "skips log must record reject reason"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_think_rejects_non_read_tier() {
  # Sibling pin for runner:ollama-think — the guard at ceo-cron.sh:459 covers
  # both ollama variants, so a regression that drops one side would leak.
  cat > "$CEO_DIR/playbooks/ollama-think-writetier.md" << 'PB'
---
name: ollama-think-writetier
description: ollama-think on non-read tier must reject
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: low-stakes-write
status: active
runner: ollama-think
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-think-writetier >/dev/null 2>&1 || rc=$?

  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] ollama-think with non-read tier must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama-think must NOT be invoked for non-read tier\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_success_routes_through_ceo_report_intake() {
  # Pins Finding 1 of the panel review: morning-brief / morning-scan after the
  # ollama switch must still land in CEO/reports/<date>.md and trigger the
  # Discord side-channel — same as the claude path. Regression-test for the
  # bug where the ollama branch wrote directly to LOG_FILE and bypassed
  # ceo-report.sh entirely.

  cat > "$CEO_DIR/playbooks/ollama-intake.md" << 'PB'
---
name: ollama-intake
description: ollama success must route through ceo-report.sh intake
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  # ollama stub emits a parseable LOG_ENTRY block — the helper extracts and
  # routes through ceo-report.sh intake, which writes to REPORT_FILE and
  # fires the Discord side-channel via curl. We capture curl to assert the
  # side-channel fired (same shape as test_read_tier_posts_full_report).
  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "run" ]; then
  echo "$2" > "$HOME/ollama-invoked-model.txt"
  cat > "$HOME/ollama-invoked-prompt.txt"
  cat << 'OUT'
LOG_ENTRY:
## 09:00 — ollama-intake
**Status:** completed
**Playbook:** playbooks/ollama-intake.md
**Output:**
Hello from ollama-intake-sentinel.
**Errors:**
- none
END_LOG_ENTRY
OUT
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  mkdir -p "$TEST_HOME/curl"
  export CURL_CAPTURE_DIR="$TEST_HOME/curl"
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
out="$CURL_CAPTURE_DIR/payload.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) shift; printf '%s' "$1" > "$out" ;;
  esac
  shift || true
done
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' \
    > "$HOME/.config/claude-ceo/secrets.json"
  # ceo-discord-report.sh defaults the trigger allowlist to ["morning-brief"];
  # extend it so this test playbook is allowed to fire the side channel.
  echo '{"discord_report_triggers": ["ollama-intake"]}' \
    > "$CEO_DIR/settings.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-intake >/dev/null 2>&1 || true

  # REPORT_FILE must exist with the intake entry — this is the canonical
  # write that breaks if the ollama branch skips ceo-report.sh.
  local report_file
  report_file="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  assert_file_exists "$report_file" "ollama success must write to CEO/reports/<date>.md via ceo-report.sh intake"
  local report
  report=$(cat "$report_file" 2>/dev/null || echo "")
  assert_contains "$report" "ollama-intake-sentinel" "report file must contain the LOG_ENTRY body"
  assert_contains "$report" "ollama-intake [intake]" "report header must be intake-tagged"

  # Discord side-channel fires (proves intake routing is reached, not just
  # report-file append — they're separate concerns inside ceo-report.sh).
  local payload
  payload=$(cat "$CURL_CAPTURE_DIR/payload.json" 2>/dev/null || echo "")
  assert_contains "$payload" "ollama-intake-sentinel" "Discord side-channel must fire on ollama success"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_self_reported_failed_records_failure() {
  # Pins Finding 1 second facet: a model that emits **Status:** failed inside
  # its LOG_ENTRY block must increment FAIL_COUNT_FILE — not silently record
  # success because the exit code was 0 and stdout was non-empty.

  cat > "$CEO_DIR/playbooks/ollama-selffail.md" << 'PB'
---
name: ollama-selffail
description: ollama self-reports failed → must increment fail count
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
if [ "${1:-}" = "run" ]; then
  cat << 'OUT'
LOG_ENTRY:
## 09:00 — ollama-selffail
**Status:** failed
**Playbook:** playbooks/ollama-selffail.md
**Output:**
Simulated playbook failure.
**Errors:**
- something broke during synthesis
END_LOG_ENTRY
OUT
  exit 0
fi
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-selffail >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "model self-reporting **Status:** failed must increment FAIL_COUNT_FILE (silent-success invariant)"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "self-reported" "cron-skips.log must record self-reported-failure reason"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_claude_self_reported_failed_records_failure() {
  # Sibling invariant: the same shape on the claude path. Before the
  # _dispatch_single_output helper consolidation, claude swallowed
  # model-self-reported failures and recorded success. The helper now gates
  # both runners through the same check.

  cat > "$CEO_DIR/playbooks/claude-selffail.md" << 'PB'
---
name: claude-selffail
description: claude self-reports failed → must increment fail count
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — claude-selffail
**Status:** failed
**Playbook:** playbooks/claude-selffail.md
**Output:**
Simulated claude failure.
**Errors:**
- broken
END_LOG_ENTRY
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" claude-selffail >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "claude path: model self-reporting **Status:** failed must increment FAIL_COUNT_FILE"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_production_morning_brief_registers_with_ollama_runner() {
  # Pins Finding 2 of the panel review: the actual docs/playbooks/morning-brief.md
  # in the repo must register with runner: ollama + tier: read after this PR.
  # A typo in the frontmatter (e.g. `runner: olllama`) would silently ship
  # green without this test — the unit tests above use synthetic playbooks.

  local repo_playbook="$SCRIPT_DIR/../docs/playbooks/morning-brief.md"
  if [ ! -f "$repo_playbook" ]; then
    printf '  FAIL [%s] cannot find production playbook at %q\n' \
      "$CURRENT_TEST" "$repo_playbook"
    FAILS=$((FAILS + 1))
    return
  fi
  cp "$repo_playbook" "$CEO_DIR/playbooks/morning-brief.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local runner tier model
  runner=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .runner' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  tier=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .tier' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  model=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .model' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  assert_eq "$runner" "ollama" "production morning-brief.md must declare runner: ollama"
  assert_eq "$tier" "read" "production morning-brief.md must declare tier: read"
  assert_eq "$model" "mistral-small3.2:24b" "production morning-brief.md must declare model: mistral-small3.2:24b"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_production_morning_scan_registers_with_ollama_runner() {
  local repo_playbook="$SCRIPT_DIR/../docs/playbooks/morning-scan.md"
  if [ ! -f "$repo_playbook" ]; then
    printf '  FAIL [%s] cannot find production playbook at %q\n' \
      "$CURRENT_TEST" "$repo_playbook"
    FAILS=$((FAILS + 1))
    return
  fi
  cp "$repo_playbook" "$CEO_DIR/playbooks/morning-scan.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local runner tier model
  runner=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .runner' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  tier=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .tier' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  model=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .model' "$CEO_DIR/registry.json" 2>/dev/null || echo "")
  assert_eq "$runner" "ollama" "production morning-scan.md must declare runner: ollama"
  assert_eq "$tier" "read" "production morning-scan.md must declare tier: read"
  assert_eq "$model" "mistral-small3.2:24b" "production morning-scan.md must declare model: mistral-small3.2:24b"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_prepends_user_tool_prefixes() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_detect_os() { echo "macos"; }
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_idempotent() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_detect_os() { echo "macos"; }
    ceo_augment_path; first="$PATH"
    ceo_augment_path; second="$PATH"
    [ "$first" = "$second" ] && echo idempotent || echo diverged
  ')
  assert_eq "$out" "idempotent" "ceo_augment_path must not drift PATH on repeated calls"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_empty_home_aborts() {
  local rc=0
  HOME="" bash -c '
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_augment_path
  ' >/dev/null 2>&1 || rc=$?
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] expected non-zero rc with HOME="", got 0\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_writes_schema_version_3() {
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
  assert_eq "$v" "3" "playbook scan must write schema_version=3 into registry.json"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cmd_chat_rejects_old_schema_version() {
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
  bash "$CEO_CLI" chat example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cmd_chat must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cmd_preflight_rejects_old_schema_version() {
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
  bash "$CEO_CLI" preflight >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cmd_preflight must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
{"schema_version":3,"playbooks":[{"name":"pending-drip","file":"$CEO_DIR/playbooks/pending-drip.md","model":"haiku","preflight":"has_pending_items","trigger":"cron","tier":"read","status":"active"}]}
JSON
  printf -- '- [ ] pending approval sentinel\n' > "$CEO_DIR/approvals/pending.md"
  printf -- '- [ ] **file:** sentinel.md **question:** sentinel ask?\n' > "$CEO_VAULT/Pending.md"
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_skips_when_pending_md_empty() {
  _write_pending_drip_registry
  # Setup line 32 + helper line 1885 leave $CEO_DIR/approvals/pending.md
  # populated (PENDING_COUNT > 0). Remove Pending.md so PENDING_ASK_QUESTIONS
  # is empty — this is the literal bug shape that motivated the fix at
  # scripts/ceo-cron.sh:369. Reverting that gate must make this test fail.
  rm -f "$CEO_VAULT/Pending.md"
  _stub_claude_log_entry "completed" "should never run"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local skip_log="$CEO_DIR/log/cron-skips.log"
  assert_file_exists "$skip_log" "preflight skip must write cron-skips.log"
  local skip_body
  skip_body=$(cat "$skip_log" 2>/dev/null)
  assert_contains "$skip_body" "preflight 'has_pending_items' returned no-work" \
    "empty Pending.md must trigger preflight no-work skip even when approvals/pending.md is populated"

  if [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] empty Pending.md must not produce inbox entry\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox/testhost.md")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_no_relevant_questions_suppresses_inbox() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "No relevant [ask] questions today."

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  if [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] no-relevant pending-drip must not create inbox task\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox/testhost.md")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_rate_limit_falls_back_to_ollama_on_read_tier() {
  cat > "$CEO_DIR/playbooks/ratelimit.md" << 'PB'
---
name: ratelimit
description: hit the limit
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # Stub claude to return rate limit exit code and text
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "You've hit your session limit · resets 5:10am (America/New_York)"
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  local rc=0
  bash "$CRON" ratelimit >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 after falling back to ollama"
  
  local skip_log
  skip_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skip_log" "Falling back to ollama" "cron-skips.log must mention fallback"
  
  local ollama_invoked
  ollama_invoked=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_contains "$ollama_invoked" "mistral-small" "ollama must be invoked with default model during fallback"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_rate_limit_fallback_ignores_claude_model_frontmatter() {
  # Regression: a runner:claude playbook with model:haiku|sonnet (Claude tier
  # name) must NOT pass that name through to `ollama run` when the rate-limit
  # fallback flips RUNNER to ollama. The invariant is "rate-limit fallback is
  # 100% ollama-mapped"; frontmatter model overrides apply only to native
  # runner:ollama playbooks, not to a runtime-flipped runner.
  cat > "$CEO_DIR/playbooks/ratelimit-haiku.md" << 'PB'
---
name: ratelimit-haiku
description: claude-tier playbook that declares model:haiku
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "You've hit your session limit · resets 5:10am (America/New_York)"
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  local rc=0
  bash "$CRON" ratelimit-haiku >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 after falling back to ollama"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "mistral-small3.2:24b" "fallback must use the runner-default ollama model, not the Claude-tier frontmatter name"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_cron_skips_read_tier_on_failed_gather() {
  cat > "$CEO_DIR/playbooks/morning-brief.md" << 'PB'
---
name: morning-brief
description: briefing
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # Force gather phase to fail by emptying pending tasks
  : > "$CEO_DIR/approvals/pending.md"

  local rc=0
  bash "$CRON" morning-brief >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 on failed gather"
  
  local skip_log
  skip_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skip_log" "Gather phase empty" "cron-skips.log must mention gather phase empty"
  
  local report
  report=$(cat "$CEO_DIR/reports/$(date +%Y-%m-%d).md" 2>/dev/null || echo "")
  assert_contains "$report" "skipped: gather-empty" "report must show skipped status"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_located_and_success() {
  cat > "$CEO_DIR/playbooks/skill-success.md" << 'PB'
---
name: skill-success
description: skill executes successfully
trigger: cron
status: active
tier: read
runner: skill
skill: test-skill
out_pattern: CEO/reports/test/${TODAY}-${HOSTNAME}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/test-skill/scripts"
  cat > "$HOME/.claude/skills/test-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
echo "test-skill output" > "$out_dir/report.md"
EOF
  chmod +x "$HOME/.claude/skills/test-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-success >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "runner:skill must exit 0 on success"

  local expected_out
  expected_out="$CEO_DIR/reports/test/$(date +%Y-%m-%d)-$(hostname -s).md"
  assert_file_exists "$expected_out" "runner:skill must write to interpolated out_pattern"
  local content
  content=$(cat "$expected_out" 2>/dev/null || echo "")
  assert_contains "$content" "test-skill output" "runner:skill must capture skill stdout"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_missing_skill_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-missing.md" << 'PB'
---
name: skill-missing
description: skill script does not exist
trigger: cron
status: active
tier: read
runner: skill
skill: nonexistent-skill
out_pattern: CEO/reports/test/missing.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-missing >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill is missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill script not found" "skips log must record missing skill script"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_missing_credential_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-creds.md" << 'PB'
---
name: skill-creds
description: skill missing required credential
trigger: cron
status: active
tier: read
runner: skill
skill: test-skill
out_pattern: CEO/reports/test/creds.md
requires: ["MISSING_TEST_VAR"]
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  # Don't create the skill script because we want it to fail on the credential gate
  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-creds >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when credentials are missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "missing credential(s) MISSING_TEST_VAR" "skips log must record missing credential"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_no_output_file_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-noout.md" << 'PB'
---
name: skill-noout
description: skill produces no output file
trigger: cron
status: active
tier: read
runner: skill
skill: noout-skill
out_pattern: CEO/reports/test/noout.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/noout-skill/scripts"
  cat > "$HOME/.claude/skills/noout-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$HOME/.claude/skills/noout-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-noout >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill output is missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill produced no output file" "skips log must record missing output file failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_empty_output_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-empty.md" << 'PB'
---
name: skill-empty
description: skill produces empty output
trigger: cron
status: active
tier: read
runner: skill
skill: empty-skill
out_pattern: CEO/reports/test/empty.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/empty-skill/scripts"
  cat > "$HOME/.claude/skills/empty-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
touch "$out_dir/empty.md"
EOF
  chmod +x "$HOME/.claude/skills/empty-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-empty >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill output is empty"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill produced empty output" "skips log must record empty output failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_workload_report_stub_produces_output() {
  cat > "$CEO_DIR/playbooks/workload-report.md" << 'PB'
---
name: workload-report
description: The migrated workload-report playbook
trigger: cron
status: active
tier: read
runner: skill
skill: workload-report
out_pattern: CEO/reports/workload/${TODAY}-${HOSTNAME}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/workload-report/scripts"
  cat > "$HOME/.claude/skills/workload-report/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
echo "workload report stub" > "$out_dir/report.md"
EOF
  chmod +x "$HOME/.claude/skills/workload-report/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" workload-report >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "workload-report skill runner must exit 0"

  local expected_out
  expected_out="$CEO_DIR/reports/workload/$(date +%Y-%m-%d)-$(hostname -s).md"
  assert_file_exists "$expected_out" "workload-report must produce correct interpolated file"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
