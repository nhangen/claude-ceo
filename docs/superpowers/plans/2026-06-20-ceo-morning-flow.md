# CEO Morning Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the disconnected morning playbooks with one orchestrated flow that produces a single Discord briefing ranked by real per-domain signals (sprint, not age) and starts a positives-only model-of-Nathan learning ledger.

**Architecture:** Shell pre-gather (`ceo-gather.sh`) collects a new current-sprint signal + yesterday's observable actions + the recent ledger; one read-tier synthesis playbook (`morning`) consumes them and emits the briefing plus a machine-readable predicted-priorities block; a shell observe step (`ceo-observe.sh`) scores yesterday's prediction hit-rate and appends a discretion-scrubbed ledger entry. The four legacy morning playbooks are disabled (not deleted) for one cutover cycle.

**Tech Stack:** Bash (custom test harness `scripts/test-harness.sh`), `jq`, `gh`, `git`, Zenhub GraphQL via `curl`, Claude/ollama runner. Spec: `docs/superpowers/specs/2026-06-20-ceo-morning-flow-design.md`.

## Global Constraints

- Gather is shell / model-free; only the synthesis phase is an LLM run.
- Ship **two domains only** in v1: Awesome Motive (Zenhub current sprint) + Personal (daily-note Top 3). No pluggable resolver framework.
- **Acceptance criterion:** for AM, sprint membership is the primary priority key — a sprint-member PR outranks an older non-sprint PR.
- **Ledger is positives-only:** record observable actions (merged/committed/closed); never infer "deprioritized" from absence.
- Ledger lives in the **synced** vault (`CEO/model/YYYY-MM.md`) and is **discretion-bound** per `Profile/discretion.md` — patterns only, never employer/Altamira specifics.
- Synthesis must degrade across models (sonnet → ollama) and **fall back to a raw digest** if the LLM run fails — never deliver nothing.
- Credentials sourced from `~/.config/ceo/credentials.env` (`ZENHUB_TOKEN`, `ZENHUB_WORKSPACE_ID`). Validate presence; missing → graceful skip of the sprint signal, not a crash.
- Tests: custom bash harness; each `scripts/*.test.sh` sources `test-harness.sh`, defines `setup`/`teardown` + `test_*` functions, runs via `bash scripts/<name>.test.sh`. Stub external CLIs (`gh`, `git`, `curl`) with argv validation (exit non-zero on unexpected shape).
- Cutover (registry scan, enabling/disabling playbooks) is an **ML-1-only** action (`ceo-scan-only-on-ml1`). The flow writes to the synced vault → register it in the registry as an automated writer (`ceo-automated-writers-are-playbooks`).
- Shell: `: "${VAR:?msg}"` for required env (`shell-required-env-vars`); validate enum-ish fields, no silent default-on-typo (`enum-config-typo-fallback`).

---

### Task 1: Zenhub current-sprint shell helper

**Files:**
- Create: `scripts/ceo-zenhub-sprint.sh`
- Test: `scripts/ceo-zenhub-sprint.test.sh`

**Interfaces:**
- Consumes: env `ZENHUB_TOKEN`, `ZENHUB_WORKSPACE_ID` (from `~/.config/ceo/credentials.env`, sourced by caller).
- Produces: prints to stdout a JSON array `[{ "number": <int>, "repo": "<owner/name>", "title": "<str>" }, ...]` of issues/PRs in the **current** sprint; prints `[]` and exits 0 when creds missing or the API fails (degrade, never crash). Exit 0 always after arg validation.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-zenhub-sprint.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
HELPER="$SCRIPT_DIR/ceo-zenhub-sprint.sh"

setup() {
  TMP=$(mktemp -d)
  STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
  # curl stub: validates it's a POST to the zenhub graphql endpoint with auth,
  # returns a canned current-sprint payload.
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"api.zenhub.com/public/graphql"*) : ;;
  *) echo "stub curl: unexpected args: $args" >&2; exit 99 ;;
esac
case "$args" in
  *"Authorization"*|*"-H"*) : ;;
  *) echo "stub curl: missing auth header" >&2; exit 99 ;;
esac
cat <<'JSON'
{"data":{"workspace":{"sprints":{"nodes":[{"state":"OPEN","issues":{"nodes":[
{"number":42,"title":"Sprint task A","repository":{"ownerName":"awesomemotive","name":"optin-monster-app"}}
]}}]}}}}
JSON
STUB
  chmod +x "$STUB_BIN/curl"
  export PATH="$STUB_BIN:$PATH"
  export ZENHUB_TOKEN="test-token"
  export ZENHUB_WORKSPACE_ID="ws_test"
}
teardown() { rm -rf "$TMP"; unset ZENHUB_TOKEN ZENHUB_WORKSPACE_ID; }

test_emits_current_sprint_issues() {
  setup
  out=$(bash "$HELPER")
  assert_contains "$out" '"number": 42' "sprint issue number present"
  assert_contains "$out" 'optin-monster-app' "repo present"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_degrades_to_empty_array_when_token_missing() {
  setup
  unset ZENHUB_TOKEN
  out=$(bash "$HELPER"); rc=$?
  assert_eq "$rc" "0" "exit 0 when token missing"
  assert_eq "$out" "[]" "empty array when token missing"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-zenhub-sprint.test.sh`
Expected: FAIL — helper does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/ceo-zenhub-sprint.sh
#!/usr/bin/env bash
# Print current-sprint issues as a JSON array, or [] on any failure. Never crashes.
set -uo pipefail

emit_empty() { echo "[]"; exit 0; }

[ -n "${ZENHUB_TOKEN:-}" ] || emit_empty
[ -n "${ZENHUB_WORKSPACE_ID:-}" ] || emit_empty
command -v curl >/dev/null 2>&1 || emit_empty
command -v jq >/dev/null 2>&1 || emit_empty

read -r -d '' QUERY <<'GQL' || true
query($ws: ID!) {
  workspace(id: $ws) {
    sprints(filters: {state: {eq: OPEN}}, first: 1) {
      nodes { state issues(first: 100) { nodes {
        number title repository { ownerName name }
      } } }
    }
  }
}
GQL

payload=$(jq -n --arg q "$QUERY" --arg ws "$ZENHUB_WORKSPACE_ID" \
  '{query:$q, variables:{ws:$ws}}' 2>/dev/null) || emit_empty

resp=$(curl -sS -X POST "https://api.zenhub.com/public/graphql" \
  -H "Authorization: Bearer $ZENHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null) || emit_empty

echo "$resp" | jq -e '.data.workspace.sprints.nodes[0].issues.nodes' >/dev/null 2>&1 || emit_empty

echo "$resp" | jq '[.data.workspace.sprints.nodes[0].issues.nodes[]
  | {number, repo: (.repository.ownerName + "/" + .repository.name), title}]' 2>/dev/null || emit_empty
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-zenhub-sprint.test.sh`
Expected: PASS (both tests). Then verify the real query shape against the live API once (creds present): `bash scripts/ceo-zenhub-sprint.sh | jq .` — if Zenhub's schema field names differ (e.g. `sprints` filter args), adjust the `QUERY` heredoc and re-run the test. This verification is required because the GraphQL field names are the one externally-owned contract.

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-zenhub-sprint.sh scripts/ceo-zenhub-sprint.test.sh
git commit -m "feat(ceo): current-sprint Zenhub shell helper (degrade-to-empty)"
```

---

### Task 2: Gather the current-sprint signal in ceo-gather.sh

**Files:**
- Modify: `scripts/ceo-gather.sh` (insert after the sync-conflict scan, ~line 271, before the gather-status evaluation)
- Test: `scripts/ceo-gather-sprint.test.sh`

**Interfaces:**
- Consumes: `scripts/ceo-zenhub-sprint.sh` (Task 1), `~/.config/ceo/credentials.env`.
- Produces: exported `CURRENT_SPRINT_ITEMS` (JSON array, `[]` on failure) and `CURRENT_SPRINT_COUNT` (int).

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-gather-sprint.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  # stub the sprint helper to return one item
  cat > "$SCRIPT_DIR/.ceo-zenhub-sprint.stub" <<'STUB'
#!/usr/bin/env bash
echo '[{"number":7,"repo":"awesomemotive/x","title":"Sprint Y"}]'
STUB
  chmod +x "$SCRIPT_DIR/.ceo-zenhub-sprint.stub"
  export CEO_SPRINT_HELPER="$SCRIPT_DIR/.ceo-zenhub-sprint.stub"
  export CEO_VAULT="$TMP/vault"; mkdir -p "$CEO_VAULT/CEO"
}
teardown() { rm -rf "$TMP" "$SCRIPT_DIR/.ceo-zenhub-sprint.stub"; unset CEO_SPRINT_HELPER CEO_VAULT; }

test_exports_sprint_items_and_count() {
  setup
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1 || true
  assert_contains "$CURRENT_SPRINT_ITEMS" '"number":7' "sprint items exported"
  assert_eq "$CURRENT_SPRINT_COUNT" "1" "sprint count exported"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-gather-sprint.test.sh`
Expected: FAIL — `CURRENT_SPRINT_ITEMS` unset.

- [ ] **Step 3: Write minimal implementation**

Insert in `scripts/ceo-gather.sh` after the sync-conflict scan (~line 271):

```bash
# --- Current-sprint signal (AM priority key; degrades to empty) ---
_CEO_CREDS="${CEO_CREDS_FILE:-$HOME/.config/ceo/credentials.env}"
[ -f "$_CEO_CREDS" ] && { set -a; # shellcheck source=/dev/null
  . "$_CEO_CREDS"; set +a; }
_SPRINT_HELPER="${CEO_SPRINT_HELPER:-$(dirname "${BASH_SOURCE[0]}")/ceo-zenhub-sprint.sh}"
export CURRENT_SPRINT_ITEMS
if [ -x "$_SPRINT_HELPER" ]; then
  CURRENT_SPRINT_ITEMS=$(bash "$_SPRINT_HELPER" 2>/dev/null || echo "[]")
else
  CURRENT_SPRINT_ITEMS="[]"
fi
[ -n "$CURRENT_SPRINT_ITEMS" ] || CURRENT_SPRINT_ITEMS="[]"
export CURRENT_SPRINT_COUNT
CURRENT_SPRINT_COUNT=$(echo "$CURRENT_SPRINT_ITEMS" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-gather-sprint.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-gather.sh scripts/ceo-gather-sprint.test.sh
git commit -m "feat(ceo): gather current-sprint signal into pre-gather"
```

---

### Task 3: Gather yesterday's observable actions + recent ledger

**Files:**
- Modify: `scripts/ceo-gather.sh` (after Task 2 block)
- Test: `scripts/ceo-gather-actuals.test.sh`

**Interfaces:**
- Consumes: `gh` (merged PRs since yesterday), the ledger dir `CEO/model/`.
- Produces: exported `YESTERDAY_MERGED` (JSON array `[{number, repo, title}]`, `[]` on failure) and `LEDGER_RECENT` (string: the most recent ledger month file's tail, or empty).

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-gather-actuals.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  export CEO_VAULT="$TMP/vault"; mkdir -p "$CEO_VAULT/CEO/model"
  printf '## 2026-06-19 — predicted\n- pred: PR #7\n' > "$CEO_VAULT/CEO/model/2026-06.md"
  STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"search prs"*"--state merged"*) echo '[{"number":7,"title":"Did it","repository":{"nameWithOwner":"o/r"}}]' ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"; export PATH="$STUB_BIN:$PATH"
  export CEO_SPRINT_HELPER="/bin/true"
}
teardown() { rm -rf "$TMP"; unset CEO_VAULT CEO_SPRINT_HELPER; }

test_exports_yesterday_merged_and_ledger_tail() {
  setup
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1 || true
  assert_contains "$YESTERDAY_MERGED" '"number":7' "merged PR captured"
  assert_contains "$LEDGER_RECENT" 'PR #7' "ledger tail loaded"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-gather-actuals.test.sh`
Expected: FAIL — vars unset.

- [ ] **Step 3: Write minimal implementation**

Append in `scripts/ceo-gather.sh` after the Task 2 block:

```bash
# --- Yesterday's observable actions (positives only) + recent ledger ---
export YESTERDAY_MERGED
_yday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "")
if command -v gh >/dev/null 2>&1 && [ -n "$_yday" ]; then
  YESTERDAY_MERGED=$(gh search prs --author "@me" --merged --json number,title,repository \
    --limit 50 2>/dev/null | jq --arg d "$_yday" \
    '[.[] | {number, repo: .repository.nameWithOwner, title}]' 2>/dev/null || echo "[]")
else
  YESTERDAY_MERGED="[]"
fi
[ -n "$YESTERDAY_MERGED" ] || YESTERDAY_MERGED="[]"

export LEDGER_RECENT
_ledger_dir="$CEO_DIR/model"
if [ -d "$_ledger_dir" ]; then
  _latest=$(ls -1 "$_ledger_dir"/*.md 2>/dev/null | sort | tail -1)
  [ -n "$_latest" ] && LEDGER_RECENT=$(tail -40 "$_latest" 2>/dev/null) || LEDGER_RECENT=""
else
  LEDGER_RECENT=""
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-gather-actuals.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-gather.sh scripts/ceo-gather-actuals.test.sh
git commit -m "feat(ceo): gather yesterday merged PRs + recent ledger tail"
```

---

### Task 4: The `morning` synthesis playbook

**Files:**
- Create: `docs/playbooks/morning.md`
- Test: `scripts/morning-playbook.test.sh` (validates frontmatter + that the body states the ranking rule and the predicted-priorities block contract)

**Interfaces:**
- Consumes (pre-gathered): `CURRENT_SPRINT_ITEMS`, `CURRENT_SPRINT_COUNT`, `PR_REVIEW_REQUESTED`, `DAILY_NOTE_TOP3`, `DAILY_NOTE_TASKS`, `PENDING_ASK_QUESTIONS`, `LEDGER_RECENT`, `YESTERDAY_MERGED`.
- Produces: a briefing in the LOG_ENTRY output, ending with a fenced machine-readable block:
  ```
  <!-- CEO-PREDICTED-PRIORITIES
  - {repo}#{number}: {title}
  ... (top N) -->
  ```
  consumed by Task 5.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/morning-playbook.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
PB="$SCRIPT_DIR/../docs/playbooks/morning.md"

test_frontmatter_and_contract_present() {
  body=$(cat "$PB")
  assert_contains "$body" "name: morning" "name set"
  assert_contains "$body" "tier: read" "read tier"
  assert_contains "$body" "sprint" "ranking references sprint"
  assert_contains "$body" "older non-sprint" "states sprint-beats-age rule"
  assert_contains "$body" "CEO-PREDICTED-PRIORITIES" "emits predicted block contract"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/morning-playbook.test.sh`
Expected: FAIL — file missing.

- [ ] **Step 3: Write minimal implementation**

```markdown
<!-- docs/playbooks/morning.md -->
---
name: morning
description: One coherent CEO morning briefing ranked by real priority signals
trigger: cron
schedule: "20 3 * * 1-5"
runner: claude
model: sonnet
preflight: none
tier: read
status: draft
inputs: [pr_data, pending_count, today_log, yesterday_log, daily_note, active_domains, pending_ask, current_sprint, yesterday_merged, ledger_recent]
---

# Morning Flow

You are the CEO arriving at the office. Produce ONE briefing from the pre-gathered data below. Do NOT call Read/Grep/Glob/gh — everything is injected. Cap is `--max-turns 5`.

## Steps

1. **Overnight digest.** Summarize what changed: PRs needing review (`PR_REVIEW_REQUESTED`), pending approvals, firing alerts. 2-3 lines.
2. **Priorities (ranked by REAL signal).** Rank today's work. **Sprint membership is the primary key: an item in `CURRENT_SPRINT_ITEMS` outranks an older non-sprint PR.** Never rank by age alone. For Personal, use `Daily note Top 3`. Show the top 3-5 with a one-clause justification each ("in current sprint", "Top 3 today").
3. **Day plan.** Translate the priorities into a short ordered plan.
4. **Goals/todos.** Surface relevant items from `Active Domains` + `Daily note Tasks` + 1-2 `Pending [ask] questions`.
5. **Predicted-priorities block.** End the output with this exact machine-readable block (consumed by the learning ledger), listing the top priorities you chose in step 2:

   ```
   <!-- CEO-PREDICTED-PRIORITIES
   - {repo}#{number}: {title}
   -->
   ```

## Output Format

A briefing of <= 10 bullets (digest, priorities-with-justification, day plan, goals/todos), then the CEO-PREDICTED-PRIORITIES block. The shell writes it to CEO/reports/YYYY-MM-DD.md and posts to Discord.

## Constraints

- Read-only. No write actions.
- All data is pre-gathered; never run gh/git directly.
- Rank by sprint/Top-3 signal, never by age alone.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/morning-playbook.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/playbooks/morning.md scripts/morning-playbook.test.sh
git commit -m "feat(ceo): add morning synthesis playbook (draft, sprint-ranked)"
```

---

### Task 5: Observe step — hit-rate + ledger append (positives-only, discretion-scrubbed)

**Files:**
- Create: `scripts/ceo-observe.sh`
- Test: `scripts/ceo-observe.test.sh`

**Interfaces:**
- Consumes: the synthesis run output (stdin or `$1` path — contains the CEO-PREDICTED-PRIORITIES block), `YESTERDAY_MERGED` (env), the prior ledger entry's predicted list, `CEO_VAULT`.
- Produces: appends a dated entry to `CEO/model/YYYY-MM.md` with: today's predicted block, yesterday's hit-rate (predicted vs `YESTERDAY_MERGED`), and a scrubbed observations line. Exit 0 always (low-stakes write, never aborts the flow). Function `compute_hit_rate <predicted_json> <actual_json>` prints `hits/total`.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-observe.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
OBS="$SCRIPT_DIR/ceo-observe.sh"

setup() { TMP=$(mktemp -d); export CEO_VAULT="$TMP/v"; mkdir -p "$CEO_VAULT/CEO/model"; export TODAY="2026-06-20"; }
teardown() { rm -rf "$TMP"; unset CEO_VAULT TODAY; }

test_hit_rate_counts_only_matches() {
  setup
  # shellcheck source=/dev/null
  source "$OBS"
  pred='["o/r#7","o/r#8"]'; actual='[{"number":7,"repo":"o/r"}]'
  assert_eq "$(compute_hit_rate "$pred" "$actual")" "1/2" "1 of 2 predicted merged"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_no_deprioritized_inference() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- o/r#9: Thing\n-->\n' | \
    YESTERDAY_MERGED='[]' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "deprioritized" "never writes deprioritized/absence inference"
  assert_contains "$entry" "2026-06-20" "dated entry appended"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_discretion_scrub_drops_employer_specifics() {
  setup
  printf '<!-- CEO-PREDICTED-PRIORITIES\n- altamira/secret-contract#1: ACME deal terms\n-->\n' | \
    YESTERDAY_MERGED='[]' CEO_DISCRETION_DENY='ACME' bash "$OBS"
  entry=$(cat "$CEO_VAULT/CEO/model/2026-06.md")
  assert_no_match "$entry" "ACME" "employer-specific term scrubbed"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-observe.test.sh`
Expected: FAIL — script missing.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/ceo-observe.sh
# Append a positives-only, discretion-scrubbed learning entry to the model ledger.
# Sourced for unit tests (defines compute_hit_rate); executed as the observe step.
set -uo pipefail

compute_hit_rate() {
  # $1 = JSON array of predicted "repo#num" strings; $2 = JSON array of {number,repo}
  local pred="$1" actual="$2" total hits
  total=$(echo "$pred" | jq 'length' 2>/dev/null || echo 0)
  hits=$(jq -n --argjson p "$pred" --argjson a "$actual" \
    '[$p[] | . as $x | $a[] | select(($.repo + "#" + (.number|tostring)) == $x)] | length' 2>/dev/null || echo 0)
  echo "${hits}/${total}"
}

_ceo_observe_main() {
  : "${CEO_VAULT:?CEO_VAULT must be set}"
  : "${TODAY:?TODAY must be set}"
  local ledger_dir="$CEO_VAULT/CEO/model"
  mkdir -p "$ledger_dir"
  local month="${TODAY%-*}"           # YYYY-MM
  local ledger="$ledger_dir/$month.md"

  local input; input=$(cat || true)
  # Extract predicted lines from the synthesis block.
  local predicted; predicted=$(printf '%s\n' "$input" \
    | awk '/CEO-PREDICTED-PRIORITIES/{f=1;next}/-->/{f=0}f' \
    | sed -E 's/^- //; s/:.*$//' | sed '/^$/d')

  # Discretion scrub: drop any line containing a denied term (patterns only, never specifics).
  local deny="${CEO_DISCRETION_DENY:-}"
  if [ -n "$deny" ]; then
    predicted=$(printf '%s\n' "$predicted" | grep -viE "$deny" || true)
  fi

  local hit="n/a"
  if [ -n "${YESTERDAY_MERGED:-}" ] && [ -n "${LEDGER_PREV_PREDICTED:-}" ]; then
    hit=$(compute_hit_rate "$LEDGER_PREV_PREDICTED" "$YESTERDAY_MERGED")
  fi

  {
    echo ""
    echo "## $TODAY — model update"
    echo "- yesterday hit-rate: $hit"
    echo "- predicted today:"
    printf '%s\n' "$predicted" | sed 's/^/  - /'
  } >> "$ledger"
}

# Only run main when executed, not when sourced for tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then _ceo_observe_main; fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-observe.test.sh`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-observe.sh scripts/ceo-observe.test.sh
git commit -m "feat(ceo): observe step — positives-only ledger + hit-rate + discretion scrub"
```

---

### Task 6: Wire the observe step into the dispatch after a `morning` run

**Files:**
- Modify: `scripts/ceo-cron.sh` (in the success path, after the report is captured for trigger `morning`)
- Test: `scripts/ceo-cron-morning-observe.test.sh`

**Interfaces:**
- Consumes: the captured `log_entry` (synthesis output) for trigger `morning`; `scripts/ceo-observe.sh` (Task 5).
- Produces: calls `ceo-observe.sh` with the run output piped in, only for `morning`, only on success, only when not dry-run. Failure of observe must not fail the flow.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-cron-morning-observe.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

test_morning_invokes_observe_hook() {
  # The dispatch must contain a guarded call to ceo-observe.sh for trigger "morning".
  body=$(cat "$SCRIPT_DIR/ceo-cron.sh")
  assert_contains "$body" "ceo-observe.sh" "observe step wired into dispatch"
  assert_contains "$body" 'morning' "guarded on morning trigger"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-cron-morning-observe.test.sh`
Expected: FAIL — no observe call yet.

- [ ] **Step 3: Write minimal implementation**

In `scripts/ceo-cron.sh`, in the success path right after `_report intake "$trigger" "$log_entry"` (~line 333), add:

```bash
  if [ "$trigger" = "morning" ] && [ "$self_reported_failed" -eq 0 ] && [ "${CEO_DRY_RUN:-}" != "1" ]; then
    # Low-stakes learning write; never fail the flow on observe error.
    printf '%s\n' "$log_entry" | YESTERDAY_MERGED="${YESTERDAY_MERGED:-[]}" \
      LEDGER_PREV_PREDICTED="${LEDGER_PREV_PREDICTED:-[]}" \
      bash "$SCRIPT_DIR/ceo-observe.sh" >/dev/null 2>&1 || \
      _v "observe step failed (non-fatal)"
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-cron-morning-observe.test.sh`
Expected: PASS. Then run the full suite to confirm no regression: `for t in scripts/*.test.sh; do bash "$t" || echo "FAIL: $t"; done`

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-cron.sh scripts/ceo-cron-morning-observe.test.sh
git commit -m "feat(ceo): invoke observe step after morning run (non-fatal)"
```

---

### Task 7: Synthesis fallback — raw digest when the LLM run fails

**Files:**
- Modify: `scripts/ceo-cron.sh` (the `morning` read-tier execution path)
- Test: `scripts/ceo-cron-morning-fallback.test.sh`

**Interfaces:**
- Consumes: the pre-gathered vars (sprint, PRs, daily note).
- Produces: when the synthesis runner exits non-zero or emits empty, a deterministic raw-digest string (sprint items + review PRs + Top 3) is used as `log_entry` so Discord still receives something.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/ceo-cron-morning-fallback.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

test_raw_digest_helper_emits_signals_when_synthesis_empty() {
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-cron.sh" 2>/dev/null || true
  CURRENT_SPRINT_ITEMS='[{"number":7,"repo":"o/r","title":"Sprint Y"}]'
  PR_REVIEW_REQUESTED='[]'; DAILY_NOTE_TOP3="Write spec"
  out=$(ceo_morning_raw_digest)
  assert_contains "$out" "Sprint Y" "digest includes sprint item"
  assert_contains "$out" "Write spec" "digest includes Top 3"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/ceo-cron-morning-fallback.test.sh`
Expected: FAIL — `ceo_morning_raw_digest` undefined.

- [ ] **Step 3: Write minimal implementation**

Add the helper near the top of `scripts/ceo-cron.sh` (function definitions area):

```bash
ceo_morning_raw_digest() {
  echo "**Morning (raw digest — synthesis unavailable)**"
  local sprint; sprint=$(echo "${CURRENT_SPRINT_ITEMS:-[]}" | jq -r '.[]? | "- [sprint] " + .repo + "#" + (.number|tostring) + " " + .title' 2>/dev/null)
  [ -n "$sprint" ] && { echo "Current sprint:"; echo "$sprint"; }
  local rev; rev=$(echo "${PR_REVIEW_REQUESTED:-[]}" | jq -r '.[]? | "- [review] " + (.title // "PR")' 2>/dev/null)
  [ -n "$rev" ] && { echo "Needs review:"; echo "$rev"; }
  [ -n "${DAILY_NOTE_TOP3:-}" ] && { echo "Top 3:"; echo "${DAILY_NOTE_TOP3}"; }
}
```

Then in the `morning` execution path, after the runner call, gate the fallback:

```bash
  if [ -z "${RUN_OUTPUT//[[:space:]]/}" ] || [ "$RUN_RC" -ne 0 ]; then
    _v "morning synthesis failed/empty — using raw digest fallback"
    log_entry=$(ceo_morning_raw_digest)
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/ceo-cron-morning-fallback.test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/ceo-cron.sh scripts/ceo-cron-morning-fallback.test.sh
git commit -m "feat(ceo): raw-digest fallback when morning synthesis fails"
```

---

### Task 8: Cutover — enable `morning`, disable legacy playbooks, enable Discord (ML-1 only)

**Files:**
- Modify: `docs/playbooks/morning.md` (status draft → active)
- Modify: `docs/playbooks/morning-scan.md`, `morning-brief.md`, `pending-drip.md`, `pr-triage.md` (status → disabled)
- Modify: `CEO/settings.json` (vault) — add `morning` to `discord_report_triggers`
- Create: `docs/playbooks/morning.md` registry note + `docs/cutover-morning-flow.md` (runbook)
- Test: `scripts/morning-cutover.test.sh`

**Interfaces:**
- Consumes: all prior tasks merged + tested.
- Produces: `morning` active and Discord-enabled; the four legacy playbooks disabled-not-deleted; a cutover runbook documenting the ML-1 scan + one-cycle diff.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/morning-cutover.test.sh
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
PB="$SCRIPT_DIR/../docs/playbooks"

test_morning_active_legacy_disabled() {
  assert_contains "$(cat "$PB/morning.md")" "status: active" "morning active"
  for legacy in morning-scan morning-brief pending-drip pr-triage; do
    assert_contains "$(cat "$PB/$legacy.md")" "status: disabled" "$legacy disabled"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/morning-cutover.test.sh`
Expected: FAIL — statuses not yet changed.

- [ ] **Step 3: Make the changes**

- In `docs/playbooks/morning.md`: `status: draft` → `status: active`.
- In each of `morning-scan.md`, `morning-brief.md`, `pending-drip.md`, `pr-triage.md`: `status: active` → `status: disabled`.
- In vault `CEO/settings.json`: add `"morning"` to `discord_report_triggers` (keep `morning-brief` until the diff cycle confirms parity, then remove it).
- Create `docs/cutover-morning-flow.md`:

```markdown
# Morning Flow Cutover (ML-1 only)

1. On ML-1 only: `ceo playbook scan` (regenerates ~/.ceo/registry.json from frontmatter; installs schedule via ceo-schedulerd). Never run scan on the MacBook.
2. Keep morning-brief enabled in discord_report_triggers for ONE cycle; compare the new `morning` briefing against the old `morning-brief` output for 1-2 days.
3. Once parity/superiority confirmed: remove `morning-brief` from discord_report_triggers; leave legacy playbooks disabled.
4. Register `morning` as an automated writer (writes CEO/model/ ledger) in the registry note per ceo-automated-writers-are-playbooks.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/morning-cutover.test.sh`
Then full suite: `for t in scripts/*.test.sh; do bash "$t" >/dev/null 2>&1 && echo "ok $t" || echo "FAIL $t"; done`
Expected: PASS + all green.

- [ ] **Step 5: Commit**

```bash
git add docs/playbooks/morning.md docs/playbooks/morning-scan.md docs/playbooks/morning-brief.md docs/playbooks/pending-drip.md docs/playbooks/pr-triage.md docs/cutover-morning-flow.md scripts/morning-cutover.test.sh
git commit -m "feat(ceo): cutover — activate morning flow, disable legacy playbooks"
```

> **Note:** The actual `ceo playbook scan` + `CEO/settings.json` edit are runtime ML-1 actions per `ceo-scan-only-on-ml1`; the settings.json change is in the synced vault, not this repo. Do them per `docs/cutover-morning-flow.md` after merge.

---

## Self-Review

- **Spec coverage:** one flow (Tasks 4,6,7) ✓; real signals/sprint-beats-age (Tasks 1,2,4) ✓; positives-only ledger + hit-rate (Tasks 3,5) ✓; discretion-bound synced ledger (Task 5) ✓; model portability + raw-digest fallback (Task 7) ✓; cutover safety / disabled-not-deleted / ML-1 / automated-writer registration (Task 8) ✓; out-of-scope items (Propose, bidirectional, calendar) correctly absent ✓.
- **Placeholder scan:** no TBD/TODO; the one external unknown (Zenhub GraphQL field names) is handled by an explicit verify-against-live-API step in Task 1.4, not a placeholder.
- **Type/name consistency:** `CURRENT_SPRINT_ITEMS`/`CURRENT_SPRINT_COUNT`, `YESTERDAY_MERGED`, `LEDGER_RECENT`, `compute_hit_rate`, `ceo_morning_raw_digest`, the `CEO-PREDICTED-PRIORITIES` block, and `CEO/model/YYYY-MM.md` are used consistently across tasks.

---

## Audit findings — MUST FIX before execution (2026-06-20)

An independent audit against the verified `ceo-cron.sh` internals found four HIGH issues. **Do not execute the plan above until these are folded in.**

1. **HIGH — missing PRE_GATHERED wiring task.** `ceo-cron.sh:1344-1359` builds the injected `PRE_GATHERED` block from a *hardcoded* `_inputs_includes` vocabulary (`pending_count`, `pr_data`, `today_log`, `yesterday_log`, `daily_note`, `briefings_training`, `active_domains`, `pending_ask`, `scan_data`, `blessings`). Adding `current_sprint`/`yesterday_merged`/`ledger_recent` to `morning.md` frontmatter does nothing — there is no branch emitting `$CURRENT_SPRINT_ITEMS`. **Add a task that inserts `_inputs_includes current_sprint && PRE_GATHERED+=...` (and the other two) at ~line 1359, before Task 4 is meaningful.** Without it the synthesis never sees the sprint signal and ranks by age — the exact failure this whole effort targets.
2. **HIGH — Task 7 phantom variables.** The fallback gates on `RUN_OUTPUT`/`RUN_RC`, which don't exist. The real contract: `_dispatch_single_output()` (`ceo-cron.sh:301-334`) parses `log_entry` from a `LOG_ENTRY:`/`END_LOG_ENTRY` block (`:307`) out of the runner `$output`. Fix: in `_dispatch_single_output`, when `trigger="morning"` and `log_entry` is empty, set `log_entry=$(ceo_morning_raw_digest)` before `_report intake` — replacing the current "unparseable output" branch for morning. Test must drive `_dispatch_single_output "morning" "<garbage>"` and assert the digest is reported.
3. **HIGH — `LEDGER_PREV_PREDICTED` never populated.** Task 3 loads `LEDGER_RECENT` as text; nothing parses yesterday's predicted list into JSON, so hit-rate is permanently `n/a`. Fix in Task 3: parse the most-recent ledger entry's `predicted today:` bullets into `LEDGER_PREV_PREDICTED` (JSON array of `repo#num` strings) and export it.
4. **HIGH — Task 6 is a grep tautology** (and Task 8 too, lower stakes). Replace with a behavioral test: stub the runner, drive the `morning` dispatch, assert `CEO/model/YYYY-MM.md` gains an entry.
5. **MEDIUM — Zenhub query is a guess.** Reuse the proven `@octokit/graphql` client in `~/.claude/skills/story-points/scripts/analyzer/` (endpoint `https://api.zenhub.com/public/graphql`, bearer auth) as the reference, and treat the current-sprint query as a small spike validated against the Zenhub MCP `getSprint` schema. The degrade-to-`[]` wrapper already prevents a wrong query from breaking the flow.
6. **MEDIUM — discretion scrub is inert by default.** Task 5's `CEO_DISCRETION_DENY` is empty unless set, so nothing is scrubbed in production. Default the denylist from `Profile/discretion.md` (or a configured term list) so the guarantee actually holds.

**Status: design approved, plan drafted + audited, NOT execution-ready until the six items above are folded in.**
