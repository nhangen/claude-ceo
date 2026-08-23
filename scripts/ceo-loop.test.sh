#!/usr/bin/env bash
# ceo-loop.test.sh — end-to-end dry-run of the #329 loop over fixture specs.
# Every gate runs for real; workers/reviewers are fixture commands, no providers.
set -euo pipefail
cd "$(dirname "$0")"
source ./test-harness.sh

LIB_DIR="$(pwd)"
# shellcheck source=ceo-loop-lib.sh
source ./ceo-loop-lib.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolated state root AND isolated shared ledger — tests must not touch
# developer state anywhere (#317 class; test-writes-stay-in-the-fixture).
CEO_LOOP_STATE_ROOT="$TMP/state"
export CEO_LOOP_STATE_ROOT
OLLAMA_AGENT_LEDGER="$TMP/ledger/runs.jsonl"
export OLLAMA_AGENT_LEDGER
LOOP="$LIB_DIR/ceo-loop.sh"

REPO_N=0
next_repo() { # unique slug per test so cases never share state
  REPO_N=$((REPO_N + 1))
  echo "repo-$REPO_N"
}

cat > "$TMP/routes.json" <<'JSON'
{"routes": {"bug-fix": [
  {"provider": "ollama", "model": "qwen2.5-coder:7b", "command": "$WORKER_PRIMARY"},
  {"provider": "opencode", "model": "kimi-k3", "command": "$WORKER_FALLBACK"}
]}}
JSON

# Test bodies run in subshells, so a shared counter cannot advance across
# cases; slug off the unique spec name instead.
make_spec() { # <name> <files-json> <verify-cmd> <findings-json> [repo-slug]
  local repo="${5:-repo-$1}"
  printf -v "SLUG_$1" '%s' "$repo"
  jq -n \
    --arg repo "$repo" --arg branch "nh/fixture-$1" --arg base "abc123" \
    --argjson files "$2" --arg verify "$3" --arg author "ollama/qwen2.5-coder:7b" \
    --argjson reviewers '["opencode/kimi-k3"]' --argjson findings "$4" \
    '{repo: $repo, branch: $branch, base: $base, shape: "bug-fix",
      files: $files, verify_cmd: $verify, author: $author,
      reviewers: $reviewers, findings: $findings}' > "$TMP/$1.json"
}
state_of() { # <name>
  local var="SLUG_$1"
  echo "$CEO_LOOP_STATE_ROOT/${!var:-missing-slug}"
}

WORKER_PRIMARY="true"
WORKER_FALLBACK="true"
WORKER_FAIL="false"
export WORKER_PRIMARY WORKER_FALLBACK WORKER_FAIL

test_e2e_happy_path_exercises_every_phase() {
  make_spec ok '["src/app/widget.ts"]' "true" \
    '[{"invariant":"null check","location":"src/app/widget.ts:12","severity":"LOW"}]'
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/ok.json" --routes "$TMP/routes.json" --target integration) || rc=$?
  assert_contains "$out" "queued"
  assert_contains "$out" "isolated branch nh/fixture-ok"
  assert_contains "$out" "cross-provider reviewer opencode/kimi-k3"
  assert_contains "$out" "done (repo-ok/nh/fixture-ok risk=medium action=promote)"
  assert_eq "$rc" "0"
  # the queue write is a real row, not just an echo
  assert_contains "$(cat "$(state_of ok)/queue.jsonl")" '"status":"queued"'
  # telemetry row in the token-scope-ingestable contract, per-run findings count
  local tel
  tel="$(cat "$(state_of ok)/telemetry.jsonl")"
  assert_contains "$tel" '"writer":"ceo-loop"'
  assert_contains "$tel" '"accepted":true'
  assert_contains "$tel" '"findings":1'
  # shared-ledger entry actually landed (OLLAMA_AGENT_LEDGER points into TMP)
  assert_contains "$(cat "$OLLAMA_AGENT_LEDGER")" 'loop:'
  # worker slot was registered AND released by the loop itself
  if grep -q "nh/fixture-ok" "$(state_of ok)/workers.jsonl"; then
    fail_test "completed run must not keep its serialization slot"
  fi
}

test_usage_error_exits_2() {
  local out rc=0
  out=$(bash "$LOOP" run --spec /nonexistent/x.json --routes "$TMP/routes.json" 2>&1) || rc=$?
  assert_contains "$out" "spec not found"
  assert_eq "$rc" "2"
  # An empty-but-present spec must hit the required-field gate, not pass silently.
  : > "$TMP/empty-spec.json"
  out=$(bash "$LOOP" run --spec "$TMP/empty-spec.json" --routes "$TMP/routes.json" 2>&1) || rc=$?
  assert_contains "$out" "missing required field"
  assert_eq "$rc" "2"
}

test_spec_with_no_files_refuses_to_classify() {
  jq -n --arg repo "repo-empty" --arg branch "nh/fixture-empty" --arg base abc \
    --argjson files '[]' --arg verify true --arg author "ollama/q" \
    --argjson reviewers '["opencode/k"]' --argjson findings '[]' \
    '{repo:$repo,branch:$branch,base:$base,shape:"bug-fix",files:$files,
      verify_cmd:$verify,author:$author,reviewers:$reviewers,findings:$findings}' > "$TMP/empty-files.json"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/empty-files.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "no changed files"
  assert_eq "$rc" "2"
}

test_review_gate_failure_exits_5_e2e() {
  make_spec sametier '["docs/a.md"]' "true" '[]'
  jq '.author = "ollama/qwen" | .reviewers = ["ollama/qwen-turbo"]' "$TMP/sametier.json" > "$TMP/sametier2.json"
  mv "$TMP/sametier2.json" "$TMP/sametier.json"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/sametier.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "review gate failed"
  assert_eq "$rc" "5"
}

test_stale_base_stops_promotion_at_the_door() {
  make_spec stalebase '["docs/b.md"]' "true" '[]'
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/stalebase.json" --routes "$TMP/routes.json" \
    --target integration --current-base def456 2>&1) || rc=$?
  assert_contains "$out" "STALE BASE"
  assert_eq "$rc" "9"
}

test_high_risk_cannot_reach_production_main_without_premium_gate() {
  make_spec hot '["db/migrations/0042_add_index.js"]' "true" '[]'
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/hot.json" --routes "$TMP/routes.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "BLOCKED"
  assert_contains "$out" "premium approval"
  assert_eq "$rc" "7"
}

test_premium_approval_requires_real_evidence_not_mere_existence() {
  make_spec approved '["hooks/pre-commit"]' "true" '[]'
  # An EMPTY file at the approval path must NOT unlock the gate.
  : > "$TMP/empty-approval.md"
  local out rc=0
  out=$(CEO_LOOP_PREMIUM_APPROVAL="$TMP/empty-approval.md" \
    bash "$LOOP" run --spec "$TMP/approved.json" --routes "$TMP/routes.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "lacks evidence"
  assert_eq "$rc" "7"

  # Schema-carrying evidence does unlock it.
  printf '%s\n' '{"approved_by":"nhangen","ticket":"CEO/approvals/premium-42"}' > "$TMP/premium-approval.json"
  out=$(CEO_LOOP_PREMIUM_APPROVAL="$TMP/premium-approval.json" \
    bash "$LOOP" run --spec "$TMP/approved.json" --routes "$TMP/routes.json" --target main) || rc=$?
  assert_contains "$out" "action=promote"
}

test_equivalent_findings_collapse_to_one_repair_ticket() {
  make_spec dupes '["src/app/widget.ts"]' "true" \
    '[{"invariant":"null check","location":"lib/util.sh:120","severity":"HIGH"},
      {"invariant":"null check","location":"lib/util.sh:4187","severity":"HIGH"}]'
  bash "$LOOP" run --spec "$TMP/dupes.json" --routes "$TMP/routes.json" --target integration >/dev/null
  local fp rows=0
  fp=$(ceo_finding_fingerprint repo-dupes abc123 "null check" "lib/util.sh:120" "HIGH")
  rows=$(grep -c "\"ticket_id\":\"repair-${fp:0:12}" "$(state_of dupes)/repair-tickets.jsonl" || true)
  assert_eq "$rows" "1" "line-shifted equivalent must file ONE ticket"
}

test_overlapping_in_flight_worker_stops_the_loop_naming_conflict() {
  # Same shared slug so the two workers contend on one registry.
  make_spec first '["lib/util.sh"]' "true" '[]' repo-overlap
  make_spec second '["lib/util.sh"]' "true" '[]' repo-overlap
  bash "$LOOP" run --spec "$TMP/first.json" --routes "$TMP/routes.json" --target integration >/dev/null
  # first worker is released on completion; simulate it still in flight:
  printf '%s\n' '{"branch":"nh/fixture-first","base":"abc123","files":["lib/util.sh"]}' \
    >> "$(state_of first)/workers.jsonl"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/second.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "overlaps in-flight worker 'nh/fixture-first'"
  assert_eq "$rc" "6"
}

test_corrupt_workers_row_is_a_hard_stop_not_a_pass() {
  make_spec corrupt '["lib/other.sh"]' "true" '[]'
  mkdir -p "$(state_of corrupt)"
  printf '%s\n' 'this is not json at all' >> "$(state_of corrupt)/workers.jsonl"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/corrupt.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "corrupt row"
  assert_eq "$rc" "6"
}

test_finding_strings_with_quotes_survive_json_roundtrip() {
  make_spec quotes '["src/app/widget.ts"]' "true" \
    '[{"invariant":"handles \"null\" case","location":"src/app/widget.ts:12","severity":"HIGH"}]'
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/quotes.json" --routes "$TMP/routes.json" --target integration) || rc=$?
  assert_eq "$rc" "0"
  # findings.jsonl stays machine-readable after a quote-bearing finding
  jq -e . "$(state_of quotes)/findings.jsonl" >/dev/null 2>&1 \
    || fail_test "findings.jsonl corrupted by quoted strings"
  assert_contains "$(cat "$(state_of quotes)/repair-tickets.jsonl")" 'null\" case'
}

test_provider_failure_reroutes_to_fallback_and_both_failing_is_loud() {
  make_spec reroute '["src/app/widget.ts"]' "true" '[]'
  # Primary command fails ($WORKER_FAIL), fallback succeeds.
  sed 's/\$WORKER_PRIMARY/\$WORKER_FAIL/' "$TMP/routes.json" > "$TMP/routes-reroute.json"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/reroute.json" --routes "$TMP/routes-reroute.json" --target integration) || rc=$?
  assert_contains "$out" "rerouted to opencode/kimi-k3"
  assert_eq "$rc" "0"

  # Both fail -> loud exit with actionable state left behind.
  sed 's/\$WORKER_PRIMARY/\$WORKER_FAIL/; s/\$WORKER_FALLBACK/\$WORKER_FAIL/' \
    "$TMP/routes.json" > "$TMP/routes-dead.json"
  out=$(bash "$LOOP" run --spec "$TMP/reroute.json" --routes "$TMP/routes-dead.json" --target integration 2>&1) || rc=$?
  # Both providers dead: loop exits loudly naming where actionable state lives.
  assert_contains "$out" "rerouted worker also failed"
  assert_contains "$out" "actionable state"
  assert_eq "$rc" "4"

  # A shape with NO remaining configured candidate says so explicitly.
  cat > "$TMP/routes-single.json" <<'JSON'
{"routes": {"bug-fix": [{"provider": "ollama", "model": "qwen2.5-coder:7b", "command": "$WORKER_PRIMARY"}]}}
JSON
  out=$(WORKER_PRIMARY=false bash "$LOOP" run --spec "$TMP/reroute.json" --routes "$TMP/routes-single.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "no fallback left"
  assert_eq "$rc" "4"
}

test_failing_verification_requeues_then_exhaustion_stays_visible() {
  make_spec flaky '["src/app/widget.ts"]' "false" \
    '[{"invariant":"tests pass","location":"tests/flaky.test.sh:1","severity":"HIGH"}]'
  CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/flaky.json" --routes "$TMP/routes.json" --target integration >/dev/null 2>&1 || true
  local out2 rc2=0
  out2=$(CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/flaky.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc2=$?
  assert_contains "$out2" "retries EXHAUSTED"
  assert_eq "$rc2" "3" "exhaustion propagates as exit 3"
  assert_file_exists "$(state_of flaky)/exhausted.jsonl"
  assert_contains "$(cat "$(state_of flaky)/exhausted.jsonl")" "tests pass"
  # exhaustion is recorded ONCE — a later cycle short-circuits on the marker
  local before after
  before=$(wc -l < "$(state_of flaky)/exhausted.jsonl")
  CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/flaky.json" --routes "$TMP/routes.json" --target integration >/dev/null 2>&1 || true
  after=$(wc -l < "$(state_of flaky)/exhausted.jsonl")
  assert_eq "$after" "$before" "exhaustion rows must not multiply"
}

test_status_reports_state_without_touching_anything() {
  make_spec st '["docs/note.md"]' "true" '[]'
  bash "$LOOP" run --spec "$TMP/st.json" --routes "$TMP/routes.json" --target integration >/dev/null
  local slug out
  slug="$(state_of st)"
  slug="${slug#$CEO_LOOP_STATE_ROOT/}"
  out=$(bash "$LOOP" status --repo "$slug")
  assert_contains "$out" "repair-tickets"
  assert_contains "$out" "telemetry"
  # content, not just headers: the run's ticket summary must be visible
  assert_contains "$out" "$(jq -r '.summary // empty' <(head -1 "$CEO_LOOP_STATE_ROOT/$slug/repair-tickets.jsonl") 2>/dev/null || true)"
}

run_tests
