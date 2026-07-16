#!/bin/bash
# ceo-cron.sh tests — misc / pre-marker cron tests.
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"

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


test_cron_rejects_trigger_with_quote() {
  local rc=0
  bash "$CRON" 'bad"trigger' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject trigger names containing shell metacharacters"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "invalid trigger" "stderr must explain rejection"
}


test_cron_rejects_trigger_with_path_traversal() {
  local rc=0
  bash "$CRON" '../etc' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject trigger names containing path separators"
}


test_cron_rejects_pure_dot_trigger() {
  local rc=0
  bash "$CRON" '..' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject '..' (would land in .last-run-.. path)"
}


test_cron_rejects_leading_dot_trigger() {
  local rc=0
  bash "$CRON" '.hidden' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject names starting with '.'"
}


test_cron_accepts_valid_trigger_shapes() {
  cat > "$CEO_DIR/playbooks/valid-trigger_1.md" << 'PB'
---
name: valid-trigger_1
description: shape-validation acceptance fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: shape-noop.sh
---
PB
  cat > "$SCRIPT_DIR/shape-noop.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/shape-noop.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" valid-trigger_1 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo-cron.sh must accept trigger names matching [A-Za-z0-9._-]+"
  rm -f "$SCRIPT_DIR/shape-noop.sh"
}


test_runner_claude_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-claude.md" << 'PB'
---
name: playbook-id-claude
description: Verifies CEO_PLAYBOOK_ID is exported to the claude runner
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  cat > "$TEST_HOME/.bun/bin/claude" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-claude.txt"
cat >/dev/null
echo "ACTION: 1 | read | noop | n/a"
SH
  chmod +x "$TEST_HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-claude >/dev/null 2>&1 || true
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-claude.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-claude" "claude runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
}


test_runner_ollama_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-ollama.md" << 'PB'
---
name: playbook-id-ollama
description: Verifies CEO_PLAYBOOK_ID is exported to the ollama runner
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# Body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-ollama.txt"
cat >/dev/null
printf 'ollama-stub-response' | jq -Rs '{response:.}'
SH
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-ollama >/dev/null 2>&1 || true
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-ollama.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-ollama" "ollama runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
}


test_runner_skill_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-skill.md" << 'PB'
---
name: playbook-id-skill
description: Verifies CEO_PLAYBOOK_ID is exported to the skill runner
trigger: cron
status: active
tier: read
runner: skill
skill: playbook-id-skill
out_pattern: CEO/reports/playbook-id-skill/${TODAY}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/playbook-id-skill/scripts"
  cat > "$HOME/.claude/skills/playbook-id-skill/scripts/run-report.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-skill.txt"
printf '%s' "\${CEO_MODEL_SOURCE:-UNSET}" > "$TEST_HOME/skill-source-from-child.txt"
printf '%s' "\${CEO_RUNNER_ARTIFACT:-UNSET}" > "$TEST_HOME/skill-artifact-from-child.txt"
while [[ "\$#" -gt 0 ]]; do
  case \$1 in --out) out_dir="\$2"; shift ;; esac
  shift
done
echo "skill stub" > "\$out_dir/report.md"
SH
  chmod +x "$HOME/.claude/skills/playbook-id-skill/scripts/run-report.sh"

  PATH=/usr/bin:/bin bash "$CRON" playbook-id-skill >/dev/null 2>&1 || true
  local got got_source got_artifact
  got=$(cat "$TEST_HOME/playbook-id-from-skill.txt" 2>/dev/null || echo "MISSING")
  got_source=$(cat "$TEST_HOME/skill-source-from-child.txt" 2>/dev/null || echo "MISSING")
  got_artifact=$(cat "$TEST_HOME/skill-artifact-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-skill" "skill runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
  assert_eq "$got_source" "declared" "skill runner must export CEO_MODEL_SOURCE=declared (frontmatter claim, not harness-invoked)"
  assert_eq "$got_artifact" "playbook-id-skill" "skill runner must export CEO_RUNNER_ARTIFACT=<skill name> for the Discord embed"
}


test_runner_script_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-script.md" << 'PB'
---
name: playbook-id-script
description: Verifies CEO_PLAYBOOK_ID is exported to script-runner children
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: playbook-id-script.sh
---
PB

  cat > "$SCRIPT_DIR/playbook-id-script.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-child.txt"
SH
  chmod +x "$SCRIPT_DIR/playbook-id-script.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-script >/dev/null 2>&1
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-script" "script-runner must export CEO_PLAYBOOK_ID=<trigger> to its child"

  rm -f "$SCRIPT_DIR/playbook-id-script.sh"
}


test_runner_script_exports_frontmatter_model_not_runner_name() {
  cat > "$CEO_DIR/playbooks/model-script.md" << 'PB'
---
name: model-script
description: Verifies CEO_MODEL carries the frontmatter model for a script runner
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: model-script.sh
model: sonnet
---
PB
  cat > "$CEO_DIR/playbooks/pureshell-script.md" << 'PB'
---
name: pureshell-script
description: Verifies CEO_MODEL is empty for a script runner with no model
trigger: cron
schedule: "30 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: pureshell-script.sh
---
PB

  cat > "$SCRIPT_DIR/model-script.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_MODEL:-UNSET}" > "$TEST_HOME/model-from-child.txt"
printf '%s' "\${CEO_MODEL_SOURCE:-UNSET}" > "$TEST_HOME/source-from-child.txt"
printf '%s' "\${CEO_RUNNER_ARTIFACT:-UNSET}" > "$TEST_HOME/artifact-from-child.txt"
SH
  cat > "$SCRIPT_DIR/pureshell-script.sh" << SH
#!/bin/bash
printf '[%s]' "\${CEO_MODEL-UNSET}" > "$TEST_HOME/pureshell-model-from-child.txt"
SH
  chmod +x "$SCRIPT_DIR/model-script.sh" "$SCRIPT_DIR/pureshell-script.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" model-script >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" pureshell-script >/dev/null 2>&1
  local got_model got_pure got_source got_artifact
  got_model=$(cat "$TEST_HOME/model-from-child.txt" 2>/dev/null || echo "MISSING")
  got_pure=$(cat "$TEST_HOME/pureshell-model-from-child.txt" 2>/dev/null || echo "MISSING")
  got_source=$(cat "$TEST_HOME/source-from-child.txt" 2>/dev/null || echo "MISSING")
  got_artifact=$(cat "$TEST_HOME/artifact-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_model" "sonnet" "script-runner must export CEO_MODEL=<frontmatter model>, not the runner name"
  assert_eq "$got_pure" "[]" "script-runner with no model must export CEO_MODEL empty, not 'script'"
  assert_eq "$got_source" "declared" "script-runner must export CEO_MODEL_SOURCE=declared (frontmatter claim, not harness-invoked)"
  assert_eq "$got_artifact" "model-script.sh" "script-runner must export CEO_RUNNER_ARTIFACT=<script file> for the Discord embed"

  rm -f "$SCRIPT_DIR/model-script.sh" "$SCRIPT_DIR/pureshell-script.sh"
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
  local got_source
  got_source=$(cat "$HOME/claude-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "claude runner must export CEO_MODEL_SOURCE=invoked (harness drove the model)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_pipeline_claude_exports_invoked_source() {
  cat > "$CEO_DIR/playbooks/pipeline-claude.md" << 'PB'
---
name: pipeline-claude
description: Low-stakes-write playbook locking the three-phase pipeline CEO_MODEL_SOURCE export
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: low-stakes-write
status: active
---
# Body
PB
  rm -f "$HOME/claude-model-source.txt"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" pipeline-claude >/dev/null 2>&1 || true
  local got_source
  got_source=$(cat "$HOME/claude-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "three-phase pipeline (low-stakes-write) claude runner must export CEO_MODEL_SOURCE=invoked"
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

  # The read-tier single-call path always requests --output-format json and
  # extracts the body via `jq -r '.result'`, so the stub emits a JSON envelope.
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
{"result":"LOG_ENTRY:\n## 09:00 — morning-brief\n**Status:** completed\n**Playbook:** playbooks/morning-brief.md\n**Output:**\nFull morning body from the model.\n**Errors:**\n- none\nEND_LOG_ENTRY","total_cost_usd":0.001,"session_id":"test"}
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

run_tests
