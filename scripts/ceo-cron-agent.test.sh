#!/bin/bash
# ceo-cron.sh tests — runner:ollama-agent (bridge) dispatch.
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


test_runner_ollama_agent_ingests_hallucinated_calls() {
  _register_agent_pb agent-ingest low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["make_coffee", "teleport"]}'
  _make_pt_stub
  export CEO_AGENT_RUN_ID="run-ingest-1"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-ingest >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "2" "both hallucinated calls must be ingested as findings"
  assert_contains "$(cat "$PT_STUB_DB" 2>/dev/null)" "local-run://run-ingest-1|agent-ingest|0|hallucinated tool call: make_coffee" "finding must embed run id (pr_url) + call index (line_no) + name"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_ingest_idempotent_across_reingest() {
  # Dedup key = run_id (pr_url) + call index (line_no). Re-ingesting the SAME run
  # must not double-insert, and two calls with the SAME name must stay distinct
  # via their index. Revert either half of the key and this assertion fails.
  _register_agent_pb agent-idem low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["make_coffee", "make_coffee", "teleport"]}'
  _make_pt_stub
  export CEO_AGENT_RUN_ID="run-idem-1"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-idem >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "3" "3 calls (one name repeated) must be 3 distinct findings via index"
  # CEO_FORCE=1 bypasses the per-trigger "last run too recent" guard so the
  # second run genuinely re-executes and re-ingests — otherwise this assertion
  # is vacuous (the run would be skipped, not deduped).
  CEO_FORCE=1 bash "$CRON" agent-idem >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "3" "re-ingesting the same run must not double-insert (idempotent on run_id+index)"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_ingests_even_when_incomplete() {
  # The ingest runs BEFORE the completion gate, so a hallucinating-but-incomplete
  # run still records its findings. Move the ingest call below the incomplete gate
  # and this assertion drops to 0 rows.
  _register_agent_pb agent-inchal low-stakes-write
  _make_agent_stub '{"completed": false, "turns": 8, "calls": [], "unknown_calls": ["bogus_tool"]}'
  _make_pt_stub
  export CEO_AGENT_RUN_ID="run-inchal-1"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-inchal >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] an incomplete run must still exit non-zero\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "1" "a hallucinating-but-incomplete run must still ingest the finding (ingest precedes the gate exit)"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_tool_error_records_failure() {
  # A completed run whose bridge .tool_errors[] carries a mutating-tool failure
  # (e.g. a write_file that errored) must record a FAILURE, not success — the
  # report write silently failed. Reverting the dispatch-side tool_errors gate
  # makes this run record success (exit 0), so the assertions flip.
  _register_agent_pb agent-toolerr low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 2, "calls": [["write_file", {"path": "report.md"}]], "unknown_calls": [], "tool_errors": [{"tool": "write_file", "error": "write_file failed: PermissionError: [Errno 13]"}]}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-toolerr >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] a completed run with a tool error must exit non-zero\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "tool error" "cron-skips.log must record the tool-error failure reason"
  assert_contains "$skips_log" "write_file" "the failure reason must name the failing tool"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_agent_clean_completed_run_succeeds() {
  # Guards acceptance #2: a genuine no-op / clean completion (empty tool_errors,
  # no writes) must NOT false-positive as a failure. A run_shell that exited
  # non-zero benignly never reaches tool_errors (no "error" key), so the bridge
  # reports tool_errors:[] and the run succeeds.
  _register_agent_pb agent-clean low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": [], "tool_errors": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-clean >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a completed run with no tool errors must succeed (no false-positive on the no-op path)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_agent_ingests_null_unknown_call() {
  # agent.py appends None for a malformed tool-call envelope (no function name),
  # so unknown_calls can contain null. It must still ingest, rendered (unnamed).
  _register_agent_pb agent-null low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": [null, "teleport"]}'
  _make_pt_stub
  export CEO_AGENT_RUN_ID="run-null-1"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-null >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "2" "a null (malformed-envelope) unknown_call must still ingest as a finding"
  assert_contains "$(cat "$PT_STUB_DB" 2>/dev/null)" "hallucinated tool call: (unnamed)" "a null name must render as (unnamed)"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_distinct_runs_not_deduped() {
  # The run_id half of the dedup key: two DIFFERENT runs with identical call
  # names/indices must NOT collide. Drop run_id from pr_url and this drops to 2.
  _register_agent_pb agent-tworun low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["make_coffee", "teleport"]}'
  _make_pt_stub
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  # CEO_FORCE=1 on the second run bypasses the per-trigger interval guard so both
  # runs actually execute (same trigger, back-to-back).
  CEO_AGENT_RUN_ID="run-A" bash "$CRON" agent-tworun >/dev/null 2>&1 || true
  CEO_FORCE=1 CEO_AGENT_RUN_ID="run-B" bash "$CRON" agent-tworun >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$PT_STUB_DB" 2>/dev/null | tr -d ' ')" "4" "two distinct runs with identical calls must produce 4 findings (run_id half of the dedup key)"
}


test_runner_ollama_agent_clean_run_ingests_nothing() {
  _register_agent_pb agent-clean low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 2, "calls": [], "unknown_calls": []}'
  _make_pt_stub
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-clean >/dev/null 2>&1 || true
  local _rows
  _rows=$([ -f "$PT_STUB_DB" ] && wc -l < "$PT_STUB_DB" | tr -d ' ' || echo 0)
  assert_eq "$_rows" "0" "a clean run (no unknown_calls) must ingest nothing"
}


test_runner_ollama_agent_ingest_skips_when_pt_absent() {
  # pattern-tracker absent must never block the run — skip with a notice. The run
  # still fails its gate (unknown_calls), but on the gate, not on a missing pt.
  _register_agent_pb agent-noptt low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["bogus_tool"]}'
  unset CEO_PT_FINDING_CMD
  export CEO_PT_REPO="$HOME/no-such-pattern-tracker"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-noptt >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] hallucinated run must still fail its gate even when pt is absent\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "pattern-tracker absent" "pt-absent must log a skip notice"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "unknown tool call" "the gate failure must still be recorded"
  unset CEO_PT_REPO
}


test_runner_ollama_agent_ingest_skips_on_pt_failure() {
  _register_agent_pb agent-ptfail low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["bogus_tool"]}'
  cat > "$HOME/.bun/bin/pt-fail" << 'STUB'
#!/bin/bash
cat >/dev/null
echo "pt boom" >&2
exit 1
STUB
  chmod +x "$HOME/.bun/bin/pt-fail"
  export CEO_PT_FINDING_CMD="$HOME/.bun/bin/pt-fail --db /tmp/x"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-ptfail >/dev/null 2>&1 || true
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "ingest failed" "a pt ingest failure must log a notice, never crash the run"
  unset CEO_PT_FINDING_CMD
}


test_runner_ollama_agent_success() {
  _register_agent_pb agent-ok low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 2, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-ok >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ollama-agent success must exit 0"
  [ -f "$HOME/agent-invoked.txt" ] || { printf '  FAIL [%s] bridge must be invoked on success\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)); }
  assert_contains "$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null)" "agent-ok completed" "success must record to cron-runs.log"
}


test_runner_ollama_agent_emits_run_event() {
  # Slice D: every run emits one events row via pt event-add carrying the run id,
  # namespaced tool_name, rules_loaded_hash, and a compact error_tail JSON.
  # Revert the `_emit_run_event` call in ceo-cron.sh and this fails (no row).
  _register_agent_pb agent-evt low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [["run_shell",{}],["write_file",{}]], "unknown_calls": [], "rules_loaded_hash": "abc123def4567890"}'
  _make_pt_event_stub
  export CEO_AGENT_RUN_ID="run-evt-1"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-evt >/dev/null 2>&1 || true
  local row; row=$(cat "$PT_EVENT_DB" 2>/dev/null)
  assert_contains "$row" "\"tool_name\":\"ollama-agent:agent-evt\"" "tool_name must be namespaced ollama-agent:<task>"
  assert_contains "$row" "\"session_id\":\"run-evt-1\"" "session_id must be the run id"
  assert_contains "$row" "\"rules_loaded_hash\":\"abc123def4567890\"" "rules_loaded_hash must pass through from the bridge record"
  assert_contains "$row" "\"exit_code\":0" "exit_code must be 0 — completion lives in error_tail, not exit_code"
  assert_contains "$row" "\"event_id\":\"run-evt-1\"" "event_id must equal the run id — the INSERT OR IGNORE idempotency key (drop event_id: \$rid and this fails)"
  assert_contains "$row" 'completed\":true' "error_tail must record completion"
  assert_contains "$row" 'calls\":2' "error_tail must carry the tool-call count"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_emits_event_even_on_non_completion() {
  # The event must record runs that did NOT complete (that is the signal slice D
  # correlates), even though the run itself is recorded as a failure.
  _register_agent_pb agent-evt2 low-stakes-write
  _make_agent_stub '{"completed": false, "turns": 8, "calls": [], "unknown_calls": []}'
  _make_pt_event_stub
  export CEO_AGENT_RUN_ID="run-evt-2"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-evt2 >/dev/null 2>&1 || true
  local row; row=$(cat "$PT_EVENT_DB" 2>/dev/null)
  assert_contains "$row" "\"session_id\":\"run-evt-2\"" "a non-completing run must still emit its event"
  assert_contains "$row" 'completed\":false' "error_tail must record completed=false for a non-completing run (revert .completed // false and this fails)"
  assert_contains "$row" 'turns\":8' "error_tail must carry the non-completing run's turn count"
  unset CEO_AGENT_RUN_ID
}


test_runner_ollama_agent_breadcrumb_on_event_add_failure() {
  # A failed event-add must leave a grep-able NOTICE in cron-skips.log, not vanish
  # into cron-stderr.log noise — a permanently-broken emit path must be detectable
  # (the disk-monitor incident class). Revert the `|| pt_rc=$?` + NOTICE in
  # _emit_run_event and this fails.
  _register_agent_pb agent-evt3 low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": []}'
  cat > "$HOME/.bun/bin/pt-event-failstub" << 'STUB'
#!/bin/bash
cat >/dev/null
exit 7
STUB
  chmod +x "$HOME/.bun/bin/pt-event-failstub"
  export CEO_PT_EVENT_CMD="$HOME/.bun/bin/pt-event-failstub"
  export CEO_AGENT_RUN_ID="run-evt-3"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-evt3 >/dev/null 2>&1 || true
  local skips; skips=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)
  assert_contains "$skips" "event-add failed (rc=7)" "a failed event-add must write a NOTICE to cron-skips.log"
  unset CEO_AGENT_RUN_ID CEO_PT_EVENT_CMD
}


test_runner_ollama_agent_dispatches_with_cwd_in_vault() {
  # The bridge takes no --cwd of its own, so a write-tier playbook's relative
  # reads/writes would resolve against an undefined cwd. The dispatch must run
  # the bridge with --cwd "$CEO_DIR" so a task reads (log/…) and writes
  # (reports/…) relative to the vault's CEO dir. Revert the `--cwd "$CEO_DIR"`
  # arg in ceo-cron.sh and the stub's argv gate (exit 97) fails this; the value
  # assertion additionally pins it to $CEO_DIR (not some other dir).
  _register_agent_pb agent-cwd low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" agent-cwd >/dev/null 2>&1 || true
  assert_contains "$(cat "$HOME/agent-argv.txt" 2>/dev/null)" "--cwd $CEO_DIR" "bridge must be invoked with --cwd \$CEO_DIR"
}


test_runner_ollama_agent_high_stakes_refused_before_dispatch() {
  _register_agent_pb agent-hs high-stakes
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-hs >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] high-stakes ollama-agent must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$HOME/agent-invoked.txt" ]; then
    printf '  FAIL [%s] high-stakes must NOT invoke the bridge (gate is cron-side)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "may not run high-stakes" "refusal reason must be logged"
}


test_runner_ollama_agent_hallucinated_calls_is_failure() {
  _register_agent_pb agent-halluc low-stakes-write
  _make_agent_stub '{"completed": true, "turns": 3, "calls": [], "unknown_calls": ["bogus_tool"]}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-halluc >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] a run with unknown_calls must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "unknown tool call" "hallucinated call must be recorded as failure"
}


test_runner_ollama_agent_incomplete_is_failure() {
  _register_agent_pb agent-incomplete low-stakes-write
  _make_agent_stub '{"completed": false, "turns": 8, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-incomplete >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] completed:false must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "did not complete" "incomplete run must be recorded as failure"
}


test_runner_ollama_agent_tier_drift_normalized() {
  # The live registry carries "low-stakes write" (space); the canonical form is
  # hyphenated. The boundary normalization must accept the space variant.
  _register_agent_pb agent-drift "low-stakes write"
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-drift >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "space-variant tier must normalize and run (got rc=$rc)"
  [ -f "$HOME/agent-invoked.txt" ] || { printf '  FAIL [%s] normalized tier must reach the bridge\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)); }
}


test_runner_ollama_agent_missing_registry_is_failure() {
  cat > "$CEO_DIR/playbooks/agent-noreg.md" << 'PB'
---
name: agent-noreg
description: ollama-agent with no registry field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: low-stakes-write
status: active
runner: ollama-agent
---
# body
PB
  _make_agent_stub '{"completed": true, "turns": 1, "calls": [], "unknown_calls": []}'
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-noreg >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] missing registry must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$HOME/agent-invoked.txt" ]; then
    printf '  FAIL [%s] missing registry must fail before invoking the bridge\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "no 'registry' field" "missing-registry error must be logged"
}


test_runner_ollama_agent_malformed_output_is_failure() {
  # A 0-exit bridge that emits non-JSON must be recorded as a failure, not crash
  # ceo-cron.sh on the jq pipeline under set -euo pipefail (non-throwing-client-
  # success-check): the parse-validity guard must route it through _record_failure.
  _register_agent_pb agent-garbage low-stakes-write
  cat > "$HOME/.bun/bin/agent-stub" << 'STUB'
#!/bin/bash
echo invoked >> "$HOME/agent-invoked.txt"
echo "not json at all"
STUB
  chmod +x "$HOME/.bun/bin/agent-stub"
  export CEO_OLLAMA_AGENT_CMD="$HOME/.bun/bin/agent-stub"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-garbage >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] malformed bridge output must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  # The failure must be RECORDED (fail-count incremented), not a bare set -e crash.
  assert_eq "$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null)" "1" "malformed output must increment the fail count (not crash before recording)"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "unparseable output" "parse failure reason must be logged"
}


test_runner_ollama_agent_missing_bridge_command_is_failure() {
  _register_agent_pb agent-nocmd low-stakes-write
  export CEO_OLLAMA_AGENT_CMD="$HOME/.bun/bin/does-not-exist-agent"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" agent-nocmd >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] a missing bridge command must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "bridge exited" "missing bridge command must be recorded as a failure"
}

run_tests
