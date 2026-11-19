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
  assert_not_contains "$prompt" "Pending approvals:" "inputs:[] should suppress pending_count line"
  assert_not_contains "$prompt" "Briefing-specific training" "inputs:[] should suppress briefings_training block"
  assert_not_contains "$prompt" "PRs requesting review:" "inputs:[] should suppress pr_data lines"
  assert_not_contains "$prompt" "PR data (recently merged):" "inputs:[] should suppress the merged-PR line (#163)"
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
  - yesterday_merged
  - ledger_recent
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_not_contains "$out" "unknown key" "scan must NOT warn on valid morning-flow keys (yesterday_merged, ledger_recent)"
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
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"

  assert_contains "$out" "ADD   _test-repo-pb" "repo playbook must be picked up by scan"

  local file_field
  file_field=$(jq -r '.playbooks[] | select(.name=="_test-repo-pb") | .file' "$REGISTRY_FILE")
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
status: disabled
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"

  assert_contains "$out" "SHADOW" "scan must report shadowing"

  local desc status
  desc=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .description' "$REGISTRY_FILE")
  status=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .status' "$REGISTRY_FILE")
  assert_eq "$desc" "Vault override" "vault entry must win on collision"
  assert_eq "$status" "disabled" "vault status must override repo status"
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
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"

  assert_contains "$out" "DUP" "two repo files with same name must log DUP"
  if [[ "$out" == *"SHADOW"* ]]; then
    printf '  FAIL [%s] repo-internal dup must NOT log SHADOW (no vault override exists)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
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
  skip_log=$(_skips_log)
  assert_contains "$skip_log" "Falling back to ollama" "cron-skips.log must mention fallback"
  
  local ollama_invoked
  ollama_invoked=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_contains "$ollama_invoked" "glm4" "ollama must be invoked with default model during fallback"
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
  # 78 = cronbird's FATAL_EXIT_CODE (src/core/constants.ts). An auth failure cannot
  # resolve itself between attempts — a human runs /login — so the scheduler must
  # fail fast to the attempt cap rather than spend three dispatches per tick on a
  # host that will stay logged out. Still non-zero, so telemetry stays red, which
  # is what this test's name has always been about. Was a bare 1 before #298.
  assert_eq "$rc" "78" "auth failure must exit 78 (fatal, no retry), not a retryable 1"
  assert_eq "$(_fail_count authfail)" "1" \
    "a fatal exit must still record the failure — the fail count is what escalates"

  local ollama_invoked
  ollama_invoked=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$ollama_invoked" "" "ollama must NOT be invoked on auth failure"

  local skip_log
  skip_log=$(_skips_log)
  assert_contains "$skip_log" "AUTH FAILURE" "cron-skips.log must record the auth failure"
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

  mkdir -p "$CEO_VAULT/Profile"
  printf -- '---\nactive_domains_as_of: %s\n---\n## Active Domains\nCurrent Research\n' "$(date +%F)" > "$CEO_VAULT/Profile/goals.md"

  # Force gather phase to fail by emptying pending tasks
  : > "$CEO_DIR/approvals/pending.md"

  local rc=0
  bash "$CRON" morning-brief >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 on failed gather"
  
  local skip_log
  skip_log=$(_skips_log)
  assert_contains "$skip_log" "Gather phase empty" "cron-skips.log must mention gather phase empty"
  assert_eq "$(grep -c 'Gather phase' <<< "$skip_log")" "1" "the read-tier skip must log the gather status once, not twice"
  
  local report
  report=$(cat "$CEO_DIR/reports/$(date +%Y-%m-%d).md" 2>/dev/null || echo "")
  assert_contains "$report" "skipped: gather-empty" "report must show skipped status"
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
}

# #593's case: a profile-context reader crash degrades the gather while other data is
# present, so the status is partial, and a runner:skill playbook must still log it.
test_runner_skill_records_degraded_gather_status_in_skips_log() {
  cat > "$CEO_DIR/playbooks/skill-degraded-gather.md" << 'PB'
---
name: skill-degraded-gather
description: skill executes when gather is degraded
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
  printf '#!/bin/bash\nwhile [ "$#" -gt 0 ]; do [ "$1" = --out ] && out_dir="$2"; shift; done\necho ok > "$out_dir/report.md"\n' \
    > "$HOME/.claude/skills/test-skill/scripts/run-report.sh"
  chmod +x "$HOME/.claude/skills/test-skill/scripts/run-report.sh"

  # ceo-config.sh puts ~/.bun/bin first on PATH, so the stub goes where the other stubs live.
  local stub="$TEST_HOME/.bun/bin/python3"
  printf '#!/bin/sh\ncase "$1" in *ceo-profile-context.py) exit 1 ;; esac\nexec /usr/bin/python3 "$@"\n' > "$stub"
  chmod +x "$stub"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-degraded-gather >/dev/null 2>&1 || rc=$?
  rm -f "$stub"
  assert_eq "$rc" "0" "runner:skill must still run when gather is degraded (#593)"

  local skip_log
  skip_log=$(_skips_log)
  assert_contains "$skip_log" "WARN — Gather phase partial:" \
    "skips log must record a partial gather for runner:skill playbooks (#593)"
  assert_contains "$skip_log" "profile-context-reader-failed" "the recorded reason names the failed source"
  assert_eq "$(grep -c 'Gather phase' <<< "$skip_log")" "1" "a degraded gather is logged once per run"
}

# Script runners are excluded: they don't read gather output, and at a 5-10 minute
# cadence a WARN per run would push real errors out of cron-failure-digest's window.
test_runner_script_does_not_log_degraded_gather_status() {
  cat > "$CEO_DIR/playbooks/script-degraded-gather.md" << 'PB'
---
name: script-degraded-gather
description: script runner under a degraded gather
trigger: cron
status: active
tier: read
runner: script
script: no-such-script-for-593.sh
---
PB
  "$CEO_CLI" playbook scan >/dev/null
  : > "$CEO_DIR/approvals/pending.md"

  bash "$CRON" script-degraded-gather >/dev/null 2>&1 || true

  local skip_log
  skip_log=$(_skips_log)
  assert_contains "$skip_log" "Script not found" "the run must reach the script dispatch"
  assert_not_contains "$skip_log" "Gather phase" "a script runner must not log the gather status"
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
  skips_log=$(_skips_log)
  assert_contains "$skips_log" "Skill script not found" "skips log must record missing skill script"
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
  skips_log=$(_skips_log)
  assert_contains "$skips_log" "missing credential(s) MISSING_TEST_VAR" "skips log must record missing credential"
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
  skips_log=$(_skips_log)
  assert_contains "$skips_log" "Skill produced no output file" "skips log must record missing output file failure"
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
  skips_log=$(_skips_log)
  assert_contains "$skips_log" "Skill produced empty output" "skips log must record empty output failure"
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
}

test_morning_uses_current_canonical_domains_without_legacy_fallback() {
  mkdir -p "$CEO_VAULT/Profile"
  printf '## Active Domains\nLegacy Employer\n' > "$CEO_VAULT/Profile.md"
  printf -- '---\nactive_domains_as_of: %s\n---\n## Active Domains\nCurrent Research\n## Private\nDO NOT INJECT\n' "$(date +%F)" > "$CEO_VAULT/Profile/goals.md"
  cp "$SCRIPT_DIR/../docs/playbooks/morning.md" "$CEO_DIR/playbooks/morning.md"
  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_FORCE=1 bash "$CRON" morning >/dev/null 2>&1
  local prompt; prompt=$(cat "$HOME/claude-stdin.txt")
  assert_contains "$prompt" "Current Research" "current canonical domains reach the morning prompt"
  assert_not_contains "$prompt" "Legacy Employer" "legacy Profile.md domains never reach the morning prompt"
  assert_not_contains "$prompt" "DO NOT INJECT" "non-domain profile sections stay private"
}


# ---------------------------------------------------------------------------
# Ticket #660 — Claude auth failure visibility
# ---------------------------------------------------------------------------

# _auth_alert_fixture — point the harness at an isolated HOME and seed the
# vault directories the auth-alert code paths need. Returns nothing.
_auth_alert_fixture() {
  mkdir -p "$CEO_DIR/alerts" "$CEO_DIR/inbox" "$CEO_DIR/approvals"
  echo "- [ ] existing user task" > "$CEO_DIR/approvals/pending.md"
  # Default host for the test.
  export CEO_HOSTNAME="${CEO_HOSTNAME:-testhost}"
}

# Helper: seed a playbook named authfail that exercises the single-call path.
_seed_authfail_playbook() {
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
}

# Helper: claude stub that emits a 401 envelope and exits 1.
_stub_claude_authfail() {
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo '{"type":"result","is_error":true,"subtype":"error","api_error_status":401,"result":""}'
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}

test_auth_failure_writes_firing_alert_with_frontmatter() {
  _auth_alert_fixture
  _seed_authfail_playbook
  _stub_claude_authfail

  local rc=0
  bash "$CRON" authfail >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "78" "auth failure must still exit 78"

  local alert="$CEO_VAULT/CEO/alerts/auth-testhost.md"
  assert_file_exists "$alert" "auth alert file must be written"
  local status since host err
  status=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' status")
  since=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' since")
  host=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' host")
  err=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' error")
  assert_eq "$status" "firing" "status must be firing"
  assert_eq "$host" "testhost" "host must match the test host"
  assert_eq "$err" '"OAuth session expired and could not be refreshed"' "error must match requirement"
  [ -n "$since" ] && [ "$since" != "null" ]
  assert_eq "1" "1" "since must be non-empty"
}

test_auth_failure_preserves_since_on_reaffirm() {
  _auth_alert_fixture
  _seed_authfail_playbook
  _stub_claude_authfail
  local alert="$CEO_VAULT/CEO/alerts/auth-testhost.md"
  local first_since
  bash "$CRON" authfail >/dev/null 2>&1 || true
  first_since=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' since")
  [ -n "$first_since" ] || { echo "first since missing"; return 1; }

  # Simulate 24h passing, then re-fire.
  sleep 2  # ensure last_check differs
  bash "$CRON" authfail >/dev/null 2>&1 || true
  local second_since
  second_since=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' since")
  assert_eq "$second_since" "$first_since" "since must be preserved across reaffirmations"
}

test_auth_failure_appends_shadow_inbox_task_once() {
  _auth_alert_fixture
  _seed_authfail_playbook
  _stub_claude_authfail
  local inbox="$CEO_VAULT/CEO/inbox/testhost.md"
  bash "$CRON" authfail >/dev/null 2>&1 || true
  bash "$CRON" authfail >/dev/null 2>&1 || true
  local count
  count=$(grep -c '^\- \[ \] Fix Claude authentication on testhost' "$inbox" 2>/dev/null || true)
  assert_eq "$count" "1" "shadow inbox task must be appended exactly once"
  # CEO/inbox.md must NOT be written (not the synced per-host inbox).
  if [ -f "$CEO_VAULT/CEO/inbox.md" ]; then
    assert_not_contains "$(cat "$CEO_VAULT/CEO/inbox.md")" "Fix Claude authentication on testhost" "CEO/inbox.md must not carry the auth task"
  fi
}

test_auth_clear_writes_status_clear_and_marks_inbox_done() {
  _auth_alert_fixture
  local alert="$CEO_VAULT/CEO/alerts/auth-testhost.md"
  local inbox="$CEO_VAULT/CEO/inbox/testhost.md"
  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_set testhost firing"
  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_inbox_task testhost firing"
  [ -f "$alert" ] || { echo "alert not written by direct set"; return 1; }
  [ -f "$inbox" ] || { echo "inbox not written by direct set"; return 1; }

  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_set testhost clear"
  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_inbox_task testhost clear"

  local status
  status=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' status")
  assert_eq "$status" "clear" "status must be clear after clear"
  local done_lines
  done_lines=$(grep -c '^\- \[done\] Fix Claude authentication on testhost' "$inbox" 2>/dev/null || true)
  assert_eq "$done_lines" "1" "inbox task must be rewritten to [done]"
  local unchecked
  unchecked=$(grep -c '^\- \[ \] Fix Claude authentication on testhost' "$inbox" 2>/dev/null || true)
  assert_eq "$unchecked" "0" "no unchecked auth task must remain"
}

test_auth_failure_does_not_append_approvals_block() {
  _auth_alert_fixture
  _seed_authfail_playbook
  _stub_claude_authfail
  local pending="$CEO_VAULT/CEO/approvals/pending.md"
  local before
  before=$(wc -l < "$pending" 2>/dev/null || echo 0)

  # Force three consecutive failures to cross the 3-strike threshold.
  bash "$CRON" authfail >/dev/null 2>&1 || true
  bash "$CRON" authfail >/dev/null 2>&1 || true
  bash "$CRON" authfail >/dev/null 2>&1 || true

  local after
  after=$(wc -l < "$pending" 2>/dev/null || echo 0)
  local delta=$(( after - before ))
  assert_eq "$delta" "0" "auth failure must NOT append a 3-strike approvals block"
  assert_not_contains "$(cat "$pending")" "CEO cron failing repeatedly" "pending.md must not carry the generic 3-strike line"
}

test_auth_clear_via_claude_success_auto_clears_alert() {
  _auth_alert_fixture
  local alert="$CEO_VAULT/CEO/alerts/auth-testhost.md"
  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_set testhost firing"
  bash -c "source '$SCRIPT_DIR/ceo-config.sh'; CEO_VAULT='$CEO_VAULT' ceo_auth_alert_inbox_task testhost firing"
  [ "$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' status")" = "firing" ] || { echo "precondition: alert not firing"; return 1; }

  # Stub claude to succeed (exit 0, valid JSON envelope).
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo '{"type":"result","is_error":false,"result":"ok","total_cost_usd":0.01}'
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  _seed_authfail_playbook
  bash "$CRON" authfail >/dev/null 2>&1 || true

  local status
  status=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' status")
  assert_eq "$status" "clear" "claude-backed success must auto-clear the alert"
}

# ---------------------------------------------------------------------------
# WSL credential auto-sync (ticket #660)
# ---------------------------------------------------------------------------

test_wsl_creds_heal_copies_newer_win_creds_and_retries_once() {
  _auth_alert_fixture
  _seed_authfail_playbook

  # Simulate WSL via CEO_FORCE_WSL=1 and pin both paths.
  local win_creds="$TEST_HOME/win-creds/.credentials.json"
  local linux_creds="$TEST_HOME/linux-creds/.credentials.json"
  mkdir -p "$(dirname "$win_creds")" "$(dirname "$linux_creds")"
  printf '{"token":"fresh"}' > "$win_creds"
  printf '{"token":"stale"}' > "$linux_creds"
  # Make the Windows side newer.
  touch -d "2026-01-01T00:00:00Z" "$linux_creds" 2>/dev/null || touch -t 2601010000 "$linux_creds" 2>/dev/null || true
  touch "$win_creds"

  # First claude call fails auth; second (after heal) succeeds.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
if [ -f "$HOME/claude-call-count" ]; then
  n=$(cat "$HOME/claude-call-count")
else
  n=0
fi
n=$((n+1))
echo "$n" > "$HOME/claude-call-count"
if [ "$n" -eq 1 ]; then
  echo '{"type":"result","is_error":true,"subtype":"error","api_error_status":401,"result":""}'
  exit 1
fi
echo '{"type":"result","is_error":false,"result":"ok after heal","total_cost_usd":0.01}'
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
  rm -f "$HOME/claude-call-count"

  local rc=0
  CEO_FORCE_WSL=1 CEO_WINDOWS_CREDS_PATH="$win_creds" CEO_LINUX_CREDS_PATH="$linux_creds" \
    bash "$CRON" authfail >/dev/null 2>&1 || rc=$?

  local calls
  calls=$(cat "$HOME/claude-call-count" 2>/dev/null || echo 0)
  assert_eq "$calls" "2" "claude must be invoked exactly twice (initial + heal retry)"
  # The linux credentials must now match the windows ones.
  assert_contains "$(cat "$linux_creds")" "fresh" "linux credentials must be replaced by the windows ones"
  # The heal must have produced a 600-permission file.
  local perms
  perms=$(stat -f %Lp "$linux_creds" 2>/dev/null || stat -c %a "$linux_creds" 2>/dev/null)
  assert_eq "$perms" "600" "healed credentials must be chmod 600"
  # The alert should NOT have been raised because the retry succeeded.
  local alert="$CEO_VAULT/CEO/alerts/auth-testhost.md"
  local status=""
  if [ -f "$alert" ]; then
    status=$(bash -c "source '$SCRIPT_DIR/ceo-config.sh'; ceo_read_alert_field '$alert' status")
  fi
  assert_eq "$status" "" "alert must not be raised when the WSL heal retry succeeds"
}

test_wsl_creds_heal_noop_when_win_creds_invalid_json() {
  _auth_alert_fixture
  _seed_authfail_playbook
  local win_creds="$TEST_HOME/win-bad/.credentials.json"
  local linux_creds="$TEST_HOME/linux-bad/.credentials.json"
  mkdir -p "$(dirname "$win_creds")" "$(dirname "$linux_creds")"
  printf 'NOT JSON' > "$win_creds"
  printf '{"token":"stale"}' > "$linux_creds"

  _stub_claude_authfail
  local before; before=$(cat "$linux_creds")

  local rc=0
  CEO_FORCE_WSL=1 CEO_WINDOWS_CREDS_PATH="$win_creds" CEO_LINUX_CREDS_PATH="$linux_creds"     bash "$CRON" authfail >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "78" "invalid Windows credentials must still exit 78"
  assert_eq "$(cat "$linux_creds")" "$before" "linux credentials must be untouched when Windows side is invalid JSON"
}

test_wsl_creds_heal_noop_when_not_wsl() {
  _auth_alert_fixture
  _seed_authfail_playbook
  local win_creds="$TEST_HOME/win-nwsl/.credentials.json"
  local linux_creds="$TEST_HOME/linux-nwsl/.credentials.json"
  mkdir -p "$(dirname "$win_creds")" "$(dirname "$linux_creds")"
  printf '{"token":"fresh"}' > "$win_creds"
  printf '{"token":"stale"}' > "$linux_creds"
  touch -t 2601010000 "$linux_creds" 2>/dev/null || touch -d "2026-01-01T00:00:00Z" "$linux_creds" 2>/dev/null || true
  touch "$win_creds"

  _stub_claude_authfail
  local rc=0
  # CEO_FORCE_WSL unset; WSL_DISTRO_NAME unset; /proc/version not WSL on macOS.
  CEO_WINDOWS_CREDS_PATH="$win_creds" CEO_LINUX_CREDS_PATH="$linux_creds"     bash "$CRON" authfail >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "78" "non-WSL host must still exit 78"
  assert_eq "$(cat "$linux_creds")" '{"token":"stale"}' "linux credentials must be untouched outside WSL"
}

run_tests
