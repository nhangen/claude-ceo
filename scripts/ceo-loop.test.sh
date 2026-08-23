#!/usr/bin/env bash
# ceo-loop.test.sh — the #329 loop driven against REAL git repositories.
# Workers and reviewers are stub commands that actually run; branches,
# worktrees, diffs, promotions, and tickets are real state.
set -euo pipefail
cd "$(dirname "$0")"
source ./test-harness.sh

LIB_DIR="$(pwd)"
# shellcheck source=ceo-loop-lib.sh
source ./ceo-loop-lib.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOOP="$LIB_DIR/ceo-loop.sh"

CEO_LOOP_STATE_ROOT="$TMP/state"
export CEO_LOOP_STATE_ROOT
OLLAMA_AGENT_LEDGER="$TMP/ledger/runs.jsonl"
export OLLAMA_AGENT_LEDGER

REPO_N=0
STATE_N=0
fresh_state() { # isolate each test's loop state so order can never matter
  STATE_N=$((STATE_N + 1))
  CEO_LOOP_STATE_ROOT="$TMP/state-$STATE_N"
  export CEO_LOOP_STATE_ROOT
}

mkrepo() { # <name> — a real git repo with one commit on main
  fresh_state
  local dir="$TMP/repos/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo base > "$dir/base.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm init
  echo "$dir"
}

mkroutes() { # <file> <worker-script> <reviewer-script> [reviewer2-script]
  cat > "$1" <<JSON
{
  "candidates": [
    {"provider": "ollama", "model": "qwen-test", "command": "$2"},
    {"provider": "opencode", "model": "kimi-test", "command": "$3"}
  ],
  "reviewers": [
    {"provider": "opencode", "model": "kimi-test", "command": "${4:-true}"}
  ]
}
JSON
}

mkspec() { # <file> <repo-dir> <branch> <verify-cmd>
  jq -n --arg repo "$(basename "$2")-$3" --arg dir "$2" --arg branch "$3" \
    --arg verify "$4" \
    '{repo: $repo, repo_dir: $dir, branch: $branch, shape: "bug-fix",
      verify_cmd: $verify}' > "$1"
}

WORKER_WRITE='cd "$WT" && echo feature > feature.txt'
export WORKER_WRITE WORKER_FAIL=false

write_script() { # <path> <body> — exec bit required: routes run commands directly
  printf '#!/bin/bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

test_happy_path_creates_real_branch_and_commits_and_promotes() {
  local repo; repo="$(mkrepo happy)"
  local wscript="${TMP}/w-ok.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-happy.json" "$wscript" true
  mkspec "$TMP/happy.json" "$repo" nh/loop-happy "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/happy.json" --routes "$TMP/routes-happy.json" --target main) || rc=$?
  assert_contains "$out" "isolated branch nh/loop-happy"
  assert_contains "$out" "cross-provider reviewer opencode/kimi-test"
  assert_eq "$rc" "0"
  # Policy default: low-risk work parks on its branch; main is untouched.
  assert_contains "$out" "action=parked"
  assert_eq "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse "$(git -C "$repo" rev-list --max-parents=0 HEAD)")"
  # REAL git state: the branch exists with the worker's commit merged in.
  assert_eq "$(git -C "$repo" rev-parse --verify -q nh/loop-happy >/dev/null && echo yes || echo no)" "yes"
  assert_eq "$(git -C "$repo" show nh/loop-happy:feature.txt 2>/dev/null)" "feature"
  # With policy explicitly allowing main, promotion fast-forwards.
  out=$(CEO_LOOP_ALLOW_MAIN=1 bash "$LOOP" run --spec "$TMP/happy.json" --routes "$TMP/routes-happy.json" --target main) || rc=$?
  assert_contains "$out" "fast-forward"
  assert_eq "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse nh/loop-happy)"
  # Slot released after completion.
  if grep -q "nh/loop-happy" "$CEO_LOOP_STATE_ROOT/$(basename "$repo")-nh_loop-happy/workers.jsonl" 2>/dev/null || \
     grep -rq "nh/loop-happy" "$CEO_LOOP_STATE_ROOT"/*/workers.jsonl 2>/dev/null; then
    fail_test "completed run must not keep its serialization slot"
  fi
  # Telemetry carries the required metrics.
  local tel slug_dir
  slug_dir=$(find "$CEO_LOOP_STATE_ROOT" -name telemetry.jsonl -path "*happy*" | head -1)
  tel=$(cat "$slug_dir")
  assert_contains "$tel" '"retries_used":0'
  assert_contains "$tel" '"accepted":true'
  assert_contains "$tel" '"reviewer":"opencode/kimi-test"'
}

test_failing_verification_blocks_promotion_and_files_ticket() {
  local repo; repo="$(mkrepo failing)"
  local wscript="${TMP}/w-fail.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-fail.json" "$wscript" true
  mkspec "$TMP/fail.json" "$repo" nh/loop-fail "false"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/fail.json" --routes "$TMP/routes-fail.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "verification failed"
  if [ "$rc" = "0" ]; then fail_test "failing verification must not exit clean"; fi
  # Production condition: main did NOT move.
  assert_eq "$(git -C "$repo" rev-parse main)" "$(git -C "$repo" rev-parse "$(git -C "$repo" rev-list --max-parents=0 HEAD)")"
  # A repair ticket exists for the verification failure with required fields.
  local row
  row=$(grep -rh "verification failed" "$CEO_LOOP_STATE_ROOT" --include="repair-tickets.jsonl" | head -1)
  assert_contains "$row" '"owner"'
  assert_contains "$row" '"definition_of_done":"verify_cmd exits 0 inside the worktree"'
  assert_contains "$row" '"failing_test":"false"'
}

test_high_findings_block_promotion_with_full_ticket_schema() {
  local repo; repo="$(mkrepo highfind)"
  local wscript="${TMP}/w-high.sh"; write_script "$wscript" 'cd "$WT" && mkdir -p src/lib && echo x > src/lib/util.sh' 
  local rscript="${TMP}/r-high.sh"
  cat > "$rscript" <<'EOF'
#!/bin/bash
echo '{"invariant":"no SQL injection in helper","location":"src/lib/util.sh:7","severity":"HIGH"}'
EOF
  chmod +x "$rscript"
  mkroutes "$TMP/routes-high.json" "$wscript" true "$rscript"
  mkspec "$TMP/high.json" "$repo" nh/loop-high "true"
  git -C "$repo" branch integration   # a real integration target exists
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/high.json" --routes "$TMP/routes-high.json" --target integration 2>&1) || rc=$?
  if [ "$rc" = "0" ]; then fail_test "HIGH findings must block acceptance (exit 5)"; fi
  assert_contains "$out" "HIGH finding(s) block promotion"
  local row
  row=$(grep -rh "SQL injection" "$CEO_LOOP_STATE_ROOT" --include="repair-tickets.jsonl" | head -1)
  assert_contains "$row" '"owner":"unassigned"'
  assert_contains "$row" '"severity":"HIGH"'
  assert_contains "$row" '"external_id":null'
  # The HIGH-risk change was NOT promoted anywhere.
  if grep -q "promoted" <<<"$out"; then fail_test "HIGH finding must prevent promotion"; fi
}

test_stale_base_stops_before_any_work() {
  local repo; repo="$(mkrepo stale)"
  local sha; sha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" commit -q --allow-empty -m advance
  mkroutes "$TMP/routes-stale.json" true true
  mkspec "$TMP/stale.json" "$repo" nh/loop-stale "true"
  # The spec declares the revision its work was cut from.
  jq '.base = "'"$sha"'"' "$TMP/stale.json" > "$TMP/stale2.json" && mv "$TMP/stale2.json" "$TMP/stale.json"
  local out rc=0 new_tip
  new_tip=$(git -C "$repo" rev-parse HEAD)   # target has advanced past spec.base
  out=$(bash "$LOOP" run --spec "$TMP/stale.json" --routes "$TMP/routes-stale.json" \
    --target main --current-base "$new_tip" 2>&1) || rc=$?
  assert_contains "$out" "STALE BASE"
  assert_eq "$rc" "9"
  # Stale base stops at the door: no worktree was ever created.
  if [ -e "$repo/.ceo-loop" ]; then fail_test "stale-base check must precede worktree creation"; fi
}

test_premium_approval_is_bound_to_the_change_digest() {
  local repo; repo="$(mkrepo premium)"
  local wscript="${TMP}/w-mig.sh"
  write_script "$wscript" 'cd "$WT" && mkdir -p db && echo up > db/migrate.ts' 
  mkroutes "$TMP/routes-prem.json" "$wscript" true
  mkspec "$TMP/prem.json" "$repo" nh/loop-prem "true"

  # No approval at all -> hard stop.
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/prem.json" --routes "$TMP/routes-prem.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "BLOCKED"
  assert_eq "$rc" "7"
  # The gate prints the digest it needs — capture it from state/telemetry-free path:
  local digest slug
  slug=$(jq -r '.repo' "$TMP/prem.json" | tr '/' '-')
  digest=$(ceo_change_digest "$slug" "$(git -C "$repo" rev-parse main)" "db/migrate.ts")

  # An approval for a DIFFERENT change must NOT unlock this one.
  printf '%s\n' "{\"approved_by\":\"n\",\"ticket\":\"t-1\",\"change_digest\":\"deadbeef\"}" > "$TMP/approval-wrong.json"
  out=$(CEO_LOOP_PREMIUM_APPROVAL="$TMP/approval-wrong.json" \
    bash "$LOOP" run --spec "$TMP/prem.json" --routes "$TMP/routes-prem.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "7"

  # Approval bound to THIS change's digest unlocks it.
  printf '%s\n' "{\"approved_by\":\"nhangen\",\"ticket\":\"CEO/premium-9\",\"change_digest\":\"$digest\"}" > "$TMP/approval-ok.json"
  rc=0
  out=$(CEO_LOOP_PREMIUM_APPROVAL="$TMP/approval-ok.json" \
    bash "$LOOP" run --spec "$TMP/prem.json" --routes "$TMP/routes-prem.json" --target main 2>&1) || rc=$?
  if [ "$rc" != "0" ]; then
    fail_test "bound approval must promote (rc=$rc digest=$digest)" "$out"
    return 0
  fi
  assert_contains "$out" "fast-forward"
}

test_same_branch_registers_once_and_release_clears_it() {
  local repo; repo="$(mkrepo dupreg)"
  local slug; slug="$(basename "$repo")-nh_dup"
  local dir="$CEO_LOOP_STATE_ROOT/$slug"
  mkdir -p "$dir"
  ceo_worker_register "$dir" "nh/dup" "aaa" "a.sh"
  ceo_worker_register "$dir" "nh/dup" "bbb" "a.sh"
  assert_eq "$(wc -l < "$dir/workers.jsonl" | tr -d ' ')" "1" "re-registration replaces, never stacks"
  ceo_worker_release "$dir" "nh/dup"
  assert_eq "$(wc -l < "$dir/workers.jsonl" | tr -d ' ')" "0"
}

test_multiword_verify_commands_run_as_shell_input() {
  local repo; repo="$(mkrepo multiword)"
  local wscript="${TMP}/w-mv.sh"; write_script "$wscript" 'cd "$WT" && echo hi > out.txt' 
  mkroutes "$TMP/routes-mv.json" "$wscript" true
  mkspec "$TMP/mv.json" "$repo" nh/loop-mv "echo started && test -f out.txt && grep -q hi out.txt"
  local out rc=0
  # Policy allows main so the accepted work actually promotes.
  out=$(CEO_LOOP_ALLOW_MAIN=1 bash "$LOOP" run --spec "$TMP/mv.json" --routes "$TMP/routes-mv.json" --target main) || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$out" "action=promoted"
}

test_provider_failure_reroutes_to_next_candidate() {
  local repo; repo="$(mkrepo reroute)"
  # Primary (ollama) fails; backup (opencode) delivers. Reviewer must differ
  # from the ACTUAL author after failover, hence anthropic here.
  local wbackup="${TMP}/w-backup.sh"
  write_script "$wbackup" 'cd "$WT" && echo rescued > rescued.txt'
  cat > "$TMP/routes-reroute.json" <<JSON
{"candidates": [
    {"provider": "ollama", "model": "qwen-test", "command": "false"},
    {"provider": "opencode", "model": "kimi-test", "command": "$wbackup"}
  ],
  "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "true"}]}
JSON
  mkspec "$TMP/reroute.json" "$repo" nh/loop-reroute "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/reroute.json" --routes "$TMP/routes-reroute.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "trying next candidate"
  assert_eq "$rc" "0"
  assert_contains "$(git -C "$repo" show nh/loop-reroute:rescued.txt 2>/dev/null)" "rescued"
}

test_requeue_dispatches_another_attempt_then_exhausts_visibly() {
  local repo; repo="$(mkrepo requeue)"
  # Worker always delivers; VERIFICATION fails on attempt 1 only. A bounded
  # requeue must DISPATCH another worker attempt (counter proves it ran).
  local counter="$TMP/attempt-counter"; echo 0 > "$counter"
  # Worker increments the attempt counter every time it is dispatched.
  local wok="${TMP}/w-ok2.sh"
  write_script "$wok" "cd \"\$WT\" && echo ok > ok.txt && n=\$(cat '$counter') && echo \$((n+1)) > '$counter'"
  mkroutes "$TMP/routes-requeue.json" "$wok" true
  mkspec "$TMP/requeue.json" "$repo" nh/loop-requeue \
    "[ \$(cat $counter) -ge 2 ]"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/requeue.json" --routes "$TMP/routes-requeue.json" \
    --target main 2>&1) || rc=$?
  assert_eq "$(cat "$counter")" "2" "second attempt must actually dispatch"
  assert_eq "$rc" "0"
  local tel slug_dir
  slug_dir=$(find "$CEO_LOOP_STATE_ROOT" -name telemetry.jsonl -path "*requeue*" | head -1)
  tel=$(cat "$slug_dir")
  assert_contains "$tel" '"retries_used":1'

  # Exhaustion: always-failing verification burns the cap -> exhausted.jsonl.
  local repo2; repo2="$(mkrepo exhaust)"
  mkroutes "$TMP/routes-exh.json" "$wok" true
  mkspec "$TMP/exh.json" "$repo2" nh/loop-exh "false"
  rc=0
  out=$(CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/exh.json" --routes "$TMP/routes-exh.json" --target main 2>&1) || rc=$?
  if [ "$rc" = "0" ]; then fail_test "exhausted retries must not exit clean"; fi
  assert_file_exists "$(find "$CEO_LOOP_STATE_ROOT" -name exhausted.jsonl | head -1)"
}

test_risk_map_catches_filename_shaped_blast_radii() {
  for p in src/billing.ts src/payments.ts db/migrate.ts src/save-user.ts lib/auth.ts secrets.json; do
    assert_eq "$(ceo_risk_classify "$LIB_DIR/ceo-risk-map.json" "$p")" "high" "$p is high risk"
  done
  assert_eq "$(ceo_risk_classify "$LIB_DIR/ceo-risk-map.json" "docs/guide.md")" "low"
}

test_same_provider_only_reviewers_are_refused_e2e() {
  local repo; repo="$(mkrepo sametier)"
  local wscript="${TMP}/w-same.sh"; write_script "$wscript" 'cd "$WT" && echo z > z.txt' 
  cat > "$TMP/routes-same.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen", "command": "$wscript"}],
 "reviewers": [{"provider": "ollama", "model": "qwen-big", "command": "true"}]}
JSON
  mkspec "$TMP/same.json" "$repo" nh/loop-same "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/same.json" --routes "$TMP/routes-same.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "review gate failed"
  assert_eq "$rc" "5"
}

run_tests
