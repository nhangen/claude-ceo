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

# Isolated state root — tests must not touch developer state (#317 class).
CEO_LOOP_STATE_ROOT="$TMP/state"
export CEO_LOOP_STATE_ROOT
LOOP="$LIB_DIR/ceo-loop.sh"

cat > "$TMP/routes.json" <<'JSON'
{"routes": {"bug-fix": [
  {"provider": "ollama", "model": "qwen2.5-coder:7b", "command": "$WORKER_PRIMARY"},
  {"provider": "opencode", "model": "kimi-k3", "command": "$WORKER_FALLBACK"}
]}}
JSON

make_spec() { # <name> <files-json> <verify-cmd> <findings-json>
  jq -n \
    --arg repo "fixture-repo" --arg branch "nh/fixture-$1" --arg base "abc123" \
    --argjson files "$2" --arg verify "$3" --arg author "ollama/qwen2.5-coder:7b" \
    --argjson reviewers '["opencode/kimi-k3"]' --argjson findings "$4" \
    '{repo: $repo, branch: $branch, base: $base, shape: "bug-fix",
      files: $files, verify_cmd: $verify, author: $author,
      reviewers: $reviewers, findings: $findings}' > "$TMP/$1.json"
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
  assert_contains "$out" "done (fixture-repo/nh/fixture-ok risk=medium action=promote)"
  assert_eq "$rc" "0"
  # telemetry row written in the token-scope-ingestable contract
  assert_contains "$(cat "$CEO_LOOP_STATE_ROOT/fixture-repo/telemetry.jsonl")" '"writer":"ceo-loop"'
  # ledger entry appended under the shared writer contract
  assert_contains "$(cat "$CEO_LOOP_STATE_ROOT/fixture-repo/telemetry.jsonl")" '"accepted":true'
}

test_high_risk_cannot_reach_production_main_without_premium_gate() {
  make_spec hot '["db/migrations/0042_add_index.js"]' "true" '[]'
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/hot.json" --routes "$TMP/routes.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "BLOCKED"
  assert_contains "$out" "premium approval"
  assert_eq "$rc" "7"
}

test_premium_approval_evidence_unlocks_production_main_for_high_risk() {
  make_spec approved '["hooks/pre-commit"]' "true" '[]'
  : > "$TMP/premium-approval.md"
  local out rc=0
  out=$(CEO_LOOP_PREMIUM_APPROVAL="$TMP/premium-approval.md" \
    bash "$LOOP" run --spec "$TMP/approved.json" --routes "$TMP/routes.json" --target main) || rc=$?
  assert_contains "$out" "action=promote"
}

test_equivalent_findings_collapse_to_one_repair_ticket() {
  make_spec dupes '["src/app/widget.ts"]' "true" \
    '[{"invariant":"null check","location":"lib/util.sh:120","severity":"HIGH"},
      {"invariant":"null check","location":"lib/util.sh:4187","severity":"HIGH"}]'
  bash "$LOOP" run --spec "$TMP/dupes.json" --routes "$TMP/routes.json" --target integration >/dev/null
  local fp rows=0
  fp=$(ceo_finding_fingerprint fixture-repo abc123 "null check" "lib/util.sh:120" "HIGH")
  rows=$(grep -c "\"ticket_id\":\"repair-${fp:0:12}" "$CEO_LOOP_STATE_ROOT/fixture-repo/repair-tickets.jsonl" || true)
  assert_eq "$rows" "1" "line-shifted equivalent must file ONE ticket"
}

test_overlapping_in_flight_worker_stops_the_loop_naming_conflict() {
  make_spec first '["lib/util.sh"]' "true" '[]'
  make_spec second '["lib/util.sh"]' "true" '[]'
  bash "$LOOP" run --spec "$TMP/first.json" --routes "$TMP/routes.json" --target integration >/dev/null
  # first worker is released on completion; simulate it still in flight:
  printf '%s\n' '{"branch":"nh/fixture-first","base":"abc123","files":["lib/util.sh"]}' \
    >> "$CEO_LOOP_STATE_ROOT/fixture-repo/workers.jsonl"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/second.json" --routes "$TMP/routes.json" --target integration 2>&1) || rc=$?
  assert_contains "$out" "overlaps in-flight worker 'nh/fixture-first'"
  assert_eq "$rc" "6"
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
  assert_file_exists "$CEO_LOOP_STATE_ROOT/fixture-repo/exhausted.jsonl"
  assert_contains "$(cat "$CEO_LOOP_STATE_ROOT/fixture-repo/exhausted.jsonl")" "tests pass"
}

test_status_reports_state_without_touching_anything() {
  make_spec st '["docs/note.md"]' "true" '[]'
  bash "$LOOP" run --spec "$TMP/st.json" --routes "$TMP/routes.json" --target integration >/dev/null
  local out
  out=$(bash "$LOOP" status --repo fixture-repo)
  assert_contains "$out" "repair-tickets"
  assert_contains "$out" "telemetry"
}

run_tests
