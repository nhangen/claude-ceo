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
  _fixture_script "$SCRIPT_DIR/fake-intake.sh"
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
  _fixture_script "$SCRIPT_DIR/shape-noop.sh"
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


test_runner_skill_abort_is_recorded_and_releases_the_lock() {
  # runner:skill used to install its own `trap 'rm -rf "$TMP_DIR"' EXIT`, which
  # replaced the bookkeeping/lock-release handler wholesale (bash keeps one EXIT
  # trap). So for every skill playbook — weekly-synthesis, workload-report,
  # story-points — an abort in the vault-write tail recorded nothing and leaked
  # the lock dir: the exact #293 shape, inside the branch meant to be covered.
  #
  # Reproduce it at the real abort site: make `mkdir -p "$(dirname "$FINAL_OUT")"`
  # fail by planting a regular file where the output directory has to go.
  cat > "$CEO_DIR/playbooks/skill-abort.md" << 'PB'
---
name: skill-abort
description: skill runner whose vault write aborts
trigger: cron
status: active
tier: read
runner: skill
skill: skill-abort
out_pattern: CEO/reports/blocker/${TODAY}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/skill-abort/scripts"
  cat > "$HOME/.claude/skills/skill-abort/scripts/run-report.sh" << 'SH'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in --out) out_dir="$2"; shift ;; esac
  shift
done
echo "skill output" > "$out_dir/report.md"
SH
  chmod +x "$HOME/.claude/skills/skill-abort/scripts/run-report.sh"

  # A regular file where CEO/reports/blocker/ must be a directory.
  mkdir -p "$CEO_DIR/reports"
  printf 'not a directory\n' > "$CEO_DIR/reports/blocker"

  local rc=0
  CEO_TEST_FORCE_MKDIR_LOCK=1 PATH=/usr/bin:/bin bash "$CRON" skill-abort >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL [%s] a skill runner whose vault write fails must not exit 0\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))

  assert_eq "$(cat "$(_ceo_state)/.fail-count-skill-abort" 2>/dev/null || echo 0)" "1" \
    "a skill-runner abort must be recorded, not swallowed by its cleanup trap"
  local skips
  skips=$(_skips_log)
  assert_contains "$skips" "without recording a result" \
    "the abort must leave an ERROR line naming it as un-bookkept"
  if [ -d "${LOCK_FILE:-$CEO_DIR/log/ceo-cron.lock}.d" ]; then
    printf '  FAIL [%s] the mkdir lock leaked — the cleanup trap replaced the release handler\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  _fixture_script "$SCRIPT_DIR/playbook-id-script.sh"
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
  _fixture_script "$SCRIPT_DIR/model-script.sh" "$SCRIPT_DIR/pureshell-script.sh"
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
  _fixture_script "$SCRIPT_DIR/v-test.sh"
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
  _fixture_script "$SCRIPT_DIR/stderr-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" stderr-intake >/dev/null 2>&1 || true

  local stderr_log
  stderr_log=$(_stderr_log)
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
  _fixture_script "$SCRIPT_DIR/fail-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" fail-intake >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
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
  _fixture_script "$SCRIPT_DIR/ok-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  echo 2 > "$(_ceo_state)/.fail-count-ok-intake"
  CEO_VERBOSE=1 bash "$CRON" ok-intake >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
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
  _fixture_script "$SCRIPT_DIR/log-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" log-intake >/dev/null 2>&1 || true

  local runs_log
  runs_log=$(_runs_log)
  assert_contains "$runs_log" "log-intake completed" "cron-runs.log must record successful script run"

  rm -f "$SCRIPT_DIR/log-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


# --- #397: the completion log is per-host -------------------------------------
#
# cron-runs.log lives in the Syncthing-synced vault and every host appended to
# it, so Syncthing forked the file instead of merging: ten conflict copies by
# 2026-09-09. Whichever copy loses takes its host's completion lines with it,
# and `ceo doctor`'s artifact cross-check reads those lines to decide whether a
# playbook that claimed success produced anything.

_run_log_intake_as_host() {   # $1 = CEO_HOSTNAME to run under ("" = leave unset)
  cat > "$CEO_DIR/playbooks/host-intake.md" << 'PB'
---
name: host-intake
description: Test playbook for the per-host completion log
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: host-intake.sh
---
PB
  cat > "$SCRIPT_DIR/host-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  _fixture_script "$SCRIPT_DIR/host-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  if [ -n "$1" ]; then
    CEO_HOSTNAME="$1" bash "$CRON" host-intake >/dev/null 2>&1 || true
  else
    # `env -u`, not a bare call: the harness never unsets CEO_HOSTNAME, so an
    # ambient one (a real operator variable — ~/.ceo/config, `ceo setup`) would
    # resolve the host that this arm needs to be unresolvable, and red a correct
    # tree on whoever has it exported.
    env -u CEO_HOSTNAME bash "$CRON" host-intake >/dev/null 2>&1 || true
  fi
  rm -f "$SCRIPT_DIR/host-intake.sh"
}

test_an_unresolvable_host_says_so_in_cron_skips() {
  # The fallback to `unknown` is deliberate — aborting a playbook run over a log
  # filename is disproportionate. But mute is the wrong kind of tolerant: the
  # completions go somewhere `ceo doctor`'s cross-check does not read, and
  # nothing anywhere says the host could not be resolved. `_record_failure`
  # already settled how this is handled (ceo-cron.sh:316-335); match it.
  cat > "$TEST_HOME/.bun/bin/hostname" << 'SH'
#!/bin/bash
echo ""
SH
  chmod +x "$TEST_HOME/.bun/bin/hostname"
  _run_log_intake_as_host ''
  rm -f "$TEST_HOME/.bun/bin/hostname"

  local skips
  skips=$(_skips_log)
  assert_contains "$skips" "WARN" \
    "an unresolvable host must record a WARN, not fall back in silence"
  assert_contains "$skips" "CEO_HOSTNAME" \
    "and the WARN must name the setting that fixes it"
  assert_contains "$skips" "cron-runs-unknown.log" \
    "and name the file the completions are going to instead"
}

test_an_unwritable_completion_log_is_not_swallowed() {
  # _record_success zeroes the fail counter and stamps .last-run *before* the
  # append. A failing append then aborts it under set -e with the streak already
  # reset and the cooldown already stamped, and _on_exit does not record a
  # failure because _bookkeeping_done is set. Net: the scheduler sees a failure
  # it cannot explain, and doctor's cross-check silently skips the playbook.
  #
  # This is pre-existing for the old shared name, but #397 raises it: the
  # per-host file is a *new* name, so every host's first upgraded run must
  # create it rather than append to one that already exists — and a $LOG_DIR
  # left root-owned by an earlier sudo run permits the old write and refuses the
  # new one. That is the case the cron-stdout/stderr probe was written for.
  cat > "$CEO_DIR/playbooks/ro-intake.md" << 'PB'
---
name: ro-intake
description: Test playbook for an unwritable completion log
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: ro-intake.sh
---
PB
  cat > "$SCRIPT_DIR/ro-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  _fixture_script "$SCRIPT_DIR/ro-intake.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # A directory where the log file should be: the append cannot succeed, and the
  # failure is the kernel's rather than a permission bit teardown would have to
  # restore (teardown does not run on an abort). The name comes from the
  # production helper, not from a second copy of its spelling.
  local blocked_host
  blocked_host=$(_host_slug)
  mkdir -p "$CEO_DIR/log/cron-runs-$blocked_host.log"

  bash "$CRON" ro-intake >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/ro-intake.sh"

  local skips
  skips=$(_skips_log)
  assert_contains "$skips" "cannot record the completion" \
    "a completion that could not be written must say so, not vanish"
  assert_contains "$skips" "ro-intake" \
    "and name the playbook whose record was lost"
}

# --- #394: per-trigger cron state is host-local ------------------------------

# A script-runner playbook whose script exits non-zero, so _record_failure runs
# and the failure counter is written. Named per arm so the counters do not
# collide (_fail_count reports AMBIGUOUS on more than one).
_write_failing_playbook() {
  local name="$1"
  cat > "$CEO_DIR/playbooks/$name.md" << PB
---
name: $name
description: Test playbook that fails, to exercise the fail counter
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: $name.sh
---
PB
  cat > "$SCRIPT_DIR/$name.sh" << 'SH'
#!/bin/bash
exit 1
SH
  _fixture_script "$SCRIPT_DIR/$name.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
}

test_an_uncreatable_state_dir_refuses_to_dispatch() {
  # The state dir used to be $LOG_DIR, which this script creates with a checked
  # mkdir. Moving it to $HOME/.ceo/state put it behind a mkdir whose failure was
  # discarded — and the first consumer is a bare redirect in _record_success,
  # which under set -e aborts *after* _bookkeeping_done is set, so the EXIT trap
  # records nothing either. The run then reads as an unexplained non-zero with the
  # failure streak silently reset. Realistic trigger: $HOME/.ceo root-owned by an
  # earlier sudo run, the same cause the script-runner log probe anticipates.
  _write_failing_playbook nodir-check

  # A file where the directory must be: the failure is the kernel's, not a
  # permission bit teardown would have to restore (teardown does not run on an
  # abort).
  rm -rf "$CEO_STATE_DIR"
  : > "$CEO_STATE_DIR"

  local rc=0
  bash "$CRON" nodir-check >/dev/null 2>&1 || rc=$?
  rm -f "$SCRIPT_DIR/nodir-check.sh" "$CEO_STATE_DIR"

  assert_eq "$rc" "1" "an uncreatable state dir must stop the run, not half-apply bookkeeping"
  local skips
  skips=$(_skips_log)
  assert_contains "$skips" "NOT dispatched" \
    "and say so where cron failures are read, not on the stderr the scheduler ignores"
  assert_contains "$skips" "nodir-check" "and name the playbook"
}

test_production_honors_CEO_STATE_DIR_not_just_HOME() {
  # CEO_STATE_DIR exists because seven playbook scripts call ceo_pin_home_or_warn,
  # which re-exports HOME from passwd — so a $HOME-derived path escapes a fixture
  # and writes the developer's real ~/.ceo/state. That happened once during #394.
  #
  # The harness sets HOME and CEO_STATE_DIR to the same fixture, so every other arm
  # passes whether or not the override is honored. This one points it somewhere HOME
  # is not, which is the only way to tell the two apart — and the only suite that
  # noticed the override being removed did so *by* committing the violation.
  local elsewhere="$TEST_HOME/elsewhere-state"
  mkdir -p "$elsewhere"
  _write_failing_playbook override-check
  CEO_STATE_DIR="$elsewhere" bash "$CRON" override-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/override-check.sh"

  assert_file_exists "$elsewhere/.fail-count-override-check" \
    "production must resolve the state dir through CEO_STATE_DIR, not \$HOME"
  if [ -e "$HOME/.ceo/state/.fail-count-override-check" ]; then
    fail_test "the override was ignored and \$HOME won"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_production_honors_CEO_REGISTRY_FILE_not_just_HOME() {
  local elsewhere="$TEST_HOME/elsewhere-reg.json"
  local path
  path=$(CEO_REGISTRY_FILE="$elsewhere" bash -c "source '$SCRIPT_DIR/ceo-config.sh'; _ceo_registry_path")
  assert_eq "$path" "$elsewhere" "production helper must resolve registry through CEO_REGISTRY_FILE, not \$HOME"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_the_two_last_scan_writers_agree_on_the_path() {
  # ceo-cron.sh stamps .last-scan on a successful morning-scan; ceo-scan.sh reads
  # and creates it. The comment on ceo-scan.sh calls that agreement load-bearing
  # and nothing pinned it — renaming one side left both suites green, because a
  # reader that finds nothing just takes the first-run branch and behaves the same.
  #
  # Both sides are asked for their path here rather than either being spelled out.
  local cron_side scan_side
  cron_side=$(bash -c ". '$SCRIPT_DIR/ceo-config.sh' >/dev/null 2>&1; _ceo_state_migrate .last-scan")
  scan_side=$(bash -c "
    set -euo pipefail
    CEO_VAULT='$CEO_VAULT' CEO_STATE_DIR='$CEO_STATE_DIR'
    . '$SCRIPT_DIR/ceo-config.sh' >/dev/null 2>&1
    grep -n 'last-scan' '$SCRIPT_DIR/ceo-scan.sh' | head -1")
  assert_contains "$scan_side" "_ceo_state_migrate" \
    "ceo-scan.sh must resolve .last-scan through the same helper the dispatcher uses"
  assert_contains "$cron_side" "/.last-scan" "and that helper must yield the marker path"
}

test_cron_state_is_written_outside_the_synced_vault() {
  # The fail counter, the cooldown stamp and the preview scratch used to live
  # under CEO/log/ and stay host-local only because each host had copied
  # syncthing/shared.stignore into its vault root. Nothing verifies that copy —
  # on 2026-09-09 both swarm hosts were found running an August version missing a
  # rule for a file added since. Two hosts sharing a failure counter do not fail;
  # they agree on a wrong number (#299).
  _write_failing_playbook state-check
  bash "$CRON" state-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/state-check.sh"

  assert_file_exists "$(_ceo_state)/.fail-count-state-check" \
    "the failure counter must land in the host-local state dir"
  if [ -e "$CEO_DIR/log/.fail-count-state-check" ]; then
    fail_test "the failure counter was written into the synced vault"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_legacy_cron_state_is_migrated_on_first_run() {
  # An upgrading host has the old files sitting in its vault. Ignoring them would
  # reset a failure streak (a playbook two strikes into escalation starts over)
  # and drop a cooldown stamp (the next run fires early). Both are silent, so the
  # migration happens rather than the state being abandoned.
  _write_failing_playbook migr-check
  printf '2\n' > "$CEO_DIR/log/.fail-count-migr-check"

  bash "$CRON" migr-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/migr-check.sh"

  assert_eq "$(cat "$(_ceo_state)/.fail-count-migr-check" 2>/dev/null)" "3" \
    "the legacy counter must carry across and increment, not restart at 1"
  if [ -e "$CEO_DIR/log/.fail-count-migr-check" ]; then
    fail_test "the legacy file must be moved, not copied — a leftover resyncs"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_migration_does_not_clobber_existing_host_local_state() {
  # A stale legacy file must never overwrite state this host already owns. Once
  # migrated, the vault copy is a fossil — on a host that ran the old code and
  # synced one in, it could be another machine's counter entirely.
  _write_failing_playbook clob-check
  printf '9\n' > "$CEO_DIR/log/.fail-count-clob-check"
  printf '1\n' > "$(_ceo_state)/.fail-count-clob-check"

  bash "$CRON" clob-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/clob-check.sh"

  assert_eq "$(cat "$(_ceo_state)/.fail-count-clob-check" 2>/dev/null)" "2" \
    "the host-local counter wins and increments from its own value"
}

test_an_unwritable_skips_journal_refuses_to_dispatch() {
  # The skips journal is where every failure reason goes, including #398's
  # "cannot record the completion". Every append to it is unguarded, so an
  # unwritable one loses the reason on every channel while the run still
  # increments the streak and stamps .last-run — fully bookkept and silent.
  #
  # #399 makes that the upgrade case rather than a rarity: the filename is new,
  # so the first run on each host has to CREATE it. A CEO/log/ that is read-only
  # or root-owned from an earlier sudo run succeeds on the long-existing
  # cron-skips.log and fails on cron-skips-<host>.log.
  #
  # The refusal cannot go through _record_failure — that writes here — so it goes
  # to the approvals queue, the other channel a human reads.
  _write_failing_playbook unwritable-skips
  local skips; skips=$(_skips_log_path)
  rm -f "$skips"
  mkdir -p "$skips"   # a directory where the file must be: the kernel refuses,
                      # and teardown has no permission bit to restore

  local rc=0
  bash "$CRON" unwritable-skips >/dev/null 2>&1 || rc=$?
  rm -f "$SCRIPT_DIR/unwritable-skips.sh"
  rmdir "$skips" 2>/dev/null || true

  assert_eq "$rc" "1" "an unwritable failure journal must stop the run, not fail silently"
  local pending; pending=$(cat "$CEO_DIR/approvals/pending.md" 2>/dev/null || echo "")
  assert_contains "$pending" "cannot write its failure journal" \
    "and say so on the one channel that is not the broken file"
  assert_contains "$pending" "unwritable-skips" "naming the playbook that was not dispatched"
}

test_the_host_slug_is_safe_as_a_filename() {
  # _ceo_host_slug names four file families now and has no direct arm. Its
  # flattening is what stops a CEO_HOSTNAME containing a path separator from
  # sending a write outside the log directory, or a leading dot from hiding the
  # file from every glob that reads the family.
  local slug
  slug=$(CEO_HOSTNAME='a/b/c' _host_slug)
  case "$slug" in
    */*) fail_test "a path separator survived the flattening: $slug" ;;
    *)   ASSERTION_COUNT=$((ASSERTION_COUNT + 1)) ;;
  esac

  slug=$(CEO_HOSTNAME='.hidden' _host_slug)
  case "$slug" in
    .*) fail_test "a leading dot survived: $slug would hide the file from the family glob" ;;
    *)  ASSERTION_COUNT=$((ASSERTION_COUNT + 1)) ;;
  esac

  # Never empty: cron-skips-.log would collide across every host that produced it.
  slug=$(CEO_HOSTNAME='///' _host_slug)
  if [ -z "$slug" ]; then
    fail_test "an all-separator host name flattened to empty"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_no_source_line_writes_a_shared_journal_name() {
  # The runtime tripwire in teardown only sees paths the suite actually
  # dispatches through. This reads the source instead, so a bare-name write on a
  # branch no arm exercises is caught too — reverting one dry-run line was green
  # across 87 tests before this existed.
  #
  # Comments and the deliberate cron-skips-unknown.log literal are excluded: the
  # first is prose, the second is the host-slug failure path, which cannot use
  # $SKIPS_LOG because SKIPS_LOG is derived from the slug it is failing over.
  local offenders
  offenders=$(sed 's/#.*//' "$SCRIPT_DIR/ceo-cron.sh" \
    | grep -nE '(LOG_DIR|CEO_DIR/log)"?/cron-(skips|stdout|stderr|raw)\.log' || true)
  if [ -n "$offenders" ]; then
    fail_test "ceo-cron.sh writes a shared journal name #399 keyed by host" "$offenders"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_the_dispatcher_journals_are_keyed_by_host() {
  # cron-skips/stdout/stderr had one copy each that every host appended to, so
  # Syncthing forked them — three .sync-conflict copies were on disk when #399 was
  # filed. cron-skips is the sharpest case: #398 routes the one line saying a
  # completion record was lost into it, so a fork there can drop exactly that.
  #
  # These stay in the synced vault on purpose, unlike the state moved in #394 —
  # they are journals, the digest playbook reaches them by a vault-relative path,
  # and one writer per file means syncing them costs no conflicts.
  _write_failing_playbook journal-check
  bash "$CRON" journal-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/journal-check.sh"

  assert_file_exists "$(_skips_log_path)" "the skips journal must be keyed by host"
  assert_contains "$(cat "$(_skips_log_path)")" "journal-check" \
    "and carry this run's line"

  local shared
  for shared in cron-skips cron-stdout cron-stderr; do
    if [ -e "$CEO_DIR/log/$shared.log" ]; then
      fail_test "the shared $shared.log must not be written any more — that is the file that forks"
    else
      ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
    fi
  done
}

test_operator_facing_strings_name_a_journal_that_exists() {
  # The three-strike alert and the unwritable-journal failure reason are the two
  # places a woken operator is told which file to open. Both still named the bare
  # cron-skips.log / cron-{stdout,stderr}.log after #399 keyed them, because the
  # bulk edit converted writes and no test pinned the prose. An alert that names a
  # path present on no host reads as "the journal was never written" — the
  # diagnostic channel looks broken at exactly the moment it matters.
  #
  # Asserted against the live log directory rather than a literal, so the next
  # rename cannot detach them again.
  _write_failing_playbook strings-check
  local _
  for _ in 1 2 3; do
    rm -f "$CEO_STATE_DIR/.last-run-strings-check"
    bash "$CRON" strings-check >/dev/null 2>&1 || true
  done
  rm -f "$SCRIPT_DIR/strings-check.sh"

  local pending named
  pending=$(cat "$CEO_DIR/approvals/pending.md" 2>/dev/null || echo "")
  assert_contains "$pending" "action needed" "three failures must raise the alert"

  named=$(printf '%s\n' "$pending" | grep -oE 'cron-[a-z]+[a-zA-Z0-9._-]*\.log' | sort -u)
  assert_contains "$named" "cron-" "the alert must name a journal to open"

  # A retired bare name is the regression: those exist on no host by
  # construction, unlike cron-raw.log, which a script-runner run simply never
  # writes.
  local f retired
  for f in $named; do
    for retired in cron-skips.log cron-stdout.log cron-stderr.log cron-runs.log cron-raw.log; do
      if [ "$f" = "$retired" ]; then
        fail_test "the alert names $f — a name #397/#399 retired, present on no host"
      fi
    done
  done
  assert_contains "$named" "$(basename "$(_skips_log_path)")" \
    "and must name this host's skips journal, which is where the reason went"
}

test_two_hosts_write_separate_journals() {
  _write_failing_playbook j2-check
  CEO_HOSTNAME=hostJ1 bash "$CRON" j2-check >/dev/null 2>&1 || true
  rm -f "$CEO_STATE_DIR/.last-run-j2-check"
  CEO_HOSTNAME=hostJ2 bash "$CRON" j2-check >/dev/null 2>&1 || true
  rm -f "$SCRIPT_DIR/j2-check.sh"

  assert_file_exists "$CEO_DIR/log/cron-skips-hostJ1.log" "host J1 writes its own journal"
  assert_file_exists "$CEO_DIR/log/cron-skips-hostJ2.log" "host J2 writes its own journal"

  # Existence alone is satisfied by two empty files beside one forked shared one.
  # Separation is the property #399 actually buys, so assert each host's lines are
  # in its own file and not in the other's.
  local j1 j2
  j1=$(cat "$CEO_DIR/log/cron-skips-hostJ1.log" 2>/dev/null || echo "")
  j2=$(cat "$CEO_DIR/log/cron-skips-hostJ2.log" 2>/dev/null || echo "")
  assert_contains "$j1" "j2-check" "host J1's journal carries its own run"
  assert_contains "$j2" "j2-check" "host J2's journal carries its own run"
  assert_eq "$(printf '%s\n' "$j1" | grep -c 'j2-check' || true)" "1" \
    "and exactly one run's worth — not both hosts' lines in one file"
}

test_the_completion_log_is_keyed_by_host() {
  _run_log_intake_as_host hostA

  assert_file_exists "$CEO_DIR/log/cron-runs-hostA.log" \
    "the completion must land in a host-keyed log"
  assert_contains "$(cat "$CEO_DIR/log/cron-runs-hostA.log")" "host-intake completed" \
    "and that log must carry the completion line"

  # The shared file is the one Syncthing forks. Writing it alongside the
  # per-host log would keep the conflict and make the fix invisible.
  if [ -f "$CEO_DIR/log/cron-runs.log" ]; then
    fail_test "the shared cron-runs.log must not be written any more"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_two_hosts_write_two_logs() {
  _run_log_intake_as_host hostA
  rm -f "$(_ceo_state)/.last-run-host-intake"   # else the cooldown skips the second run
  _run_log_intake_as_host hostB

  assert_contains "$(cat "$CEO_DIR/log/cron-runs-hostA.log" 2>/dev/null)" "host-intake completed" \
    "host A's completion stays in host A's log"
  assert_contains "$(cat "$CEO_DIR/log/cron-runs-hostB.log" 2>/dev/null)" "host-intake completed" \
    "host B's completion stays in host B's log"
}

test_a_host_name_that_is_a_path_is_flattened_into_one_log_file() {
  # CEO_HOSTNAME is free text and reaches this as a filename component.
  #
  # This arm used to assert the exact flattened name, which pinned the `tr`
  # replacement character rather than the property: swapping '-' for '_' is
  # equally safe and turned it red. It also checked for a file at
  # $CEO_VAULT/../escaped.log, which input can never produce — RUNS_LOG glues
  # `cron-runs-` in front of the id, so traversal would need an existing
  # `cron-runs-..` *directory* and the append just ENOENTs. Neither half tested
  # what actually breaks.
  #
  # What actually breaks is the record: an unflattened id sends the append at a
  # path that does not resolve, the write fails, and the completion is gone. So
  # assert the properties — one log, named `cron-runs-*`, inside the log dir,
  # carrying the line — and let the spelling be whatever it is.
  _run_log_intake_as_host '../../escaped'

  local logs found
  logs=$(find "$CEO_DIR/log" -maxdepth 1 -name 'cron-runs*' 2>/dev/null)
  found=$(printf '%s' "$logs" | grep -c . || true)
  assert_eq "$found" "1" "a path-shaped host name must produce exactly one log file"
  assert_contains "$(find "$CEO_DIR/log" -maxdepth 1 -name 'cron-runs*' -exec cat {} + 2>/dev/null)" \
    "host-intake completed" \
    "and the completion must actually be in it — a failed append loses the record"

  # The file has to live in the log directory, not somewhere a path component
  # took it. `find` above is already scoped there, so this pins the other half:
  # nothing landed outside it.
  if find "$CEO_VAULT" -name '*escaped*' -not -path "$CEO_DIR/log/*" 2>/dev/null | grep -q .; then
    fail_test "a host name component escaped out of the log directory as a path"
  else
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  fi
}

test_an_unresolvable_host_lands_in_the_unknown_log() {
  # No CEO_HOSTNAME and a `hostname` that answers with nothing. The record must
  # still be written somewhere doctor's glob reaches — losing the completion
  # line is worse than sharing a file with another unresolvable host.
  cat > "$TEST_HOME/.bun/bin/hostname" << 'SH'
#!/bin/bash
echo ""
SH
  chmod +x "$TEST_HOME/.bun/bin/hostname"
  _run_log_intake_as_host ''
  rm -f "$TEST_HOME/.bun/bin/hostname"

  assert_file_exists "$CEO_DIR/log/cron-runs-unknown.log" \
    "an unresolvable host must still record its completion"
  assert_contains "$(cat "$CEO_DIR/log/cron-runs-unknown.log" 2>/dev/null)" "host-intake completed" \
    "and the line must be the completion, not an empty file"
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
  _fixture_script "$SCRIPT_DIR/disk-monitor-test.sh"
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


# A playbook whose preflight_<name>() does not exist has lost its work gate. That
# used to warn through _v — gated on CEO_VERBOSE=1, so a scheduled run said nothing
# — and dispatch anyway, unconditionally, forever. CEO_VERBOSE is deliberately left
# unset in these three tests: a run with it set was never the problem.
_write_unknown_preflight_playbook() {
  cat > "$CEO_DIR/playbooks/ghost-gate.md" << 'PB'
---
name: ghost-gate
description: Declares a preflight nobody defines
trigger: cron
schedule: "0 9 * * *"
preflight: no_such_gate
tier: read
status: active
runner: claude
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
}

test_unknown_preflight_does_not_dispatch() {
  _write_unknown_preflight_playbook
  bash "$CRON" ghost-gate >/dev/null 2>&1
  local invoked=no
  [ -f "$HOME/claude-invoked.txt" ] && invoked=yes
  assert_eq "$invoked" "no" \
    "a playbook whose preflight function is missing must not reach the model"
}

test_unknown_preflight_exits_fatal() {
  _write_unknown_preflight_playbook
  local rc=0
  bash "$CRON" ghost-gate >/dev/null 2>&1 || rc=$?
  # 78 rather than any non-zero: _record_failure stamps LAST_RUN_FILE, so a retry
  # hits the cooldown gate and exits 0, which cronbird reads as success. Same
  # reasoning as the auth path (ceo-cron.sh :486).
  assert_eq "$rc" "78" "must exit cronbird's FATAL_EXIT_CODE so retries stop"
}

# Declaring nothing is not the same as declaring a gate that cannot be found. scan
# writes "" for an absent preflight: field, and jq's `//` does not substitute empty
# strings, so the resolved value was "" — which reached the unknown-preflight branch
# and ran anyway only because that branch was a no-op. Making the branch fatal
# without normalizing "" first took out four unrelated runner:skill tests, which is
# how this case got written.
test_playbook_with_no_preflight_field_still_dispatches() {
  cat > "$CEO_DIR/playbooks/no-gate.md" << 'PB'
---
name: no-gate
description: Declares no preflight at all
trigger: cron
schedule: "0 9 * * *"
tier: read
status: active
runner: claude
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" no-gate >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a playbook that declares no preflight must run, not fail closed"
  assert_file_exists "$HOME/claude-invoked.txt" "and must actually reach the model"
}

test_unknown_preflight_is_recorded_not_whispered() {
  _write_unknown_preflight_playbook
  bash "$CRON" ghost-gate >/dev/null 2>&1
  local skips
  skips=$(_skips_log)
  assert_contains "$skips" "no_such_gate" \
    "cron-skips.log must name the preflight that could not be resolved"
  assert_contains "$skips" "ERROR" \
    "and record it as a failure, not as a verbose-only note"
}

run_tests
