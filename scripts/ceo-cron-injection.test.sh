#!/bin/bash
# ceo-cron.sh tests — per-playbook injection filter (0.11.0).
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


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
  assert_contains "$prompt" "PR data (recently merged):" "default-all: merged-PR line present (#163)"
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
  if [[ "$prompt" == *"PR data (recently merged):"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress the merged-PR line (#163)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_plan_prompt_carries_merged_pr_data() {
  cat > "$CEO_DIR/playbooks/plan-merged.md" << 'PB'
---
name: plan-merged
description: high-stakes playbook — PLAN prompt must carry the merged-PR data (#163)
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: high-stakes
status: active
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" plan-merged --dry-run --depth plan >/dev/null 2>&1 || true

  assert_file_exists "$HOME/claude-stdin.txt" "PLAN phase must invoke the model"
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "PR data (recently merged):" "PLAN prompt must carry merged-PR data — reconcile classifies in PLAN (#163)"
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


test_inputs_morning_flow_keys_do_not_warn() {
  cat > "$CEO_DIR/playbooks/inputs-morning.md" << 'PB'
---
name: inputs-morning
description: Morning flow playbook with new input keys
trigger: cron
schedule: "0 7 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs:
  - current_sprint
  - yesterday_merged
  - ledger_recent
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  if echo "$out" | grep -q "unknown key.*current_sprint\|unknown key.*yesterday_merged\|unknown key.*ledger_recent"; then
    printf '  FAIL [%s] scan must NOT warn on valid morning-flow keys (current_sprint, yesterday_merged, ledger_recent)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
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
  file_field=$(jq -r '.playbooks[] | select(.name=="_test-repo-pb") | .file' "$REGISTRY_FILE")
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
status: disabled
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "SHADOW" "scan must report shadowing"

  local desc status
  desc=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .description' "$REGISTRY_FILE")
  status=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .status' "$REGISTRY_FILE")
  assert_eq "$desc" "Vault override" "vault entry must win on collision"
  assert_eq "$status" "disabled" "vault status must override repo status"
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
  assert_contains "$ollama_invoked" "glm4" "ollama must be invoked with default model during fallback"
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
  assert_eq "$model" "glm4:latest" "fallback must use the runner-default ollama model, not the Claude-tier frontmatter name"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_claude_auth_failure_does_not_fall_back_and_exits_nonzero() {
  # Auth failure must NOT fall back to ollama (a local-model report would
  # re-mute the logged-out alarm). Fails if the auth path is reverted to
  # fall-open: then rc would be 0 and ollama would be invoked.
  cat > "$CEO_DIR/playbooks/authfail.md" << 'PB'
---
name: authfail
description: auth failure
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # single-call uses --output-format json; stub emits an auth-error envelope.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo '{"type":"result","is_error":true,"subtype":"error","api_error_status":401,"result":""}'
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
  rm -f "$HOME/ollama-invoked-model.txt"

  local rc=0
  bash "$CRON" authfail >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cron must exit non-zero on auth failure (no fallback)"

  local ollama_invoked
  ollama_invoked=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$ollama_invoked" "" "ollama must NOT be invoked on auth failure"

  local skip_log
  skip_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skip_log" "AUTH FAILURE" "cron-skips.log must record the auth failure"
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


test_playbook_scan_succeeds_without_yq() {
  cat > "$CEO_DIR/playbooks/no-yq-test.md" << 'PB'
---
name: no-yq-test
description: Verify scan works without yq
trigger: cron
schedule: "0 9 * * *"
runner: script
script: fake-no-yq.sh
tier: read
status: active
requires: [gh]
---
PB

  # Remove yq from stubbed PATH to simulate a machine without it installed.
  rm -f "$TEST_HOME/.bun/bin/yq"
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo playbook scan must succeed even when yq is not on PATH"
  assert_file_exists "$REGISTRY_FILE" "registry.json must be written without yq"
  local reg_name
  reg_name=$(jq -r '.playbooks[] | select(.name=="no-yq-test") | .name' "$REGISTRY_FILE" 2>/dev/null)
  assert_eq "$reg_name" "no-yq-test" "playbook must be registered without yq"

  # Restore yq stub for subsequent tests.
  cat > "$TEST_HOME/.bun/bin/yq" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/yq"
  rm -f "$CEO_DIR/playbooks/no-yq-test.md"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 3))
}

run_tests
