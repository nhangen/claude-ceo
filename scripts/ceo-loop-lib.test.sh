#!/usr/bin/env bash
# ceo-loop-lib.test.sh — pure-function coverage for the #329 loop decisions.
set -euo pipefail
cd "$(dirname "$0")"
source ./test-harness.sh
source ./ceo-loop-lib.sh

LIB_DIR="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RISK_MAP="$LIB_DIR/ceo-risk-map.json"

# Isolated state root so tests never touch the developer's real state (#317 class).
CEO_LOOP_STATE_ROOT="$TMP/state"
export CEO_LOOP_STATE_ROOT

cat > "$TMP/routes.json" <<'JSON'
{"routes": {"bug-fix": [
  {"provider": "ollama", "model": "qwen2.5-coder:7b", "command": "run-local"},
  {"provider": "opencode", "model": "kimi-k3", "command": "run-hosted"}
]}}
JSON

test_risk_billing_path_is_high() {
  assert_eq "$(ceo_risk_classify "$RISK_MAP" "src/billing/charge.php")" "high"
}

test_risk_migrations_are_high() {
  assert_eq "$(ceo_risk_classify "$RISK_MAP" "db/migrations/0042_add_index.js")" "high"
}

test_risk_docs_are_low() {
  assert_eq "$(ceo_risk_classify "$RISK_MAP" "README.md")" "low"
}

test_risk_unmatched_path_takes_map_default_medium() {
  assert_eq "$(ceo_risk_classify "$RISK_MAP" "src/app/widget.ts")" "medium"
}

test_risk_highest_wins_across_paths() {
  assert_eq "$(ceo_risk_classify "$RISK_MAP" "docs/notes.md" "hooks/pre-commit")" "high"
}

test_risk_unreadable_map_fails_closed_to_high_never_open() {
  assert_eq "$(ceo_risk_classify "$TMP/nope.json" "README.md")" "high"
}

test_fingerprint_same_finding_collapses_despite_line_shift() {
  local a b
  a=$(ceo_finding_fingerprint o/r abc123 "tests/x.test.sh" "lib/util.sh:120" "HIGH")
  b=$(ceo_finding_fingerprint o/r abc123 "tests/x.test.sh" "lib/util.sh:4187" "HIGH")
  assert_eq "$a" "$b" "line-shifted equivalent must share a fingerprint"
}

test_fingerprint_different_invariant_does_not_collapse() {
  local a b
  a=$(ceo_finding_fingerprint o/r abc123 "tests/a.test.sh" "lib/u.sh:1" "HIGH")
  b=$(ceo_finding_fingerprint o/r abc123 "tests/b.test.sh" "lib/u.sh:1" "HIGH")
  assert_fails "different invariants must not share a fingerprint" test "$a" = "$b"
}

test_fingerprint_new_base_revision_reopens_the_finding() {
  local a b
  a=$(ceo_finding_fingerprint o/r aaa "t.sh" "l.sh:1" "HIGH")
  b=$(ceo_finding_fingerprint o/r bbb "t.sh" "l.sh:1" "HIGH")
  assert_fails "new base must reopen the finding" test "$a" = "$b"
}

test_dedup_first_filing_creates_second_returns_same_ticket_id() {
  local dir="$TMP/dedup"; mkdir -p "$dir"
  local fp id1 id2
  fp=$(ceo_finding_fingerprint o/r abc "t.sh" "l.sh:1" "MED")
  id1=$(ceo_ticket_dedup "$dir" "$fp" '{"summary":"null check missing"}')
  id2=$(ceo_ticket_dedup "$dir" "$fp" '{"summary":"null check missing"}')
  assert_eq "$id1" "$id2"
  assert_eq "$(wc -l < "$dir/repair-tickets.jsonl" | tr -d ' ')" "1" "equivalents collapse to one row"
}

test_requeue_increments_to_cap_then_exhausted_and_visible() {
  local dir="$TMP/requeue"; mkdir -p "$dir"
  local fp tid out rc=0
  fp=$(ceo_finding_fingerprint o/r abc "t.sh" "l.sh:1" "MED")
  tid=$(ceo_ticket_dedup "$dir" "$fp" '{"summary":"x"}')
  assert_eq "$(ceo_requeue_decide "$dir" "$tid" 2)" "retry:1"
  assert_eq "$(ceo_requeue_decide "$dir" "$tid" 2)" "retry:2"
  out=$(ceo_requeue_decide "$dir" "$tid" 2 2>/dev/null) || rc=$?
  assert_eq "$out" "exhausted"
  assert_eq "$rc" "3" "exhaustion is loud, distinguishable from generic failure"
  assert_file_exists "$dir/exhausted.jsonl"
  assert_contains "$(cat "$dir/exhausted.jsonl")" "$tid"
}

test_route_primary_selection() {
  assert_contains "$(ceo_route_select "$TMP/routes.json" "bug-fix")" '"provider":"ollama"'
}

test_route_unknown_shape_is_loud_with_shape_named() {
  local out rc=0
  out=$(ceo_route_select "$TMP/routes.json" "unknown-shape" 2>&1) || rc=$?
  assert_contains "$out" "unknown-shape"
}

test_failover_reroutes_past_failed_provider_model() {
  assert_contains \
    "$(ceo_route_failover "$TMP/routes.json" "bug-fix" "ollama" "qwen2.5-coder:7b")" \
    '"provider":"opencode"'
}

test_failover_exhausting_every_fallback_exits_loudly() {
  local out rc=0
  out=$(ceo_route_failover "$TMP/routes.json" "bug-fix" "opencode" "kimi-k3" 2>&1) || rc=$?
  assert_contains "$out" "no fallback left"
}

test_review_author_cannot_be_its_own_only_reviewer() {
  local out rc=0
  out=$(ceo_review_gate "ollama/qwen3.8:27b" 2>&1) || rc=$?
  assert_contains "$out" "no reviewer"
}

test_review_same_provider_only_panel_is_refused() {
  local out rc=0
  out=$(ceo_review_gate "ollama/qwen" "ollama/qwen-turbo" 2>&1) || rc=$?
  assert_contains "$out" "cross-provider review required"
}

test_review_one_different_provider_reviewer_passes_and_is_echoed() {
  assert_eq \
    "$(ceo_review_gate "ollama/qwen" "ollama/qwen-turbo" "opencode/kimi-k3")" \
    "opencode/kimi-k3"
}

test_workers_overlapping_file_registration_is_refused_naming_conflict() {
  local dir="$TMP/workers"; mkdir -p "$dir"
  local out rc=0
  ceo_worker_register "$dir" "nh/a" "aaa111" "lib/util.sh" "src/app.ts"
  out=$(ceo_worker_register "$dir" "nh/b" "bbb222" "src/other.ts" "lib/util.sh" 2>&1) || rc=$?
  assert_contains "$out" "nh/a"
  assert_contains "$out" "lib/util.sh"
}

test_workers_disjoint_files_coexist() {
  local dir="$TMP/workers2"; mkdir -p "$dir"
  ceo_worker_register "$dir" "nh/a" "aaa" "lib/util.sh"
  ceo_worker_register "$dir" "nh/b" "bbb" "src/app.ts"
  assert_eq "$(wc -l < "$dir/workers.jsonl" | tr -d ' ')" "2"
}

test_workers_release_frees_files_for_next_worker() {
  local dir="$TMP/workers3"; mkdir -p "$dir"
  ceo_worker_register "$dir" "nh/a" "aaa" "lib/util.sh"
  ceo_worker_release "$dir" "nh/a"
  ceo_worker_register "$dir" "nh/b" "bbb" "lib/util.sh"
  assert_eq "$(wc -l < "$dir/workers.jsonl" | tr -d ' ')" "1"
}

test_stale_base_same_sha_fresh_different_sha_stale() {
  ceo_base_stale "abc123" "abc123"
  assert_fails "different shas are stale" test ceo_base_stale "abc123" "def456"
}

test_promotion_high_risk_to_production_main_without_approval_blocked_hard() {
  local out rc=0
  out=$(CEO_LOOP_ALLOW_MAIN=1 ceo_promotion_gate high main main "") || rc=$?
  assert_eq "$out" "blocked-premium"
  assert_eq "$rc" "7" "premium gate is a hard stop, not advisory"
}

test_promotion_high_risk_with_premium_approval_evidence_promotes() {
  : > "$TMP/premium-approval.md"
  assert_eq "$(ceo_promotion_gate high main main "$TMP/premium-approval.md")" "promote"
}

test_promotion_low_risk_defaults_to_integration_branch() {
  assert_eq "$(CEO_LOOP_ALLOW_MAIN=0 ceo_promotion_gate low main main "")" "park-integration"
}

test_promotion_policy_enabled_low_risk_may_reach_main() {
  assert_eq "$(CEO_LOOP_ALLOW_MAIN=1 ceo_promotion_gate low main main "")" "promote"
}

test_promotion_integration_branch_targets_always_promote() {
  assert_eq "$(ceo_promotion_gate high integration main "")" "promote"
}

run_tests
