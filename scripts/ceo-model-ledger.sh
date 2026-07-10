#!/usr/bin/env bash
# ceo-model-ledger.sh — shared JSONL ledger writer for cheaper-tier dispatches.
# Writes to the SAME file ollama_agent/ollama_agent/ledger.py uses, so
# ceo-savings-report.sh has one file to read across every tier. run_ids are
# <writer>-<uuid> so they can never collide with ollama-agent's own
# caller-controlled run_ids, preserving ceo-ollama-batch's run-id-scoped reads.

ceo_ledger_path() {
  if [ -n "${OLLAMA_AGENT_LEDGER:-}" ]; then
    echo "$OLLAMA_AGENT_LEDGER"
    return
  fi
  local base="${XDG_STATE_HOME:-$HOME/.local/state}"
  echo "$base/ollama-agent/runs.jsonl"
}

ceo_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM"
  fi
}

# ceo_ledger_write_entry <writer> <model> <task_name> <cwd> [cost_usd] [completed]
# Best-effort: a write failure never raises or exits non-zero, matching
# ollama_agent.ledger.append_run's "never fail the caller" contract.
ceo_ledger_write_entry() {
  local writer="$1" model="$2" task_name="$3" cwd="$4"
  local cost_usd="${5:-null}" completed="${6:-null}"
  local path run_id ts session_id
  path="$(ceo_ledger_path)"
  run_id="${writer}-$(ceo_uuid)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

  mkdir -p "$(dirname "$path")" 2>/dev/null
  jq -nc \
    --arg ts "$ts" --arg run_id "$run_id" --arg session_id "$session_id" \
    --arg writer "$writer" --arg model "$model" --arg task_name "$task_name" --arg cwd "$cwd" \
    --argjson cost_usd "$cost_usd" --argjson completed "$completed" \
    '{ts: $ts, run_id: $run_id, session_id: (if $session_id == "" then null else $session_id end),
      writer: $writer, model: $model, task_name: $task_name, cwd: $cwd,
      cost_usd: $cost_usd, completed: $completed}' \
    >> "$path" 2>/dev/null

  echo "$run_id"
}
