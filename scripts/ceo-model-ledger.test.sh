#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-model-ledger.sh"

setup() {
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export OLLAMA_AGENT_LEDGER
}

teardown() {
  rm -f "$OLLAMA_AGENT_LEDGER"
}

test_write_entry_returns_a_run_id() {
  local run_id
  run_id=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  assert_contains "$run_id" "claude-tier-" "run_id is prefixed with the writer type"
}

test_two_writes_get_unique_run_ids() {
  local a b
  a=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  b=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")
  assert_fails "run_ids must differ" [ "$a" = "$b" ]
}

test_entry_is_one_valid_json_line() {
  ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true" > /dev/null
  assert_eq "$(wc -l < "$OLLAMA_AGENT_LEDGER" | tr -d ' ')" "1" "one write must append exactly one line"
  assert_eq "$(tail -1 "$OLLAMA_AGENT_LEDGER" | jq -e . >/dev/null 2>&1 && echo valid || echo invalid)" \
    "valid" "the appended line must be one valid JSON object"
}

test_claude_tier_entry_coexists_with_ollama_agent_entry() {
  printf '%s\n' '{"ts": "2026-07-09T16:18:50Z", "run_id": "lean-batch-1", "session_id": "abc", "model": "gpt-oss:20b", "task_name": null, "cwd": "/tmp/task1", "ollama_input_tokens": 100, "ollama_output_tokens": 20, "turns": 3, "completed": true, "verified": true}' >> "$OLLAMA_AGENT_LEDGER"
  local run_id
  run_id=$(ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true")

  local ollama_matches claude_matches
  ollama_matches=$(jq -c --arg rid "lean-batch-1" 'select(.run_id == $rid)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  claude_matches=$(jq -c --arg rid "$run_id" 'select(.run_id == $rid)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')

  assert_eq "$ollama_matches" "1" "the pre-existing ollama-agent row is still uniquely selectable by run_id"
  assert_eq "$claude_matches" "1" "the new claude-tier row is uniquely selectable by run_id"
}

test_ledger_write_entry_does_not_propagate_write_failures_under_set_e() {
  local output exit_code
  output=$( (
    set -e
    export OLLAMA_AGENT_LEDGER="/nonexistent_root_dir/cant/write/here.jsonl"
    ceo_ledger_write_entry "claude-tier" "haiku" "test" "/tmp" "0.002" "true" > /dev/null 2>&1
    echo "reached_end"
  ) 2>&1 )
  exit_code=$?

  assert_eq "$exit_code" "0" "subshell must exit with 0 after failed ceo_ledger_write_entry under set -e"
  assert_contains "$output" "reached_end" "line after failed ceo_ledger_write_entry must execute under set -e"
}

test_entry_emits_explicit_null_for_verified_and_verify_gated() {
  ceo_ledger_write_entry "claude-tier" "haiku" "test-playbook" "/tmp" "0.002" "true" > /dev/null
  local last_line
  last_line=$(tail -1 "$OLLAMA_AGENT_LEDGER")
  # has() as well as the value: `jq '.verified'` prints null for a missing key
  # too, so a value-only check passed with the fix reverted. Present-and-null
  # versus absent is the whole distinction #434 is about.
  assert_eq "$(printf '%s\n' "$last_line" | jq -c '[has("verified"), has("verify_gated"), has("verify_cmd"), .verified, .verify_gated, .verify_cmd]')" \
    '[true,true,true,null,null,null]' \
    "verify fields must be present and null on shell-written rows, not absent"
}

# --- #491: a gated caller records its real gate, not the ungated nulls ---
test_a_caller_can_record_a_real_verify_gate() {
  ceo_ledger_write_entry "ceo-loop" "qwen" "loop:r/b" "/tmp" null true true true "make check" > /dev/null
  assert_eq "$(tail -1 "$OLLAMA_AGENT_LEDGER" | jq -c '[.verified, .verify_gated, .verify_cmd]')" \
    '[true,true,"make check"]' "verify args passed by the caller must reach the row"
}

test_a_red_gate_is_recorded_as_verified_false() {
  ceo_ledger_write_entry "ceo-loop" "qwen" "loop:r/b" "/tmp" null false false true "make check" > /dev/null
  assert_eq "$(tail -1 "$OLLAMA_AGENT_LEDGER" | jq -c '[.verified, .verify_gated]')" \
    '[false,true]' "a gate that ran red must read verified:false, not the no-opinion null"
}

# --- #490: a malformed value costs its own field, never the whole row. Before
# this, one bad --argjson made jq refuse the object, `|| true` hid it, and the
# function still printed a run_id, so the row vanished with no trace. ---
test_a_malformed_cost_degrades_to_null_instead_of_dropping_the_row() {
  local err
  err=$(ceo_ledger_write_entry "claude-tier" "haiku" "t" "/tmp" "abc" "true" 2>&1 >/dev/null)
  assert_eq "$(wc -l < "$OLLAMA_AGENT_LEDGER" | tr -d ' ')" "1" "a malformed cost_usd must not drop the row"
  assert_eq "$(tail -1 "$OLLAMA_AGENT_LEDGER" | jq -c '[.cost_usd, .completed]')" '[null,true]' \
    "only the malformed field is nulled; the rest of the row survives"
  assert_contains "$err" "cost_usd" "the degradation must be reported on stderr, not swallowed"
}

test_a_two_line_cost_from_a_trailing_banner_keeps_the_row() {
  # The exact shape ceo-cron.sh's SINGLE_COST produced when the CLI printed the
  # JSON envelope and then a rate-limit banner: jq emitted the cost, failed on
  # the banner, and `|| echo null` appended a second line. That row is the
  # completed:false row for precisely the runs that failed.
  ceo_ledger_write_entry "claude-tier" "haiku" "t" "/tmp" $'0.01\nnull' "false" > /dev/null 2>&1
  assert_eq "$(wc -l < "$OLLAMA_AGENT_LEDGER" | tr -d ' ')" "1" "a two-line cost must not drop the failed-run row"
  assert_eq "$(tail -1 "$OLLAMA_AGENT_LEDGER" | jq -c '.completed')" "false" "the failed run is still recorded as failed"
}

test_a_failed_append_is_reported_on_stderr() {
  local err
  err=$( ( export OLLAMA_AGENT_LEDGER="/nonexistent_root_dir/cant/write.jsonl"
           ceo_ledger_write_entry "claude-tier" "haiku" "t" "/tmp" "0.002" "true" >/dev/null ) 2>&1 )
  assert_contains "$err" "ceo-model-ledger: append to /nonexistent_root_dir/cant/write.jsonl failed" \
    "a lost row must leave a trace; the caller discards stdout, so stderr is the only channel"
  # Pins the redirection order: with `>>` before `2>/dev/null` the shell reports
  # the failed open itself, so the writer's line arrives beside a bare error.
  assert_not_contains "$err" "No such file" \
    "the writer's message must be the only one, not a second copy from the shell"
}

run_tests
