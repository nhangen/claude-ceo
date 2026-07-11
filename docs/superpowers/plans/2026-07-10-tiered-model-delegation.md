# Tiered Model Delegation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically route simple/cheap CEO subtasks to a cheaper model tier (haiku, sometimes sonnet) via a rule-based allowlist, log every routing decision to a shared ledger, and report counterfactual savings unified across the ollama tier and the new cloud tiers.

**Architecture:** One shared allowlist (`ceo-tier-map.json`) and matching lib (`ceo-tier-lib.sh`) consulted from two call sites — `ceo-cron.sh`'s own MODEL resolution (for scheduled playbooks) and a new PreToolUse hook (for interactive-session Agent/Task dispatches). Both write to the same JSONL ledger `ollama-agent` already uses, via a new shared writer (`ceo-model-ledger.sh`) that guarantees non-colliding `run_id`s. A new report script aggregates that one ledger across every tier.

**Tech Stack:** Bash, `jq`, the existing `ollama-agent` Python ledger (untouched, read-compatible), Claude Code hooks (`PreToolUse`), `claude --print --output-format json`.

## Global Constraints

- Ledger file stays a single shared JSONL file at the path `ollama_agent/ollama_agent/ledger.py`'s `ledger_path()` already resolves to (`OLLAMA_AGENT_LEDGER` env override, else `${XDG_STATE_HOME:-$HOME/.local/state}/ollama-agent/runs.jsonl`) — do not introduce a second ledger file.
- `run_id`s for every new writer are `<writer-type>-<uuid>`, never timestamp-based, so they can't collide with `ceo-ollama-batch`'s caller-controlled `<batch-id>-<n>` run_ids.
- Routing is an allowlist match, never an LLM judgment call — a task shape not present in `ceo-tier-map.json` always runs at its originally-requested/default model.
- Every downgrade decision is logged to the ledger — no silent routing.
- An explicit `CEO_MODEL_OVERRIDE` (existing dry-run/test override) or a new `CEO_TIER_ROUTER_DISABLE=1` always wins over a tier-map match — the mechanism must be able to turn itself off.
- Any script that reads the ledger uses `jq` per-line filtering, never `grep` on the raw JSON text — `jq -c` (this plan's writer) and Python's `json.dumps` (the existing ollama-agent writer) format whitespace around `:` differently, so a hardcoded grep pattern is not portable across writers.

---

### Task 1: Tier allowlist config + matching lib

**Files:**
- Create: `scripts/ceo-tier-map.json`
- Create: `scripts/ceo-tier-lib.sh`
- Test: `scripts/ceo-tier-lib.test.sh`

**Interfaces:**
- Produces: `ceo_tier_lookup <label> <subagent_type>` — prints `"<tier>|<shape_name>"` on the first matching allowlist entry, prints nothing (empty stdout, exit 0) on no match or any failure (missing map file, missing `jq`). Never exits non-zero — a broken map must never block a real dispatch.
- Produces: `ceo_tier_map_path` — prints the resolved map path (`CEO_TIER_MAP` env override, else the sibling `ceo-tier-map.json`).

- [ ] **Step 1: Write the failing test file**

Create `scripts/ceo-tier-lib.test.sh`:

```bash
#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-tier-lib.sh"

setup() {
  CEO_TIER_MAP="$(mktemp)"
  export CEO_TIER_MAP
  cat > "$CEO_TIER_MAP" <<'JSON'
{
  "shapes": [
    {"name": "read-only-lookup", "match_pattern": "^(find|locate)\\b", "allowed_subagent_types": ["general-purpose"], "tier": "haiku"}
  ]
}
JSON
}

teardown() {
  rm -f "$CEO_TIER_MAP"
}

test_match_returns_tier_and_shape() {
  local result
  result=$(ceo_tier_lookup "find the config file" "general-purpose")
  assert_eq "$result" "haiku|read-only-lookup" "matching label+subagent_type returns tier|shape"
}

test_no_match_on_unmatched_label() {
  local result
  result=$(ceo_tier_lookup "refactor the billing module" "general-purpose")
  assert_eq "$result" "" "unmatched label returns empty"
}

test_no_match_on_wrong_subagent_type() {
  local result
  result=$(ceo_tier_lookup "find the config file" "code-reviewer")
  assert_eq "$result" "" "subagent_type not in allowlist returns empty"
}

test_missing_map_file_fails_open() {
  CEO_TIER_MAP="/tmp/ceo-tier-map-does-not-exist-$$.json"
  local result
  result=$(ceo_tier_lookup "find the config file" "general-purpose")
  assert_eq "$result" "" "missing map file returns empty, not an error"
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-tier-lib.test.sh`
Expected: FAIL — `ceo-tier-lib.sh: No such file or directory` (nothing to source yet).

- [ ] **Step 3: Write `ceo-tier-map.json`**

Create `scripts/ceo-tier-map.json`:

```json
{
  "_comment": "Allowlist of pre-approved task shapes eligible for automatic downgrade to a cheaper model. A dispatch matches ONLY if its subagent_type is in allowed_subagent_types AND its label (a CEO playbook trigger name, or an Agent-tool description) matches match_pattern (case-insensitive regex). No match means no downgrade. This is a human-curated allowlist, not a classifier — add a shape only after reviewing that the task class is safe to run on the listed tier.",
  "shapes": [
    {
      "name": "read-only-lookup",
      "match_pattern": "^(find|locate|check|look ?up)\\b",
      "allowed_subagent_types": ["general-purpose", "Explore"],
      "tier": "haiku"
    }
  ]
}
```

- [ ] **Step 4: Write `ceo-tier-lib.sh`**

Create `scripts/ceo-tier-lib.sh`:

```bash
#!/usr/bin/env bash
# ceo-tier-lib.sh — shared task-shape -> cheaper-tier lookup.
# Sourced by ceo-cron.sh and the ceo-tier-router PreToolUse hook. Pure
# lookup, no side effects; every function fails open (empty result) rather
# than raising, so a broken map can never block a real dispatch.

CEO_TIER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ceo_tier_map_path() {
  echo "${CEO_TIER_MAP:-$CEO_TIER_LIB_DIR/ceo-tier-map.json}"
}

# ceo_tier_lookup <label> <subagent_type>
# <label> is the short caller-supplied string matched against each shape's
# match_pattern: a CEO playbook trigger name, or an Agent-tool `description`.
ceo_tier_lookup() {
  local label="$1" subagent_type="$2"
  local map_path
  map_path="$(ceo_tier_map_path)"
  [ -f "$map_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg label "$label" --arg st "$subagent_type" '
    .shapes[]?
    | select((.allowed_subagent_types // []) | index($st) != null)
    | select($label | test(.match_pattern; "i"))
    | "\(.tier)|\(.name)"
  ' "$map_path" 2>/dev/null | head -1
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash scripts/ceo-tier-lib.test.sh`
Expected: `All tests passed. (4 tests)`

- [ ] **Step 6: Commit**

```bash
git add scripts/ceo-tier-map.json scripts/ceo-tier-lib.sh scripts/ceo-tier-lib.test.sh
git commit -m "Add tier allowlist and matching lib for cheaper-model routing"
```

---

### Task 2: Shared ledger writer

**Files:**
- Create: `scripts/ceo-model-ledger.sh`
- Test: `scripts/ceo-model-ledger.test.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `ceo_ledger_path` — prints the resolved ledger file path (same resolution `ollama_agent/ollama_agent/ledger.py:ledger_path()` uses).
- Produces: `ceo_ledger_write_entry <writer> <model> <task_name> <cwd> [cost_usd] [completed]` — appends one JSON line, prints the generated `run_id` on stdout. `cost_usd` defaults to `null`, `completed` defaults to `null`; both are inserted as raw JSON literals (pass `true`/`false`/a bare number/`null`, not a quoted string).

- [ ] **Step 1: Write the failing test file**

Create `scripts/ceo-model-ledger.test.sh`:

```bash
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
  local last_line
  last_line=$(tail -1 "$OLLAMA_AGENT_LEDGER")
  assert_fails "last line must not be valid JSON when this test intentionally breaks it" bash -c "! echo '$last_line' | jq -e . >/dev/null 2>&1"
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

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-model-ledger.test.sh`
Expected: FAIL — `ceo-model-ledger.sh: No such file or directory`.

- [ ] **Step 3: Write `ceo-model-ledger.sh`**

Create `scripts/ceo-model-ledger.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-model-ledger.test.sh`
Expected: `All tests passed. (4 tests)`

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-model-ledger.sh scripts/ceo-model-ledger.test.sh
git commit -m "Add shared ledger writer for cheaper-tier dispatch tracking"
```

---

### Task 3: Wire `ceo-cron.sh` to route and log runner:claude playbooks

**Files:**
- Modify: `scripts/ceo-cron.sh:149-153` (source the new libs)
- Modify: `scripts/ceo-cron.sh:1823-1847` (read-tier MODEL resolution + dispatch)
- Modify: `scripts/ceo-cron.sh:1850-1854` (three-phase pipeline MODEL resolution)
- Test: `scripts/ceo-cron-tier-routing.test.sh`

**Interfaces:**
- Consumes: `ceo_tier_lookup` (Task 1), `ceo_ledger_write_entry` (Task 2).
- Produces: nothing new for later tasks — this task is a leaf consumer.

Scope note (stated, not hidden): this task instruments live cost capture (`total_cost_usd` from `claude --print --output-format json`) for the **read-tier single-call path only** (line ~1830). The three-phase pipeline (PLAN/EXEC, ~1904/~2010) gets the same tier-map routing (so cost control applies there too) but its cost is logged as `cost_usd: null` for now — wiring `--output-format json` through three chained calls with intermediate parsing is a separate follow-up, not required to make routing itself automatic and logged.

- [ ] **Step 1: Discover the actual `--output-format json` usage schema**

Run this once, by hand, to see the real field names before writing code against them (the CLI's `usage` sub-schema isn't documented):

```bash
echo "Reply with exactly the word OK." | claude --print --max-turns 1 --model haiku --output-format json | jq '.'
```

Expected: a JSON object containing at least `total_cost_usd` (a float) and `session_id`. Note the exact top-level keys returned — Step 3 below uses `total_cost_usd` directly since it's confirmed by the CLI docs; if the live output differs, adjust Step 3's `jq` filter to match what you actually see before proceeding.

- [ ] **Step 2: Write the failing test file**

Create `scripts/ceo-cron-tier-routing.test.sh`:

```bash
#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/ceo-tier-lib.sh"
source "$SCRIPT_DIR/ceo-model-ledger.sh"

setup() {
  CEO_TIER_MAP="$(mktemp)"
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export CEO_TIER_MAP OLLAMA_AGENT_LEDGER
  cat > "$CEO_TIER_MAP" <<'JSON'
{
  "shapes": [
    {"name": "read-only-lookup", "match_pattern": "^(find|locate)\\b", "allowed_subagent_types": ["general-purpose"], "tier": "haiku"}
  ]
}
JSON
}

teardown() {
  rm -f "$CEO_TIER_MAP" "$OLLAMA_AGENT_LEDGER"
}

# Simulates the resolution block ceo-cron.sh runs before dispatching a
# runner:claude playbook, isolated from the rest of the (very large) script.
_resolve_model_for_playbook() {
  local trigger="$1"
  local model="${MODEL:-sonnet}"
  if [ -z "${CEO_MODEL_OVERRIDE:-}" ] && [ -z "${CEO_TIER_ROUTER_DISABLE:-}" ]; then
    local match
    match=$(ceo_tier_lookup "$trigger" "general-purpose")
    if [ -n "$match" ]; then
      model="${match%%|*}"
      ceo_ledger_write_entry "claude-tier" "$model" "$trigger" "$(pwd)" "null" "null" > /dev/null
    fi
  fi
  [ -n "${CEO_MODEL_OVERRIDE:-}" ] && model="$CEO_MODEL_OVERRIDE"
  echo "$model"
}

test_matching_trigger_downgrades_and_logs() {
  local model
  model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "haiku" "matching trigger resolves to the allowlisted tier"
  local logged
  logged=$(jq -c --arg tn "find-stale-branches" 'select(.task_name == $tn)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "1" "the downgrade decision is logged to the ledger"
}

test_non_matching_trigger_keeps_default() {
  local model
  model=$(_resolve_model_for_playbook "reconcile-billing")
  assert_eq "$model" "sonnet" "non-matching trigger keeps the default model"
  local logged
  logged=$(jq -c --arg tn "reconcile-billing" 'select(.task_name == $tn)' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "0" "no ledger entry when nothing was downgraded"
}

test_ceo_model_override_wins_over_tier_map() {
  local model
  CEO_MODEL_OVERRIDE="opus" model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "opus" "CEO_MODEL_OVERRIDE beats a tier-map match"
}

test_disable_flag_skips_tier_map() {
  local model
  CEO_TIER_ROUTER_DISABLE="1" model=$(_resolve_model_for_playbook "find-stale-branches")
  assert_eq "$model" "sonnet" "CEO_TIER_ROUTER_DISABLE skips the tier-map lookup entirely"
}

run_tests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash scripts/ceo-cron-tier-routing.test.sh`
Expected: PASS on `test_matching_trigger_downgrades_and_logs`'s first assertion is impossible yet since `_resolve_model_for_playbook` already contains the target logic inline in the test — this test file is verifying the *behavior contract* the real `ceo-cron.sh` edit must match, not `ceo-cron.sh` itself (editing an 1800+ line production script under a bite-sized TDD cycle isn't practical). Confirm instead that it fails for the right reason before the libs exist: temporarily comment out the `source` lines for `ceo-tier-lib.sh` / `ceo-model-ledger.sh` — expect `command not found: ceo_tier_lookup`. Restore the `source` lines once confirmed.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-cron-tier-routing.test.sh`
Expected: `All tests passed. (4 tests)`

- [ ] **Step 5: Apply the same resolution logic to `scripts/ceo-cron.sh`**

At line 149-153, add the two new `source` lines:

```bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/ceo-cron-lib.sh"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"
# shellcheck source=ceo-tier-lib.sh
source "$SCRIPT_DIR/ceo-tier-lib.sh"
# shellcheck source=ceo-model-ledger.sh
source "$SCRIPT_DIR/ceo-model-ledger.sh"
```

At line 1823-1824 (read-tier), replace:

```bash
  MODEL="${MODEL:-sonnet}"
  [ -n "${CEO_MODEL_OVERRIDE:-}" ] && MODEL="$CEO_MODEL_OVERRIDE"
```

with:

```bash
  MODEL="${MODEL:-sonnet}"
  if [ -z "${CEO_MODEL_OVERRIDE:-}" ] && [ -z "${CEO_TIER_ROUTER_DISABLE:-}" ]; then
    _TIER_MATCH="$(ceo_tier_lookup "$TRIGGER" "general-purpose")"
    if [ -n "$_TIER_MATCH" ]; then
      MODEL="${_TIER_MATCH%%|*}"
      ceo_ledger_write_entry "claude-tier" "$MODEL" "$TRIGGER" "$VAULT" "null" "null" > /dev/null
    fi
  fi
  [ -n "${CEO_MODEL_OVERRIDE:-}" ] && MODEL="$CEO_MODEL_OVERRIDE"
```

At line 1850-1852 (three-phase pipeline), replace:

```bash
MODEL="${MODEL:-sonnet}"
[ -n "${CEO_MODEL_OVERRIDE:-}" ] && MODEL="$CEO_MODEL_OVERRIDE"
```

with the identical block (same shape, top-level scope for the pipeline path):

```bash
MODEL="${MODEL:-sonnet}"
if [ -z "${CEO_MODEL_OVERRIDE:-}" ] && [ -z "${CEO_TIER_ROUTER_DISABLE:-}" ]; then
  _TIER_MATCH="$(ceo_tier_lookup "$TRIGGER" "general-purpose")"
  if [ -n "$_TIER_MATCH" ]; then
    MODEL="${_TIER_MATCH%%|*}"
    ceo_ledger_write_entry "claude-tier" "$MODEL" "$TRIGGER" "$VAULT" "null" "null" > /dev/null
  fi
fi
[ -n "${CEO_MODEL_OVERRIDE:-}" ] && MODEL="$CEO_MODEL_OVERRIDE"
```

- [ ] **Step 6: Capture live cost for the read-tier path**

At line ~1830, replace the read-tier dispatch:

```bash
  SINGLE_EXIT=0
  SINGLE_OUTPUT=$(cd "$VAULT" && echo "$SINGLE_PROMPT" | CLAUDE_MEM_INTERNAL=1 $(_with_timeout 300) claude --print --max-turns 5 \
    --model "$MODEL" --disallowedTools "Bash,Write,Edit" 2>>"$LOG_DIR/cron-stderr.log") || SINGLE_EXIT=$?
```

with a version that also captures cost, using the field confirmed in Step 1:

```bash
  SINGLE_EXIT=0
  SINGLE_RAW=$(cd "$VAULT" && echo "$SINGLE_PROMPT" | CLAUDE_MEM_INTERNAL=1 $(_with_timeout 300) claude --print --max-turns 5 \
    --model "$MODEL" --disallowedTools "Bash,Write,Edit" --output-format json 2>>"$LOG_DIR/cron-stderr.log") || SINGLE_EXIT=$?
  SINGLE_OUTPUT="$(printf '%s' "$SINGLE_RAW" | jq -r '.result // empty' 2>/dev/null)"
  SINGLE_COST="$(printf '%s' "$SINGLE_RAW" | jq -r '.total_cost_usd // "null"' 2>/dev/null)"
  if [ -n "${_TIER_MATCH:-}" ]; then
    ceo_ledger_write_entry "claude-tier" "$MODEL" "$TRIGGER" "$VAULT" "${SINGLE_COST:-null}" "true" > /dev/null
  fi
```

Note: this replaces the earlier no-cost ledger write at Step 5 for the read-tier path specifically — the read-tier block now logs once, after the call completes, with real cost. If `$SINGLE_OUTPUT` is empty because `--output-format json` changed the shape unexpectedly, `_dispatch_single_output` downstream will surface it as an empty-output failure (existing error path at line ~1813) rather than silently losing the playbook's actual output.

- [ ] **Step 7: Run the full existing `ceo-cron.sh` test suite**

Run: `bash scripts/ceo-cron.test.sh`
Expected: `All tests passed.` — confirms the edit didn't regress existing dispatch behavior. If this file stubs `claude` as an external command, verify the stub still matches argv after adding `--output-format json` (per `stub-cli-argv-validation` — a stub that ignores `$@` won't catch a malformed call).

- [ ] **Step 8: Commit**

```bash
git add scripts/ceo-cron.sh scripts/ceo-cron-tier-routing.test.sh
git commit -m "Route runner:claude playbooks through the tier allowlist, log decisions to the ledger"
```

---

### Task 4: PreToolUse hook for interactive Agent/Task dispatches

**Files:**
- Create: `hooks/ceo-tier-router.sh`
- Modify: `~/.claude/settings.json` (register the hook — outside this repo, done by hand per the install note below)
- Test: `hooks/ceo-tier-router.test.sh`

**Interfaces:**
- Consumes: `ceo_tier_lookup`, `ceo_tier_map_path` (Task 1); `ceo_ledger_write_entry` (Task 2).
- Produces: nothing for later tasks — this is the interactive-session enforcement point; Task 5 reads the ledger it writes to, not this hook directly.

- [ ] **Step 1: Discover the real `tool_input` shape for a Task dispatch**

The exact key names Claude Code sends for a Task/Agent tool call beyond `subagent_type` aren't in the public docs. Confirm them once, live, before writing the matching hook:

```bash
mkdir -p hooks
cat > /tmp/ceo-tier-router-discover.sh <<'EOF'
#!/usr/bin/env bash
cat >> /tmp/ceo-tier-router-discovery.jsonl
cat <<'JSON'
{}
JSON
EOF
chmod +x /tmp/ceo-tier-router-discover.sh
```

Temporarily add this to `~/.claude/settings.json` under `hooks.PreToolUse` with `"matcher": "Task"`, dispatch one real `Agent` tool call in this session (any small subagent task), then inspect:

```bash
tail -1 /tmp/ceo-tier-router-discovery.jsonl | jq '.tool_input'
```

Note the actual keys present (expect `subagent_type` confirmed; check whether `description`, `prompt`, and `model` are present under those exact names). Remove the temporary hook entry from `settings.json` afterward. Use the confirmed key names in Step 3 below — if `description` is absent, fall back to matching against `prompt` instead.

- [ ] **Step 2: Write the failing test file**

Create `hooks/ceo-tier-router.test.sh`:

```bash
#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/test-harness.sh"

setup() {
  CEO_TIER_MAP="$(mktemp)"
  OLLAMA_AGENT_LEDGER="$(mktemp)"
  export CEO_TIER_MAP OLLAMA_AGENT_LEDGER
  cat > "$CEO_TIER_MAP" <<'JSON'
{
  "shapes": [
    {"name": "read-only-lookup", "match_pattern": "^(find|locate)\\b", "allowed_subagent_types": ["general-purpose"], "tier": "haiku"}
  ]
}
JSON
}

teardown() {
  rm -f "$CEO_TIER_MAP" "$OLLAMA_AGENT_LEDGER"
}

test_matching_dispatch_gets_updated_input() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  local decision model
  decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  model=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.model')
  assert_eq "$decision" "allow" "matching dispatch is allowed through"
  assert_eq "$model" "haiku" "matching dispatch gets model overridden to the allowlisted tier"
}

test_non_matching_dispatch_passes_through_unmodified() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "refactor the billing module"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  assert_eq "$output" "" "no match means no hook output at all — the dispatch runs unmodified"
}

test_non_task_tool_is_ignored() {
  local input output
  input='{"tool_name": "Bash", "tool_input": {"command": "find . -name find"}}'
  output=$(printf '%s' "$input" | bash "$SCRIPT_DIR/ceo-tier-router.sh")
  assert_eq "$output" "" "non-Task tool calls are never touched by this hook"
}

test_matching_dispatch_logs_to_ledger() {
  printf '%s' '{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}' \
    | bash "$SCRIPT_DIR/ceo-tier-router.sh" > /dev/null
  local logged
  logged=$(jq -c 'select(.writer == "interactive-tier")' "$OLLAMA_AGENT_LEDGER" | wc -l | tr -d ' ')
  assert_eq "$logged" "1" "the downgrade decision is logged to the ledger"
}

test_disable_flag_short_circuits() {
  local input output
  input='{"tool_name": "Task", "tool_input": {"subagent_type": "general-purpose", "description": "find the config file"}}'
  output=$(CEO_TIER_ROUTER_DISABLE=1 bash -c "printf '%s' '$input' | bash '$SCRIPT_DIR/ceo-tier-router.sh'")
  assert_eq "$output" "" "CEO_TIER_ROUTER_DISABLE=1 skips the hook entirely"
}

run_tests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash hooks/ceo-tier-router.test.sh`
Expected: FAIL — `ceo-tier-router.sh: No such file or directory`.

- [ ] **Step 4: Write `hooks/ceo-tier-router.sh`**

Create `hooks/ceo-tier-router.sh` (adjust the `description`/`prompt` key per what Step 1 confirmed — this uses `description` with a `prompt` fallback):

```bash
#!/usr/bin/env bash
# ceo-tier-router.sh — PreToolUse hook. Enforces automatic downgrade-to-
# cheaper-tier for Task/Agent dispatches whose shape matches
# scripts/ceo-tier-map.json. This is the single choke point for interactive-
# session routing — see docs/superpowers/specs/2026-07-10-tiered-model-delegation-design.md.
set -euo pipefail

if [ -n "${CEO_TIER_ROUTER_DISABLE:-}" ]; then
  exit 0
fi

REPO_ROOT="/Users/nhangen/code/claude-ceo"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/ceo-tier-lib.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/ceo-model-ledger.sh"

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""')"

if [ "$tool_name" != "Task" ] && [ "$tool_name" != "Agent" ]; then
  exit 0
fi

subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')"
label="$(printf '%s' "$input" | jq -r '.tool_input.description // .tool_input.prompt // ""' | head -c 200)"

[ -n "$label" ] || exit 0

match="$(ceo_tier_lookup "$label" "$subagent_type")"
[ -n "$match" ] || exit 0

tier="${match%%|*}"
shape="${match##*|}"

ceo_ledger_write_entry "interactive-tier" "$tier" "$shape" "$(pwd)" "null" "null" > /dev/null

jq -nc --arg tier "$tier" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { model: $tier }
  }
}'
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash hooks/ceo-tier-router.test.sh`
Expected: `All tests passed. (5 tests)`

- [ ] **Step 6: Commit**

```bash
git add hooks/ceo-tier-router.sh hooks/ceo-tier-router.test.sh
git commit -m "Add PreToolUse hook to route interactive Agent/Task dispatches through the tier allowlist"
```

- [ ] **Step 7: Install note (manual, outside the repo)**

This step is not committed to the repo (`~/.claude/settings.json` is user-global config, not a project file). To activate the hook, add to `~/.claude/settings.json` under `hooks.PreToolUse`:

```json
{
  "matcher": "Task|Agent",
  "hooks": [
    { "type": "command", "command": "/Users/nhangen/code/claude-ceo/hooks/ceo-tier-router.sh" }
  ]
}
```

Verify activation by dispatching one real Agent call with a `description` matching an allowlisted shape (e.g. "find the config file") and confirming in the transcript that it ran on the overridden tier, and that a new `interactive-tier-*` row landed in the ledger (`tail -1 ~/.local/state/ollama-agent/runs.jsonl`).

---

### Task 5: Unified savings report

**Files:**
- Create: `scripts/ceo-savings-report.sh`
- Test: `scripts/ceo-savings-report.test.sh`

**Interfaces:**
- Consumes: the shared ledger written by `ollama_agent/ollama_agent/ledger.py`, `ceo-model-ledger.sh`'s `ceo_ledger_write_entry` (Task 2), and the hook (Task 4).
- Produces: nothing further downstream — this is the terminal reporting script, invoked directly by the user (`bash scripts/ceo-savings-report.sh`).

Scope note: this reports counts, tiers, and known costs from the ledger as written. It does not compute a hypothetical "what if this had run on Opus instead" dollar figure for the `cost_usd: null` rows Task 3's pipeline path currently logs — those rows are reported as an explicit `unpriced` count in the breakdown rather than papered over with a guessed number, consistent with `ceo-ollama-batch`'s existing "measured, not guessed" convention.

- [ ] **Step 1: Write the failing test file**

Create `scripts/ceo-savings-report.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-savings-report.test.sh`
Expected: FAIL — `ceo-savings-report.sh: No such file or directory`.

- [ ] **Step 3: Write `ceo-savings-report.sh`**

Create `scripts/ceo-savings-report.sh`:

```bash
#!/usr/bin/env bash
# ceo-savings-report.sh — unified per-tier breakdown across the shared ledger
# (ollama-agent rows + claude-tier/interactive-tier rows). Additive to
# ceo-ollama-batch's existing per-batch `token-scope --savings` calls; this
# reports counts and known costs from the ledger, never a guessed dollar
# figure for rows with no recorded cost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ceo-model-ledger.sh
source "$SCRIPT_DIR/ceo-model-ledger.sh"

LEDGER="$(ceo_ledger_path)"

if [ ! -f "$LEDGER" ]; then
  echo "No ledger found at $LEDGER — nothing to report."
  exit 0
fi

echo "=== Per-tier row counts ==="
jq -rs '
  map(.model // "unknown")
  | group_by(.)
  | map({model: .[0], count: length})
  | sort_by(.model)
  | .[]
  | "\(.model): \(.count)"
' "$LEDGER" | sed 's/gpt-oss:20b/ollama/'

echo ""
echo "=== Cost known vs unpriced ==="
UNPRICED=$(jq -rs 'map(select(.cost_usd == null and (.ollama_input_tokens | not))) | length' "$LEDGER")
echo "unpriced: $UNPRICED"

echo ""
echo "=== Known cost total (claude-tier / interactive-tier rows) ==="
jq -rs '
  map(select(.cost_usd != null))
  | map(.cost_usd)
  | add // 0
' "$LEDGER"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-savings-report.test.sh`
Expected: `All tests passed. (3 tests)`

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-savings-report.sh scripts/ceo-savings-report.test.sh
git commit -m "Add unified per-tier savings report across ollama and cloud tiers"
```

---

## Self-Review Notes

- **Spec coverage:** Component 1 (allowlist) → Task 1. Component 2 (hook) → Task 4. Component 3 (shared writer) → Task 2. Component 4 (unified report) → Task 5. Component "wire it into ceo-cron.sh" (implicit in the spec's data-flow section) → Task 3.
- **Disclosed scope cuts (not gaps hidden as done):** live cost capture for the three-phase pipeline path (Task 3) and a real dollar-value counterfactual for unpriced rows (Task 5) are both explicitly deferred, not silently skipped.
- **Type/name consistency:** `ceo_tier_lookup`, `ceo_ledger_write_entry`, `ceo_ledger_path` are defined once (Tasks 1–2) and used with the same signatures in Tasks 3–5. `writer` values (`"claude-tier"`, `"interactive-tier"`) are consistent between Task 3 and Task 4 and asserted on directly in Task 5's test fixture.
