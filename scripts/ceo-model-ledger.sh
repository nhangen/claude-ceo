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

# Echo <value> when it is exactly one JSON value passing <jq-test>, else `null`
# with a note on stderr. One malformed --argjson makes jq refuse the whole
# object, so each value is checked on its own: a bad field costs that field,
# never the row (#490).
_ceo_ledger_json_or_null() { # <field> <value> <jq-test>
  if jq -en --argjson v "$2" "\$v | ($3)" >/dev/null 2>&1; then
    printf '%s' "$2"
  else
    printf 'ceo-model-ledger: %s is not valid JSON of the expected type (%q); recording null\n' "$1" "$2" >&2
    printf 'null'
  fi
}

# ceo_ledger_write_entry <writer> <model> <task_name> <cwd> [cost_usd] [completed]
#                        [verified] [verify_gated] [verify_cmd]
# The verify args default to null — "no opinion" — which is right for the
# ungated claude-tier and interactive-tier writers. A gated caller (ceo-loop)
# passes its real gate (#491). verify_cmd is a plain string, JSON-encoded here.
# Best-effort: a write failure never raises or exits non-zero, matching
# ollama_agent.ledger.append_run's "never fail the caller" contract — but it is
# reported on stderr, since every caller discards stdout (#490).
ceo_ledger_write_entry() {
  local writer="$1" model="$2" task_name="$3" cwd="$4"
  local cost_usd completed verified verify_gated verify_cmd='null'
  cost_usd="$(_ceo_ledger_json_or_null cost_usd "${5:-null}" 'type == "number" or . == null')"
  completed="$(_ceo_ledger_json_or_null completed "${6:-null}" 'type == "boolean" or . == null')"
  verified="$(_ceo_ledger_json_or_null verified "${7:-null}" 'type == "boolean" or . == null')"
  verify_gated="$(_ceo_ledger_json_or_null verify_gated "${8:-null}" 'type == "boolean" or . == null')"
  [ "$#" -ge 9 ] && verify_cmd="$(jq -n --arg v "$9" '$v' 2>/dev/null || echo null)"
  # Not `path`: in zsh that name is tied to PATH, so a `local path` there empties
  # the command search path and every tool below becomes "command not found".
  local ledger_path run_id ts session_id
  ledger_path="$(ceo_ledger_path)"
  run_id="${writer}-$(ceo_uuid)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

  mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || true
  # 2>/dev/null precedes >>, so a redirection failure is silenced too and this
  # message is the only one — rather than the shell's bare "No such file".
  if ! jq -nc \
    --arg ts "$ts" --arg run_id "$run_id" --arg session_id "$session_id" \
    --arg writer "$writer" --arg model "$model" --arg task_name "$task_name" --arg cwd "$cwd" \
    --argjson cost_usd "$cost_usd" --argjson completed "$completed" \
    --argjson verified "$verified" --argjson verify_gated "$verify_gated" \
    --argjson verify_cmd "$verify_cmd" \
    '{ts: $ts, run_id: $run_id, session_id: (if $session_id == "" then null else $session_id end),
      writer: $writer, model: $model, task_name: $task_name, cwd: $cwd,
      cost_usd: $cost_usd, completed: $completed,
      verified: $verified, verify_gated: $verify_gated, verify_cmd: $verify_cmd}' \
    2>/dev/null >> "$ledger_path"; then
    echo "ceo-model-ledger: append to $ledger_path failed (writer=$writer task=$task_name)" >&2
  fi

  echo "$run_id"
}
