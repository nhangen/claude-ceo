#!/bin/bash
# ceo-cron.sh tests — #137/#138/#139 run-modes, dry-run, hosts.
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


test_cron_manual_mode_runs_draft_playbook() {
  _register_status_playbook rm-draft draft
  bash "$CRON" rm-draft --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "manual run of a draft playbook must dispatch"
}


# SCHEMA: bare ceo-cron.sh <name> IS the on-demand path. Default mode is manual,
# so a bare invocation runs a draft. Fails on the old gate and on a default=scheduled impl.
test_cron_default_mode_runs_draft_playbook() {
  _register_status_playbook rm-draft-d draft
  bash "$CRON" rm-draft-d >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "bare (default=manual) run of a draft must dispatch (SCHEMA on-demand)"
}


# SCHEMA: on-demand runs disabled too (explicit human force-run).
test_cron_manual_mode_runs_disabled_playbook() {
  _register_status_playbook rm-disabled disabled
  bash "$CRON" rm-disabled --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "manual run of a disabled playbook must dispatch (SCHEMA on-demand)"
}


test_cron_scheduled_mode_skips_draft_playbook() {
  _register_status_playbook rm-draft2 draft
  bash "$CRON" rm-draft2 --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a draft must NOT dispatch" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "rm-draft2" "draft skip must be logged"
}


test_cron_scheduled_mode_skips_disabled_playbook() {
  _register_status_playbook rm-disabled2 disabled
  bash "$CRON" rm-disabled2 --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a disabled playbook must NOT dispatch" test -f "$HOME/claude-invoked.txt"
}


test_cron_scheduled_mode_runs_active_playbook() {
  _register_status_playbook rm-active active
  bash "$CRON" rm-active --scheduled >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "scheduled run of an active playbook must dispatch"
}


# Missing status: SCHEMA treats it as "not active". The old `// "active"`
# coercion would wrongly run it under --scheduled; it must skip.
test_cron_scheduled_mode_skips_missing_status() {
  cat > "$CEO_DIR/playbooks/rm-nostatus.md" << 'PB'
---
name: rm-nostatus
description: run-mode fixture, no status field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_contains "$(jq -r '.playbooks[].name' "$REGISTRY_FILE" 2>/dev/null)" "rm-nostatus" "missing-status playbook must be registered (so the gate, not a missing entry, is what skips it)"
  bash "$CRON" rm-nostatus --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a missing-status playbook must NOT dispatch (SCHEMA: missing = not active)" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "not runnable in scheduled mode" "skip must come from the run-mode gate, not a missing registry entry"
}


test_cron_flag_before_trigger_is_accepted() {
  _register_status_playbook rm-order draft
  bash "$CRON" --manual rm-order >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "flags before the trigger must parse (order-independent)"
}


test_cron_rejects_unknown_run_mode_flag() {
  _register_status_playbook rm-active2 active
  local rc=0
  bash "$CRON" rm-active2 --bogus >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "unknown flag must be rejected with non-zero exit"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "unknown" "stderr must explain the rejected flag"
  assert_fails "a rejected invocation must not dispatch" test -f "$HOME/claude-invoked.txt"
}


test_cron_rejects_conflicting_run_modes() {
  _register_status_playbook rm-active3 active
  local rc=0
  bash "$CRON" rm-active3 --scheduled --manual >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "--scheduled and --manual together must be rejected"
  assert_fails "a rejected invocation must not dispatch" test -f "$HOME/claude-invoked.txt"
}


test_cron_rejects_empty_trigger() {
  local rc=0
  bash "$CRON" --manual >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "a flag with no trigger must exit non-zero"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "Usage" "stderr must print usage"
}


test_cron_rejects_double_trigger() {
  local rc=0
  bash "$CRON" alpha beta >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "two positional triggers must be rejected"
}


# --force is a manual-only smoke-test escape hatch; it must not weaken the
# runaway-protection invariant on scheduled (cron/daemon) runs.
test_cron_rejects_force_on_scheduled() {
  _register_status_playbook rm-active4 active
  local rc=0
  bash "$CRON" rm-active4 --scheduled --force >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "--force with --scheduled must be rejected"
}


# Isolate --force: all three runs are manual+active, so only --force can explain
# the third dispatch surviving the cooldown.
test_cron_force_flag_bypasses_cooldown() {
  _register_status_playbook rm-cool active
  bash "$CRON" rm-cool --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "first run must dispatch and record last-run"
  rm -f "$HOME/claude-invoked.txt"
  bash "$CRON" rm-cool --manual >/dev/null 2>&1 || true
  assert_fails "second manual run within cooldown must be skipped" test -f "$HOME/claude-invoked.txt"
  bash "$CRON" rm-cool --manual --force >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "--force must bypass the per-trigger cooldown"
}


# The catch-all arm must skip an out-of-set status (hand-edited registry) AND emit
# its distinct diagnostic — not the message any non-active status produced under
# the old gate (that would be a tautology passing on pre-change code).
test_cron_catchall_skips_unknown_status() {
  _register_status_playbook rm-weird active
  local reg="$REGISTRY_FILE"
  jq '(.playbooks[] | select(.name=="rm-weird") | .status) = "bogus"' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  bash "$CRON" rm-weird --manual >/dev/null 2>&1 || true
  assert_fails "out-of-set status must never dispatch (defense-in-depth catch-all)" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "unexpected run-mode:status" "catch-all must emit its distinct diagnostic"
}


# A runner:script playbook in dry-run must NOT exec the script; it previews the
# would-run command instead. This is the core "show what would happen, do nothing".
test_dry_run_script_runner_skips_exec_and_previews() {
  cat > "$CEO_DIR/playbooks/dr-script.md" << 'PB'
---
name: dr-script
description: dry-run script fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: dr-script.sh
---
PB
  cat > "$SCRIPT_DIR/dr-script.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/dr-script-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/dr-script.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-script --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must NOT exec the script" test -f "$TEST_HOME/dr-script-fired.txt"
  local pf; pf=$(_preview_file dr-script)
  assert_file_exists "$pf" "dry-run must write a preview file"
  assert_contains "$(cat "$pf" 2>/dev/null)" "dr-script.sh" "preview must name the would-run script"

  rm -f "$SCRIPT_DIR/dr-script.sh"
}


# Cooldown integrity: a dry-run must not stamp .last-run, or it would silently
# suppress the next real scheduled run.
test_dry_run_does_not_write_last_run() {
  _register_status_playbook dr-nolastrun active
  bash "$CRON" dr-nolastrun --dry-run >/dev/null 2>&1 || true
  assert_fails "dry-run must not write the .last-run stamp" test -f "$CEO_DIR/log/.last-run-dr-nolastrun"
  assert_file_exists "$(_preview_file dr-nolastrun)" "dry-run must still produce a preview"
}


# A dry-run must bypass the per-trigger cooldown so it can be run iteratively
# right after a real run.
test_dry_run_bypasses_cooldown() {
  _register_status_playbook dr-cool active
  bash "$CRON" dr-cool --manual >/dev/null 2>&1 || true
  assert_file_exists "$CEO_DIR/log/.last-run-dr-cool" "real run must stamp last-run"
  bash "$CRON" dr-cool --dry-run >/dev/null 2>&1 || true
  assert_file_exists "$(_preview_file dr-cool)" "dry-run must run despite a recent real run (cooldown bypassed)"
}


# read-tier dry-run: the read-only model call may happen, but its output is
# routed to the preview file — NOT posted to Discord and NOT recorded as a run.
test_dry_run_read_tier_no_discord_and_previews_output() {
  cat > "$CEO_DIR/playbooks/dr-read.md" << 'PB'
---
name: dr-read
description: dry-run read fixture
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
PB
  # The read-tier single-call path always requests --output-format json and
  # extracts the body via `jq -r '.result'`, so the stub emits a JSON envelope.
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
{"result":"LOG_ENTRY:\n## 09:00 — dr-read\n**Status:** completed\n**Playbook:** playbooks/dr-read.md\n**Output:**\nPreview body from the read model.\n**Errors:**\n- none\nEND_LOG_ENTRY","total_cost_usd":0.001,"session_id":"test"}
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
    -d) shift; printf '%s' "$1" > "$out" ;;
  esac
  shift || true
done
exit 0
STUB
  chmod +x "$HOME/.bun/bin/curl"
  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' > "$HOME/.config/claude-ceo/secrets.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dr-read --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must not post to Discord" test -f "$CURL_CAPTURE_DIR/payload.json"
  local pf; pf=$(_preview_file dr-read)
  assert_contains "$(cat "$pf" 2>/dev/null)" "Preview body from the read model." "preview must capture the model output"
  assert_not_contains "$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null)" "dr-read completed" "dry-run must not append to cron-runs.log"
  assert_fails "dry-run must not create the synced daily log file CEO/log/<TODAY>.md" test -f "$CEO_DIR/log/$(date +%Y-%m-%d).md"

  unset CURL_CAPTURE_DIR
}


# tier:write dry-run: PLAN runs (read-only) but EXECUTE is skipped, and the
# high-stakes proposal is previewed rather than appended to the approvals queue.
test_dry_run_write_tier_skips_execute_and_pending() {
  cat > "$CEO_DIR/playbooks/dr-write.md" << 'PB'
---
name: dr-write
description: dry-run write fixture
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: high-stakes
status: active
---
PB
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "call" >> "$HOME/claude-calls.log"
cat >/dev/null
echo "ACTION: 1 | high-stakes | deploy the thing | gh deploy"
echo "ACTION: 2 | read | check the status | n/a"
STUB
  chmod +x "$HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dr-write --dry-run >/dev/null 2>&1 || true

  assert_eq "$(wc -l < "$HOME/claude-calls.log" 2>/dev/null | tr -d ' ')" "1" "dry-run tier:write must run PLAN only — EXECUTE must be skipped"
  assert_fails "write-tier dry-run must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-write"
  assert_not_contains "$(cat "$CEO_DIR/approvals/pending.md" 2>/dev/null)" "deploy the thing" "dry-run must not append high-stakes proposals to the approvals queue"
  local pf; pf=$(_preview_file dr-write)
  assert_contains "$(cat "$pf" 2>/dev/null)" "deploy the thing" "preview must list the deferred high-stakes action"
  assert_contains "$(cat "$pf" 2>/dev/null)" "check the status" "preview must list the safe action that would execute"
}


# runner:skill in dry-run must NOT exec the skill or write its out_pattern;
# it previews the would-run skill instead.
test_dry_run_skill_runner_skips_exec_and_previews() {
  cat > "$CEO_DIR/playbooks/dr-skill.md" << 'PB'
---
name: dr-skill
description: dry-run skill fixture
trigger: cron
status: active
tier: read
runner: skill
skill: dr-skill-test
out_pattern: CEO/reports/test/dr-skill-out.md
---
PB
  mkdir -p "$HOME/.claude/skills/dr-skill-test/scripts"
  cat > "$HOME/.claude/skills/dr-skill-test/scripts/run-report.sh" << EOF
#!/bin/bash
echo "ran" > "$TEST_HOME/dr-skill-fired.txt"
EOF
  chmod +x "$HOME/.claude/skills/dr-skill-test/scripts/run-report.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-skill --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must NOT exec the skill" test -f "$TEST_HOME/dr-skill-fired.txt"
  assert_fails "dry-run must NOT write the skill out_pattern" test -f "$CEO_DIR/reports/test/dr-skill-out.md"
  assert_contains "$(cat "$(_preview_file dr-skill)" 2>/dev/null)" "dr-skill-test" "preview must name the would-run skill"
}


# When a dry-run hits a preflight that returns no-work, it must preview the skip
# WITHOUT stamping .last-run (a real run stamps it; a dry-run must not).
test_dry_run_preflight_no_work_does_not_stamp_last_run() {
  cat > "$CEO_DIR/playbooks/dr-pf.md" << 'PB'
---
name: dr-pf
description: dry-run preflight fixture
trigger: cron
schedule: "0 9 * * *"
preflight: has_pending_items
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  # has_pending_items is false (no PENDING_ASK_QUESTIONS), so preflight returns no-work.
  bash "$CRON" dr-pf --dry-run >/dev/null 2>&1 || true
  assert_fails "dry-run preflight-skip must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-pf"
  assert_contains "$(cat "$(_preview_file dr-pf)" 2>/dev/null)" "no-work" "preview must record the preflight no-work skip"
}


# The preview dir lives under CEO/log/, which is a SYNCED vault tree (only the
# dotfiles in shared.stignore are host-local). For the preview to be the
# host-local scratch the design promises, CEO/log/preview/ must be excluded from
# sync — otherwise a dry-run on one host propagates its preview to every host.
test_dry_run_preview_dir_excluded_from_sync() {
  local stignore="$SCRIPT_DIR/../syncthing/shared.stignore"
  assert_file_exists "$stignore" "shared.stignore must exist"
  assert_contains "$(cat "$stignore" 2>/dev/null)" "CEO/log/preview/" "preview dir must be stignored so dry-run output stays host-local"
}


# Dry-run is allowed under --scheduled (e.g. a daemon smoke-test) but must warn,
# so a cron stuck in dry-run is observable rather than silently doing nothing.
test_dry_run_under_scheduled_warns() {
  _register_status_playbook dr-sched active
  bash "$CRON" dr-sched --scheduled --dry-run >/dev/null 2>&1 || true
  assert_file_exists "$(_preview_file dr-sched)" "dry-run under scheduled must still preview"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "dry-run" "a dry-run under --scheduled must emit a WARN"
}


# Failure path: a dry-run that hits a failure must NOT increment the fail-count,
# stamp .last-run, fire the pending alert, or notify — it previews the would-fail.
# (read-tier claude exit 1 reaches _record_failure.)
test_dry_run_failure_path_has_no_side_effects() {
  _register_status_playbook dr-fail active
  echo 3 > "$CEO_DIR/log/.fail-count"
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
exit 1
STUB
  chmod +x "$HOME/.bun/bin/claude"

  bash "$CRON" dr-fail --dry-run >/dev/null 2>&1 || true

  assert_eq "$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null)" "3" "dry-run failure must not increment the fail-count"
  assert_fails "dry-run failure must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-fail"
  assert_contains "$(cat "$(_preview_file dr-fail)" 2>/dev/null)" "Would record FAILURE" "preview must record the would-be failure"
}


# pending-drip writes to the host inbox (a CEO decision-state mutation). A dry-run
# must preview that instead of mutating the inbox.
test_dry_run_pending_drip_does_not_write_inbox() {
  cat > "$CEO_DIR/playbooks/pending-drip.md" << 'PB'
---
name: pending-drip
description: dry-run pending-drip fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  # The read-tier single-call path always requests --output-format json and
  # extracts the body via `jq -r '.result'`, so the stub emits a JSON envelope.
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
{"result":"LOG_ENTRY:\n## 09:00 — pending-drip\n**Status:** completed\n**Playbook:** playbooks/pending-drip.md\n**Output:**\n- A genuine pending question to surface.\n**Errors:**\n- none\nEND_LOG_ENTRY","total_cost_usd":0.001,"session_id":"test"}
OUT
STUB
  chmod +x "$HOME/.bun/bin/claude"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" pending-drip --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must not create the host inbox" test -d "$CEO_DIR/inbox"
  assert_contains "$(cat "$(_preview_file pending-drip)" 2>/dev/null)" "inbox" "preview must note the would-be inbox append"
}


# _preview truncates the per-day file on the first write of each run, so a second
# dry-run of the same trigger/day REPLACES rather than appends.
test_dry_run_preview_truncates_per_run() {
  cat > "$CEO_DIR/playbooks/dr-trunc.md" << 'PB'
---
name: dr-trunc
description: dry-run truncation fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: dr-trunc.sh
---
PB
  cat > "$SCRIPT_DIR/dr-trunc.sh" << 'SH'
#!/bin/bash
true
SH
  chmod +x "$SCRIPT_DIR/dr-trunc.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-trunc --dry-run >/dev/null 2>&1 || true
  bash "$CRON" dr-trunc --dry-run >/dev/null 2>&1 || true

  assert_eq "$(grep -c '# DRY-RUN preview' "$(_preview_file dr-trunc)" 2>/dev/null | tr -d ' ')" "1" "a re-run must replace the preview, not append a second header"

  rm -f "$SCRIPT_DIR/dr-trunc.sh"
}


# Absent hosts → recorded as ["*"] (all hosts), the backward-compatible default.
test_hosts_absent_defaults_to_wildcard() {
  cat > "$CEO_DIR/playbooks/h-absent.md" << 'PB'
---
name: h-absent
description: no hosts field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-absent)" '["*"]' "absent hosts must default to [\"*\"]"
}


# Explicit flow-sequence host list is recorded verbatim.
test_hosts_explicit_list_recorded() {
  cat > "$CEO_DIR/playbooks/h-list.md" << 'PB'
---
name: h-list
description: explicit host list
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", "mac-mini"]
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-list)" '["ml-1","mac-mini"]' "explicit hosts list must be recorded verbatim"
}


# Block-sequence YAML form is parsed identically.
test_hosts_block_sequence_recorded() {
  cat > "$CEO_DIR/playbooks/h-block.md" << 'PB'
---
name: h-block
description: block-sequence host list
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts:
  - ml-1
  - wsl-carla
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-block)" '["ml-1","wsl-carla"]' "block-sequence hosts must parse to a JSON array"
}


# A scalar (non-array) hosts value must warn and default to ["*"], never silently
# scope to a single host (enum-config-typo-fallback: don't coerce a typo).
test_hosts_non_array_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-scalar.md" << 'PB'
---
name: h-scalar
description: scalar hosts
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ml-1
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be an array" "scan must warn when hosts is not an array"
  assert_eq "$(_hosts_in_registry h-scalar)" '["*"]' "non-array hosts must default to [\"*\"]"
}


# An empty array would mean "runs nowhere" — a likely mistake that would silently
# disable the playbook. Warn and default to all; use status:disabled to stop one.
test_hosts_empty_array_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-empty.md" << 'PB'
---
name: h-empty
description: empty hosts array
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: []
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on empty hosts array"
  assert_eq "$(_hosts_in_registry h-empty)" '["*"]' "empty hosts array must default to [\"*\"]"
}


# An empty/whitespace element is malformed → warn and default to all.
test_hosts_empty_element_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-blank.md" << 'PB'
---
name: h-blank
description: hosts with an empty element
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", ""]
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on a blank host element"
  assert_eq "$(_hosts_in_registry h-blank)" '["*"]' "a blank host element must default to [\"*\"]"
}


# A whitespace-only element pins the test("\\S") clause specifically (distinct
# from the empty-string case above) — if someone simplifies \S to !="" this
# test is the only thing that catches the regression.
test_hosts_whitespace_element_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-ws.md" << 'PB'
---
name: h-ws
description: hosts with a whitespace-only element
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", "  "]
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on a whitespace-only host element"
  assert_eq "$(_hosts_in_registry h-ws)" '["*"]' "a whitespace-only element must default to [\"*\"]"
}


# Phase 1 records hosts but does NOT enforce them: a playbook scoped to a
# different host still dispatches here. Enforcement arrives with the daemon (1.5).
test_hosts_recorded_but_not_enforced_in_phase1() {
  cat > "$CEO_DIR/playbooks/h-other.md" << 'PB'
---
name: h-other
description: scoped to a host that is not this one
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["definitely-not-this-host"]
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-other)" '["definitely-not-this-host"]' "off-host scope must still be recorded"
  bash "$CRON" h-other --scheduled >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "Phase 1 must NOT enforce hosts — playbook still dispatches"
}

run_tests
