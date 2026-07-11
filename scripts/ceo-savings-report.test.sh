#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export OLLAMA_AGENT_LEDGER
  cat > "$OLLAMA_AGENT_LEDGER" <<'JSONL'
{"ts": "2026-07-09T16:18:50Z", "run_id": "lean-batch-1", "session_id": "s1", "model": "gpt-oss:20b", "task_name": null, "cwd": "/t1", "ollama_input_tokens": 10601, "ollama_output_tokens": 1246, "turns": 6, "completed": true, "verified": true}
{"ts": "2026-07-10T09:00:00Z", "run_id": "claude-tier-aaa", "session_id": "s2", "writer": "interactive-tier", "model": "haiku", "task_name": "read-only-lookup", "cwd": "/t2", "cost_usd": 0.002, "completed": true}
{"ts": "2026-07-10T09:05:00Z", "run_id": "claude-tier-bbb", "session_id": "s2", "writer": "claude-tier", "model": "haiku", "task_name": "find-stale-branches", "cwd": "/t3", "cost_usd": null, "completed": null}
JSONL
}

teardown() {
  rm -f "$OLLAMA_AGENT_LEDGER"
}

test_report_counts_rows_per_tier() {
  local output
  output=$(bash "$SCRIPT_DIR/ceo-savings-report.sh")
  assert_contains "$output" "ollama: 1" "counts the ollama-agent row"
  assert_contains "$output" "haiku: 2" "counts both haiku rows (interactive-tier + claude-tier)"
}

test_report_flags_unpriced_rows() {
  local output
  output=$(bash "$SCRIPT_DIR/ceo-savings-report.sh")
  assert_contains "$output" "unpriced: 1" "the null-cost row is reported as unpriced, not guessed"
}

test_report_sums_known_cost() {
  local output
  output=$(bash "$SCRIPT_DIR/ceo-savings-report.sh")
  assert_contains "$output" "0.002" "known cost from the priced row appears in the total"
}

run_tests
