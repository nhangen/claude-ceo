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

STATE_N=0
fresh_state() { # isolate each test's loop state so order can never matter
  STATE_N=$((STATE_N + 1))
  CEO_LOOP_STATE_ROOT="$TMP/state-$STATE_N"
  export CEO_LOOP_STATE_ROOT
}

mkrepo() { # <name> — a real git repo with one commit on main
  local dir="$TMP/repos/$1"
  # Convention (#351): a fixture-builder guard is tested beside its builder, in
  # the suite that defines it. The sibling guards are mkrepo_cleanup and
  # mkclone_cleanup in ceo-cleanup.test.sh, each with its own arm there.
  [ ! -e "$dir" ] || { echo "mkrepo: duplicate fixture name '$1'" >&2; return 1; }
  fresh_state
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  # Without this the fixture inherits the machine's global core.hooksPath, and
  # every arm that commits or checks out runs whatever the developer has wired
  # there. Point it at the fixture's own hooks dir rather than /dev/null:
  # test_a_rejected_commit_is_not_reported_as_accepted_work installs a repo-local
  # pre-commit and needs it to fire.
  git -C "$dir" config core.hooksPath "$dir/.git/hooks"
  echo base > "$dir/base.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm init
  echo "$dir"
}

mkroutes() { # <file> <worker-script> <reviewer-script> [reviewer2-script]
  # Built by jq: worker/reviewer commands may contain any quoting.
  jq -n --arg w "$2" --arg b "$3" \
    --arg r "${4:-echo '{\"status\":\"clean\"}'}" \
    '{candidates: [
       {provider: "ollama", model: "qwen-test", command: $w},
       {provider: "opencode", model: "kimi-test", command: $b}],
      reviewers: [
       {provider: "opencode", model: "kimi-test", command: $r}]}' > "$1"
}

mkspec() { # <file> <repo-dir> <branch> <verify-cmd>
  jq -n --arg repo "$(basename "$2")-$3" --arg dir "$2" --arg branch "$3" \
    --arg verify "$4" \
    '{repo: $repo, repo_dir: $dir, branch: $branch, shape: "bug-fix",
      verify_cmd: $verify}' > "$1"
}

# The body of the default worker, written into a script file by write_script.
# Not exported: it is passed as an argument, never inherited.
WORKER_WRITE='cd "$WT" && echo feature > feature.txt'

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
  assert_eq "$rc" "5" "HIGH findings must exit exactly 5"
  assert_contains "$out" "HIGH finding(s) block promotion"
  local row
  row=$(grep -rh "SQL injection" "$CEO_LOOP_STATE_ROOT" --include="repair-tickets.jsonl" | head -1)
  assert_contains "$row" '"owner":"unassigned"'
  assert_contains "$row" '"severity":"HIGH"'
  assert_contains "$row" '"external_id":null'
  # The HIGH-risk change was NOT promoted anywhere.
  if grep -q "promoted" <<<"$out"; then fail_test "HIGH finding must prevent promotion"; fi
  # #343's second instance: the summary used to print the gate's RECOMMENDATION
  # (`action=promote`) on a run that was blocked and exited 5, so a reader of
  # the summary line saw a promotion that never happened.
  assert_contains "$out" "action=blocked"
  assert_not_contains "$out" "action=promote "
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
  "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "echo '{\"status\":\"clean\"}'"}]}
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
  assert_eq "$rc" "3" "first failing run exits 3 (requeued)"
  # Second run spends the last retry slot; third hits the cap visibly.
  CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/exh.json" --routes "$TMP/routes-exh.json" --target main >/dev/null 2>&1 || true
  rc=0
  out=$(CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/exh.json" --routes "$TMP/routes-exh.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "retries EXHAUSTED"
  assert_eq "$rc" "3" "exhaustion maps to exit 3"
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


test_all_candidates_failing_exits_4() {
  local repo; repo="$(mkrepo alldead)"
  cat > "$TMP/routes-dead.json" <<JSON
{"candidates": [
    {"provider": "ollama", "model": "q1", "command": "false"},
    {"provider": "opencode", "model": "k1", "command": "false"}
  ],
  "reviewers": [{"provider": "anthropic", "model": "c", "command": "echo '{\"status\":\"clean\"}'"}]}
JSON
  mkspec "$TMP/alldead.json" "$repo" nh/loop-dead "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/alldead.json" --routes "$TMP/routes-dead.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "every routed candidate failed"
  assert_eq "$rc" "4"
}

test_missing_verify_cmd_is_usage_error_exit_2() {
  local repo; repo="$(mkrepo noverify)"
  jq -n --arg repo t --arg dir "$repo" --arg branch nh/x \
    '{repo:$repo,repo_dir:$dir,branch:$branch,shape:"bug-fix"}' > "$TMP/noverify.json"
  mkroutes "$TMP/routes-nv.json" true true
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/noverify.json" --routes "$TMP/routes-nv.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "missing required field"
  assert_eq "$rc" "2"
}

test_worker_that_writes_nothing_refuses_to_classify() {
  local repo; repo="$(mkrepo nowrite)"
  mkroutes "$TMP/routes-nowrite.json" true true
  mkspec "$TMP/nowrite.json" "$repo" nh/loop-nowrite "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/nowrite.json" --routes "$TMP/routes-nowrite.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "no changed files"
  assert_eq "$rc" "2"
}

test_declared_files_never_replace_the_diff_for_risk() {
  local repo; repo="$(mkrepo declared)"
  # Spec CLAIMS a benign docs change; worker actually writes billing code.
  local wscript="${TMP}/w-lie.sh"
  write_script "$wscript" 'cd "$WT" && mkdir -p src/billing && echo charge > src/billing/charge.ts'
  mkroutes "$TMP/routes-declared.json" "$wscript" true
  jq -n --arg repo "declared-nh-loop-declared" --arg dir "$repo" --arg branch nh/loop-declared \
    --arg verify true --argjson files '["docs/notes.md"]' \
    '{repo:$repo,repo_dir:$dir,branch:$branch,shape:"bug-fix",verify_cmd:$verify,files:$files}' > "$TMP/declared.json"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/declared.json" --routes "$TMP/routes-declared.json" --target main 2>&1) || rc=$?
  # Diff-derived risk is high -> premium block, regardless of the benign claim.
  assert_contains "$out" "BLOCKED"
  assert_eq "$rc" "7"
}

test_reviewer_that_fails_to_run_is_not_a_pass() {
  local repo; repo="$(mkrepo deadrev)"
  local wscript="${TMP}/w-dr.sh"; write_script "$wscript" 'cd "$WT" && echo q > q.txt'
  cat > "$TMP/routes-deadrev.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen-test", "command": "$wscript"}],
 "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "false"}]}
JSON
  mkspec "$TMP/deadrev.json" "$repo" nh/loop-deadrev "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/deadrev.json" --routes "$TMP/routes-deadrev.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "review gate failed"
  assert_eq "$rc" "5"
}

test_premium_digest_binds_each_input_dimension() {
  source_lib_digest() {
    # Independent implementation of the documented format: repo|base|files,
    # files sorted, comma-joined with a trailing comma.
    local files="$3"
    [ -n "$files" ] && files="$files,"
    printf '%s' "$1|$2|$files" | shasum -a 256 | cut -d" " -f1
  }
  local d1 d2 d3 d4
  d1=$(ceo_change_digest r abc f.sh)
  assert_eq "$d1" "$(source_lib_digest r abc f.sh)" "digest matches independent computation"
  d2=$(ceo_change_digest r def f.sh)
  if [ "$d1" = "$d2" ]; then fail_test "base revision must bind the digest"; fi
  d3=$(ceo_change_digest r abc g.sh)
  if [ "$d1" = "$d3" ]; then fail_test "file set must bind the digest"; fi
  d4=$(ceo_change_digest other abc f.sh)
  if [ "$d1" = "$d4" ]; then fail_test "repo must bind the digest"; fi
}


test_finding_tickets_requeue_and_exhaust_not_just_verify_ones() {
  local repo; repo="$(mkrepo findingrequeue)"
  local wscript="${TMP}/w-fr.sh"; write_script "$wscript" 'cd "$WT" && mkdir -p src/lib && echo q > src/lib/util.sh'
  local rscript="${TMP}/r-fr.sh"
  cat > "$rscript" <<'EOF'
#!/bin/bash
echo '{"invariant":"helper stays pure","location":"src/lib/util.sh:7","severity":"MEDIUM"}'
EOF
  chmod +x "$rscript"
  cat > "$TMP/routes-fr.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen-test", "command": "$wscript"}],
 "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "$rscript"}]}
JSON
  mkspec "$TMP/fr.json" "$repo" nh/loop-fr "false"   # work fails verification too
  git -C "$repo" branch integration
  for _ in 1 2 3; do
    CEO_LOOP_MAX_RETRIES=1 bash "$LOOP" run --spec "$TMP/fr.json" --routes "$TMP/routes-fr.json" \
      --target integration >/dev/null 2>&1 || true
  done
  # The FINDING's own ticket must reach exhaustion, not just the verify one.
  local exh
  exh=$(find "$CEO_LOOP_STATE_ROOT" -path "*findingrequeue*" -name exhausted.jsonl -exec cat {} \;)
  assert_contains "$exh" "helper stays pure"
}


test_finding_without_severity_fails_closed_to_high() {
  local repo; repo="$(mkrepo nosev)"
  local wscript="${TMP}/w-ns.sh"; write_script "$wscript" 'cd "$WT" && mkdir -p src/lib && echo q > src/lib/util.sh'
  local rscript="${TMP}/r-ns.sh"
  cat > "$rscript" <<'EOF'
#!/bin/bash
echo '{"invariant":"unlabeled finding","location":"src/lib/util.sh:9"}'
EOF
  chmod +x "$rscript"
  cat > "$TMP/routes-ns.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen-test", "command": "$wscript"}],
 "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "$rscript"}]}
JSON
  mkspec "$TMP/ns.json" "$repo" nh/loop-ns "true"
  git -C "$repo" branch integration
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/ns.json" --routes "$TMP/routes-ns.json" --target integration 2>&1) || rc=$?
  assert_eq "$rc" "5" "unlabeled severity is treated as HIGH and blocks"
  assert_contains "$(grep -rh "unlabeled finding" "$CEO_LOOP_STATE_ROOT" --include="repair-tickets.jsonl")" '"severity":"high"'
}

test_refuses_to_delete_a_branch_the_loop_did_not_create() {
  # #332: "this loop owns the branch" was an assumption, not a check. A spec
  # whose .branch collides with existing work force-deleted it and exited 0.
  local repo; repo="$(mkrepo reclaim)"
  git -C "$repo" checkout -q -b important-work
  echo irreplaceable > "$repo/only-here.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "work that exists nowhere else"
  local doomed; doomed="$(git -C "$repo" rev-parse important-work)"
  git -C "$repo" checkout -q main
  local wscript="${TMP}/w-reclaim.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-reclaim.json" "$wscript" true
  mkspec "$TMP/reclaim.json" "$repo" important-work "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/reclaim.json" --routes "$TMP/routes-reclaim.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "6" "a branch the loop cannot prove it created is refused, not deleted"
  assert_contains "$out" "was not created by ceo-loop"
  assert_eq "$(git -C "$repo" rev-parse important-work 2>/dev/null || echo GONE)" "$doomed" \
    "the pre-existing branch still points at its own commit"
}

test_reclaims_its_own_branch_across_runs() {
  # The refusal above must not break the reclaim it replaces: a branch this
  # loop created is still reclaimable on the next run.
  local repo; repo="$(mkrepo reown)"
  local wscript="${TMP}/w-reown.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-reown.json" "$wscript" true
  mkspec "$TMP/reown.json" "$repo" nh/loop-reown "true"
  bash "$LOOP" run --spec "$TMP/reown.json" --routes "$TMP/routes-reown.json" --target main >/dev/null 2>&1 || true
  assert_eq "$(git -C "$repo" for-each-ref --format='%(objectname)' refs/ceo-loop/owned \
    | grep -cx "$(git -C "$repo" rev-parse nh/loop-reown)")" "1" \
    "the loop records ownership pointing at the branch tip it created"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/reown.json" --routes "$TMP/routes-reown.json" --target main 2>&1) || rc=$?
  assert_not_contains "$out" "was not created by ceo-loop"
  assert_contains "$out" "isolated branch nh/loop-reown"
}

test_rejects_a_branch_name_git_would_not_accept() {
  # ".." survives the ${BRANCH//\//_} collapse untouched, so WT resolved to
  # $REPO_DIR and line 198's rm -rf targeted the repo root. Only rm's own
  # refusal to unlink ".." prevented the deletion.
  local repo; repo="$(mkrepo badname)"
  local wscript="${TMP}/w-bad.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-bad.json" "$wscript" true
  mkspec "$TMP/bad.json" "$repo" .. "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/bad.json" --routes "$TMP/routes-bad.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "2" "an invalid branch name is rejected at spec validation"
  assert_contains "$out" "not a valid git branch name"
  assert_file_exists "$repo/base.txt"
}

test_a_stale_ownership_marker_does_not_authorize_deleting_a_stranger() {
  # #332 audit: the marker must vouch for the branch that is there NOW. A name
  # freed after a merge and later reused by a person left the old marker
  # standing, and the loop deleted their branch on the strength of it.
  local repo; repo="$(mkrepo reusedname)"
  local wscript="${TMP}/w-reused.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-reused.json" "$wscript" true
  mkspec "$TMP/reused.json" "$repo" nh/reused "true"
  bash "$LOOP" run --spec "$TMP/reused.json" --routes "$TMP/routes-reused.json" --target main >/dev/null 2>&1 || true
  # The branch is merged and deleted, as it would be after a PR lands.
  git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' \
    | while read -r w; do git -C "$repo" worktree remove --force --force "$w" 2>/dev/null || true; done
  git -C "$repo" worktree prune
  git -C "$repo" branch -D nh/reused >/dev/null 2>&1 || true
  # A person now reuses the freed name for unrelated work.
  git -C "$repo" checkout -q -b nh/reused main
  echo mine > "$repo/human-only.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "human work on a reused name"
  local doomed; doomed="$(git -C "$repo" rev-parse nh/reused)"
  git -C "$repo" checkout -q main
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/reused.json" --routes "$TMP/routes-reused.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "6" "a marker that no longer matches the branch tip proves nothing"
  assert_eq "$(git -C "$repo" rev-parse nh/reused 2>/dev/null || echo GONE)" "$doomed" \
    "the human branch that reused the name still points at its own commit"
  assert_eq "$(git -C "$repo" cat-file -e nh/reused:human-only.txt 2>/dev/null && echo yes || echo no)" \
    "yes" "the human commit's content is still reachable"
}

test_ownership_markers_do_not_collide_across_nested_branch_names() {
  # A ref namespace keyed on the branch name cannot hold both "topic" and
  # "topic/sub": one loose ref would have to be a file and a directory.
  local repo; repo="$(mkrepo nested)"
  local wscript="${TMP}/w-nested.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-nested.json" "$wscript" true
  mkspec "$TMP/nested-a.json" "$repo" topic/sub "true"
  bash "$LOOP" run --spec "$TMP/nested-a.json" --routes "$TMP/routes-nested.json" --target main >/dev/null 2>&1 || true
  git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' \
    | while read -r w; do git -C "$repo" worktree remove --force --force "$w" 2>/dev/null || true; done
  git -C "$repo" worktree prune
  git -C "$repo" branch -D topic/sub >/dev/null 2>&1 || true
  mkspec "$TMP/nested-b.json" "$repo" topic "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/nested-b.json" --routes "$TMP/routes-nested.json" --target main 2>&1) || rc=$?
  assert_not_contains "$out" "could not record ownership"
  assert_not_contains "$out" "was not created by ceo-loop"
  assert_eq "$rc" "0" "a branch whose name is a prefix of an owned one still runs"
}

test_two_branch_names_never_share_one_worktree_directory() {
  # WT collapsed "/" to "_", so nh/loop-x and the literal nh_loop-x landed in
  # the same directory and the second run evicted the first run's worktree.
  local repo; repo="$(mkrepo collapse)"
  local wscript="${TMP}/w-collapse.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-collapse.json" "$wscript" true
  mkspec "$TMP/collapse-a.json" "$repo" nh/loop-x "true"
  bash "$LOOP" run --spec "$TMP/collapse-a.json" --routes "$TMP/routes-collapse.json" --target main >/dev/null 2>&1 || true
  local before; before="$(git -C "$repo" worktree list | grep -c 'ceo-loop' || true)"
  mkspec "$TMP/collapse-b.json" "$repo" nh_loop-x "true"
  bash "$LOOP" run --spec "$TMP/collapse-b.json" --routes "$TMP/routes-collapse.json" --target main >/dev/null 2>&1 || true
  assert_eq "$(git -C "$repo" worktree list | grep -c 'ceo-loop' || true)" "$((before + 1))" \
    "the second branch gets its own worktree instead of evicting the first"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-x >/dev/null && echo yes || echo no)" \
    "yes" "the first branch survives the second run"
}

test_rejects_a_branch_name_that_would_be_read_as_an_option() {
  # git check-ref-format accepts a leading dash; only `checkout -b` happens to
  # refuse it later, and every other interpolation of $BRANCH would not.
  # Rejection at spec validation avoids leaving an orphaned worktree at
  # .ceo-loop/-oProxyCommand=x-<hash>.
  local repo; repo="$(mkrepo dashname)"
  local wscript="${TMP}/w-dash.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-dash.json" "$wscript" true
  mkspec "$TMP/dash.json" "$repo" -oProxyCommand=x "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/dash.json" --routes "$TMP/routes-dash.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "2" "a branch name starting with - is rejected at spec validation"
  assert_contains "$out" "not a valid git branch name"
  assert_eq "$(git -C "$repo" worktree list | grep -c "\.ceo-loop" || true)" "0" \
    "no worktree is registered when a dash branch name is rejected"
  # The registration grep cannot see a directory created but never registered,
  # which is the shape a run killed between `worktree add` and `checkout -b`
  # leaves behind.
  assert_eq "$([ -d "$repo/.ceo-loop" ] && echo yes || echo no)" "no" \
    "no worktree directory is created under .ceo-loop either"
}

test_a_rejected_commit_is_not_reported_as_accepted_work() {
  # The loop's whole file-list contract rests on the worker's output being
  # committed: FILES comes from `git diff --name-only "$CURRENT_BASE"`, which
  # reads the WORKING TREE. With the commit swallowed, the risk classifier and
  # the reviewers see a change the branch does not hold, the run prints "holds
  # accepted work", and ceo_claim_branch certifies the empty branch as owned.
  local repo; repo="$(mkrepo rejectedcommit)"
  printf '#!/bin/sh\nexit 1\n' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  local wscript="${TMP}/w-rej.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-rej.json" "$wscript" true
  mkspec "$TMP/rej.json" "$repo" nh/loop-rej "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/rej.json" --routes "$TMP/routes-rej.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "6" "a rejected commit stops the run instead of certifying an empty branch"
  assert_not_contains "$out" "holds accepted work"
  assert_eq "$(git -C "$repo" log --oneline main..nh/loop-rej 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "the branch is empty — which is exactly why the run must not claim otherwise"
}

test_a_failed_stage_is_not_reported_as_accepted_work() {
  # Sibling of the rejected-commit arm, and the same invariant: `git add -A`
  # failing leaves nothing staged, so `diff --cached --quiet` skips the whole
  # commit block — including its refusal. FILES still reads the working tree,
  # so a modified tracked file keeps the run looking productive.
  local repo; repo="$(mkrepo failedstage)"
  local wscript="${TMP}/w-addfail.sh"
  # Edit a TRACKED file (so the working-tree diff is non-empty), then wedge the
  # index so the loop's own `git add` cannot run.
  write_script "$wscript" 'cd "$WT" && echo edited > base.txt && touch "$(git rev-parse --git-dir)/index.lock"'
  mkroutes "$TMP/routes-addfail.json" "$wscript" true
  mkspec "$TMP/addfail.json" "$repo" nh/loop-addfail "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/addfail.json" --routes "$TMP/routes-addfail.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "6" "a failed stage stops the run instead of reporting work the branch does not hold"
  assert_not_contains "$out" "holds accepted work"
  assert_eq "$(git -C "$repo" log --oneline main..nh/loop-addfail 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "the branch is empty — which is why the run must not claim otherwise"
}

test_exhausted_retries_exit_3_not_lock_contention() {
  # #333: FINGERPRINTS_FILE aliases FINDINGS_TMP, so the requeue pass reads the
  # raw reviewer JSON still sitting in that file as if each line were a ticket
  # id. ceo_requeue_decide rejects them and exits 8, and FINAL_RC keeps the
  # highest code it saw — so a plain exhausted run reports lock contention.
  local repo; repo="$(mkrepo exitcontract)"
  local wscript="${TMP}/w-ec.sh"; write_script "$wscript" 'cd "$WT" && mkdir -p src/lib && echo q > src/lib/util.sh'
  local rscript="${TMP}/r-ec.sh"
  cat > "$rscript" <<'EOF'
#!/bin/bash
echo '{"invariant":"helper stays pure","location":"src/lib/util.sh:7","severity":"MEDIUM"}'
EOF
  chmod +x "$rscript"
  cat > "$TMP/routes-ec.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen-test", "command": "$wscript"}],
 "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "$rscript"}]}
JSON
  # verify_cmd fails and the only finding is MEDIUM, so nothing forces FINAL_RC=5.
  mkspec "$TMP/ec.json" "$repo" nh/loop-ec "false"
  git -C "$repo" branch integration
  local out rc=0
  out=$(CEO_LOOP_MAX_RETRIES=0 bash "$LOOP" run --spec "$TMP/ec.json" \
    --routes "$TMP/routes-ec.json" --target integration 2>&1) || rc=$?
  assert_eq "$rc" "3" "exhausted retries are exit 3, not 8 (lock contention)"
  assert_not_contains "$out" "unknown ticket"
}

test_the_requeue_pass_reads_ticket_ids_only() {
  # The direct statement of the same invariant: whatever the requeue loop
  # iterates holds ticket ids, never the raw finding JSON the reviewers emit.
  # Both a review finding and the synthesized verification finding must land
  # there, or one of the two stops reaching exhaustion.
  local repo; repo="$(mkrepo ticketbuffer)"
  local wscript="${TMP}/w-tb.sh"; write_script "$wscript" 'cd "$WT" && mkdir -p src/lib && echo q > src/lib/util.sh'
  local rscript="${TMP}/r-tb.sh"
  cat > "$rscript" <<'EOF'
#!/bin/bash
echo '{"invariant":"helper stays pure","location":"src/lib/util.sh:7","severity":"MEDIUM"}'
EOF
  chmod +x "$rscript"
  cat > "$TMP/routes-tb.json" <<JSON
{"candidates": [{"provider": "ollama", "model": "qwen-test", "command": "$wscript"}],
 "reviewers": [{"provider": "anthropic", "model": "claude-test", "command": "$rscript"}]}
JSON
  mkspec "$TMP/tb.json" "$repo" nh/loop-tb "false"
  git -C "$repo" branch integration
  local out
  out=$(CEO_LOOP_MAX_RETRIES=0 bash "$LOOP" run --spec "$TMP/tb.json" \
    --routes "$TMP/routes-tb.json" --target integration 2>&1) || true
  local exh
  exh=$(find "$CEO_LOOP_STATE_ROOT" -path "*ticketbuffer*" -name exhausted.jsonl -exec cat {} \;)
  assert_contains "$exh" "helper stays pure"
  assert_contains "$exh" "verification failed"
  assert_not_contains "$out" "unknown ticket"
}

test_rejects_a_target_name_with_leading_dash() {
  local repo; repo="$(mkrepo targetdash)"
  local wscript="${TMP}/w-tdash.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-tdash.json" "$wscript" true
  mkspec "$TMP/tdash.json" "$repo" nh/loop-tdash "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/tdash.json" --routes "$TMP/routes-tdash.json" --target -oProxyCommand=x 2>&1) || rc=$?
  assert_eq "$rc" "2" "a target branch name starting with - is rejected at argument validation"
  # Name the value: valid_ref_name is called for BRANCH, TARGET and DEFAULT_BRANCH
  # and emits one message shape, so a bare needle passes with TARGET unvalidated.
  assert_contains "$out" "'-oProxyCommand=x' is not a valid git branch name"
}

test_rejects_a_target_name_git_would_not_accept() {
  local repo; repo="$(mkrepo targetbadname)"
  local wscript="${TMP}/w-tbad.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-tbad.json" "$wscript" true
  mkspec "$TMP/tbad.json" "$repo" nh/loop-tbad "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/tbad.json" --routes "$TMP/routes-tbad.json" --target "main^" 2>&1) || rc=$?
  assert_eq "$rc" "2" "an invalid target branch name is rejected at argument validation"
  assert_contains "$out" "'main^' is not a valid git branch name"
}

test_loop_reclaim_leaves_an_unrelated_absent_worktree_registered() {
  # The loop must clear only the worktree blocking the branch in front of it.
  # `git worktree prune` is repo-wide and reads "directory missing" as "worktree
  # dead", which an unmounted volume or offline path looks like — it deletes that
  # worktree's admin dir, taking its index and HEAD with it, and `git worktree
  # repair` cannot undo that (#345).
  local repo; repo="$(mkrepo blastradius)"
  local human_wt="$TMP/vol/blast-human"
  mkdir -p "$TMP/vol"
  git -C "$repo" worktree add -q -b nh/human-work "$human_wt" main
  echo "human work" > "$human_wt/human.txt"
  /usr/bin/git -C "$human_wt" add -A && git -C "$human_wt" commit -qm "human work"

  # Initial loop run to create the branch, worktree, and ownership marker
  local wscript="${TMP}/w-blast.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-blast.json" "$wscript" true
  mkspec "$TMP/blast.json" "$repo" nh/loop-blast "false"
  CEO_LOOP_MAX_RETRIES=0 bash "$LOOP" run --spec "$TMP/blast.json" --routes "$TMP/routes-blast.json" --target main >/dev/null 2>&1 || true

  # Simulate the human worktree becoming unreachable (e.g. unmounted volume)
  mv "$TMP/vol" "$TMP/vol-unmounted"

  # Simulate loop worktree directory being removed (stale registration leftover)
  rm -rf "$repo/.ceo-loop"

  # Second loop run (reclaim path with successful verification)
  mkspec "$TMP/blast.json" "$repo" nh/loop-blast "true"
  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/blast.json" --routes "$TMP/routes-blast.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "0" "reclaim run must succeed"

  # Verify the unreachable worktree was NOT deregistered
  assert_eq "$(git -C "$repo" worktree list --porcelain | grep -c 'blast-human' || true)" "1" \
    "an unreachable worktree the loop was not asked about stays registered"

  # Remount and verify human worktree is functional
  mv "$TMP/vol-unmounted" "$TMP/vol"
  assert_eq "$(git -C "$human_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo BROKEN)" "nh/human-work" \
    "the remounted human worktree is still a working checkout"
  # Read the content through the repo, not through the worktree -- the two
  # assertions this replaces both re-measured the line above from inside the
  # broken checkout, so all three flipped together and none could flip alone.
  assert_eq "$(git -C "$repo" cat-file -e refs/heads/nh/human-work:human.txt 2>/dev/null && echo yes || echo no)" \
    "yes" "the human commit content survives"
}

test_loop_reclaim_clears_a_detached_leftover_registration() {
  # `worktree add --detach` runs before `checkout -b`, so a run killed between
  # them leaves a registration with no branch on it. Selecting leftovers by
  # branch alone cannot see that one, and the repo-wide prune that used to
  # absorb it is gone -- so each reclaim registers another admin dir, silently,
  # at exit 0.
  local repo; repo="$(mkrepo detachedleftover)"
  local wscript="${TMP}/w-detached.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-detached.json" "$wscript" true
  mkspec "$TMP/detached.json" "$repo" nh/loop-detached "true"

  CEO_LOOP_MAX_RETRIES=0 bash "$LOOP" run --spec "$TMP/detached.json" \
    --routes "$TMP/routes-detached.json" --target main >/dev/null 2>&1 || true

  # Reduce the loop's own worktree to the state a kill between `worktree add
  # --detach` and `checkout -b` leaves behind: registered, detached, directory
  # unreachable.
  local wt; wt="$(git -C "$repo" worktree list --porcelain \
    | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/nh\/loop-detached$/{print p}')"
  [ -n "$wt" ] || { echo "fixture: no loop worktree registered" >&2; return 1; }
  git -C "$repo" -C "$wt" checkout -q --detach HEAD 2>/dev/null \
    || git -C "$wt" checkout -q --detach HEAD
  git -C "$repo" branch -D nh/loop-detached >/dev/null 2>&1 || true
  rm -rf "$repo/.ceo-loop"
  assert_eq "$(git -C "$repo" worktree list --porcelain | grep -c '^detached$' || true)" "1" \
    "fixture leaves exactly one detached registration"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/detached.json" \
    --routes "$TMP/routes-detached.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "0" "the reclaim run must succeed"
  assert_eq "$(ls "$repo/.git/worktrees" 2>/dev/null | wc -l | tr -d ' ')" "1" \
    "the leftover registration is cleared, not left to accumulate beside the new one"
}

test_loop_reclaim_leaves_a_human_checkout_of_its_branch_alone() {
  # The loop owns the branch NAME, not every checkout of it. A person who checks
  # the parked branch out to read it leaves the tip unmoved, so the ownership
  # guard passes -- and an unscoped branch match would then hand their dirty
  # worktree to `remove --force --force`, which deletes it without complaint.
  local repo; repo="$(mkrepo humancheckout)"
  local wscript="${TMP}/w-human.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-human.json" "$wscript" true
  mkspec "$TMP/human.json" "$repo" nh/loop-human "true"

  CEO_LOOP_MAX_RETRIES=0 bash "$LOOP" run --spec "$TMP/human.json" \
    --routes "$TMP/routes-human.json" --target main >/dev/null 2>&1 || true

  # The loop's own worktree goes away; the branch stays parked at the tip the
  # loop recorded, which is what makes the ownership guard pass on the next run.
  rm -rf "$repo/.ceo-loop"
  git -C "$repo" worktree prune

  # A person checks that branch out somewhere of their own, with uncommitted work.
  local human_wt="$TMP/human-review-$$"
  git -C "$repo" worktree add -q "$human_wt" nh/loop-human
  echo "notes I have not committed" > "$human_wt/notes.txt"

  bash "$LOOP" run --spec "$TMP/human.json" --routes "$TMP/routes-human.json" \
    --target main >/dev/null 2>&1 || true

  assert_eq "$([ -f "$human_wt/notes.txt" ] && echo PRESENT || echo DESTROYED)" "PRESENT" \
    "uncommitted work in a human's checkout of the branch is not deleted"
  assert_eq "$(git -C "$human_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo BROKEN)" \
    "nh/loop-human" "and their worktree is still a working checkout"
}

test_delivery_failure_on_local_fast_forward_sets_exit_10_and_telemetry() {
  local repo; repo="$(mkrepo fffail)"
  local wscript="${TMP}/w-fffail.sh"
  # Worker writes feature file and concurrently advances main so fast-forward is impossible
  cat > "$wscript" <<'EOF'
#!/bin/bash
cd "$WT" && echo feature > feature.txt
git -C "$REPO_DIR" commit --allow-empty -qm "main advanced concurrently"
EOF
  chmod +x "$wscript"
  mkroutes "$TMP/routes-fffail.json" "$wscript" true
  mkspec "$TMP/fffail.json" "$repo" nh/loop-fffail "true"

  local out rc=0
  out=$(CEO_LOOP_ALLOW_MAIN=1 bash "$LOOP" run --spec "$TMP/fffail.json" \
    --routes "$TMP/routes-fffail.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "10" "failed fast-forward delivery must exit 10"
  assert_contains "$out" "could not fast-forward main"
  assert_contains "$out" "action=delivery-failed"
  # The pre-fix wording was `action=promote ` (the gate's recommendation printed
  # as the outcome). `action=promoted` does not contain it, so the trailing
  # space is what discriminates old from new.
  assert_not_contains "$out" "action=promote "

  # Telemetry check
  local tel slug_dir
  slug_dir=$(find "$CEO_LOOP_STATE_ROOT" -name telemetry.jsonl -path "*fffail*" | head -1)
  [ -f "$slug_dir" ] || { fail_test "telemetry.jsonl must exist"; return 1; }
  tel=$(cat "$slug_dir")
  assert_eq "$(jq -r '.promoted' <<<"$tel")" "false" "telemetry promoted must be false"
  assert_eq "$(jq -r '.accepted' <<<"$tel")" "true" "telemetry accepted must be true"
  assert_eq "$(jq -r '.action' <<<"$tel")" "promote" "telemetry gate action remains promote"
  assert_eq "$(jq -r '.delivery' <<<"$tel")" "delivery-failed" \
    "telemetry must record the delivery outcome, not just the gate recommendation"
}

test_delivery_failure_on_remote_push_sets_exit_10_and_telemetry() {
  local origin="$TMP/repos/origin-pushfail.git"
  git init -q --bare -b main "$origin"
  local repo; repo="$(mkrepo pushfail)"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  # Configure origin hook to reject pushes
  mkdir -p "$origin/hooks"
  printf '#!/bin/sh\nexit 1\n' > "$origin/hooks/pre-receive"
  chmod +x "$origin/hooks/pre-receive"
  git -C "$origin" config core.hooksPath "$origin/hooks"

  # Stub gh on PATH
  local stub_bin="$TMP/bin-pushfail"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr create") exit 0 ;;
  *) echo "stub-gh: unexpected argv: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/gh"

  local wscript="${TMP}/w-pushfail.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-pushfail.json" "$wscript" true
  mkspec "$TMP/pushfail.json" "$repo" nh/loop-pushfail "true"

  local out rc=0
  out=$(PATH="$stub_bin:$PATH" CEO_LOOP_ALLOW_MAIN=1 bash "$LOOP" run \
    --spec "$TMP/pushfail.json" --routes "$TMP/routes-pushfail.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "10" "failed remote push delivery must exit 10"
  assert_contains "$out" "push failed — branch nh/loop-pushfail kept locally"
  assert_not_contains "$out" "stub-gh: unexpected argv"
  assert_contains "$out" "action=delivery-failed"
  assert_not_contains "$out" "action=promoted"

  # Telemetry check
  local tel slug_dir
  slug_dir=$(find "$CEO_LOOP_STATE_ROOT" -name telemetry.jsonl -path "*pushfail*" | head -1)
  [ -f "$slug_dir" ] || { fail_test "telemetry.jsonl must exist"; return 1; }
  tel=$(cat "$slug_dir")
  assert_eq "$(jq -r '.promoted' <<<"$tel")" "false" "telemetry promoted must be false"
  assert_eq "$(jq -r '.accepted' <<<"$tel")" "true" "telemetry accepted must be true"
  assert_eq "$(jq -r '.delivery' <<<"$tel")" "delivery-failed" \
    "telemetry must record the delivery outcome, not just the gate recommendation"

  # Branch was NOT pushed to remote, but is kept locally
  assert_eq "$(git -C "$origin" rev-parse --verify -q refs/heads/nh/loop-pushfail >/dev/null 2>&1 && echo PRESENT || echo GONE)" "GONE"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-pushfail >/dev/null 2>&1 && echo PRESENT || echo GONE)" "PRESENT"
}

test_degraded_delivery_on_pr_create_failure_sets_exit_0_action_pushed() {
  local origin="$TMP/repos/origin-prfail.git"
  git init -q --bare -b main "$origin"
  local repo; repo="$(mkrepo prfail)"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  # Stub gh on PATH that fails on pr create
  local stub_bin="$TMP/bin-prfail"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr create") exit 1 ;;
  *) echo "stub-gh: unexpected argv: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/gh"

  local wscript="${TMP}/w-prfail.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-prfail.json" "$wscript" true
  mkspec "$TMP/prfail.json" "$repo" nh/loop-prfail "true"

  local out rc=0
  out=$(PATH="$stub_bin:$PATH" CEO_LOOP_ALLOW_MAIN=1 bash "$LOOP" run \
    --spec "$TMP/prfail.json" --routes "$TMP/routes-prfail.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "0" "degraded push success with pr create failure must exit 0"
  assert_contains "$out" "pushed nh/loop-prfail (gh pr create failed — open one manually)"
  assert_not_contains "$out" "stub-gh: unexpected argv"
  assert_contains "$out" "action=pushed"
  assert_not_contains "$out" "action=delivery-failed"
  assert_not_contains "$out" "action=promoted"

  # Telemetry check
  local tel slug_dir
  slug_dir=$(find "$CEO_LOOP_STATE_ROOT" -name telemetry.jsonl -path "*prfail*" | head -1)
  [ -f "$slug_dir" ] || { fail_test "telemetry.jsonl must exist"; return 1; }
  tel=$(cat "$slug_dir")
  assert_eq "$(jq -r '.promoted' <<<"$tel")" "true" "telemetry promoted must be true"
  assert_eq "$(jq -r '.accepted' <<<"$tel")" "true" "telemetry accepted must be true"
  assert_eq "$(jq -r '.delivery' <<<"$tel")" "pushed" \
    "telemetry must distinguish a pushed-but-PR-less branch from an opened PR"

  # Branch IS present on remote
  assert_eq "$(git -C "$origin" rev-parse --verify -q refs/heads/nh/loop-prfail >/dev/null 2>&1 && echo PRESENT || echo GONE)" "PRESENT"
}

test_marker_prune_drops_orphaned_ownership_ref() {
  # When a loop-created branch is deleted, its ownership marker in
  # refs/ceo-loop/owned/ is orphaned. Running the loop for that branch
  # must prune the marker so it stops pinning dead commits against gc.
  local repo; repo="$(mkrepo markerprune)"
  local wscript="${TMP}/w-mp.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-mp.json" "$wscript" true
  mkspec "$TMP/mp.json" "$repo" nh/loop-prune "true"
  bash "$LOOP" run --spec "$TMP/mp.json" --routes "$TMP/routes-mp.json" --target main >/dev/null 2>&1 || true
  local key; key="$(branch_key "nh/loop-prune")"
  local owned_ref="refs/ceo-loop/owned/$key"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$owned_ref" >/dev/null && echo yes || echo no)" "yes" \
    "ownership marker must exist after initial run"
  git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' \
    | while read -r w; do git -C "$repo" worktree remove --force --force "$w" 2>/dev/null || true; done
  git -C "$repo" branch -D nh/loop-prune >/dev/null 2>&1 || true
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-prune >/dev/null && echo yes || echo no)" "no" \
    "branch must be deleted"
  # Abort the run after the marker prune but before `worktree add --detach`
  # recreates the worktree and ceo_claim_branch re-writes the marker. A file
  # where the directory must go blocks it for any uid; `chmod 500` does not,
  # since mode bits are unenforced for root and CI may run as one.
  rm -rf "$repo/.ceo-loop"
  : > "$repo/.ceo-loop"
  bash "$LOOP" run --spec "$TMP/mp.json" --routes "$TMP/routes-mp.json" --target main >/dev/null 2>&1 || true
  rm -f "$repo/.ceo-loop"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$owned_ref" >/dev/null && echo yes || echo no)" "no" \
    "orphaned ownership marker must be deleted by marker prune"
}

test_mkrepo_rejects_duplicate_fixture_name() {
  local repo; repo="$(mkrepo dupname)"
  assert_file_exists "$repo/base.txt" "first mkrepo call must succeed"
  local out rc=0
  out=$(mkrepo dupname 2>&1) || rc=$?
  assert_eq "$rc" "1" "mkrepo must return 1 when called with a duplicate fixture name"
  assert_contains "$out" "duplicate fixture name 'dupname'"
}

test_reclaim_reports_worktree_remove_failure() {
  local repo; repo="$(mkrepo wtremfail)"
  local wscript="${TMP}/w-wtrem.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-wtrem.json" "$wscript" true
  mkspec "$TMP/wtrem.json" "$repo" nh/loop-wtrem "true"

  # Initial run to create worktree and branch
  bash "$LOOP" run --spec "$TMP/wtrem.json" --routes "$TMP/routes-wtrem.json" --target main >/dev/null 2>&1 || true

  local wt; wt="$(git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' | head -1)"
  [ -n "$wt" ] || { fail_test "loop worktree must be registered"; return 1; }

  # Corrupt the worktree's .git pointer so git worktree remove --force --force fails
  rm -f "$wt/.git"
  mkdir "$wt/.git"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/wtrem.json" --routes "$TMP/routes-wtrem.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "could not remove worktree at $wt" \
    "failure to remove worktree is surfaced by name"
  assert_contains "$out" "validation failed" \
    "git's own worktree remove stderr is preserved"
  assert_eq "$(git -C "$repo" worktree list --porcelain | grep -c "$wt" || true)" "1" \
    "worktree remains registered in git metadata when removal fails"
  assert_eq "$([ -d "$wt" ] && echo PRESENT || echo GONE)" "PRESENT" \
    "worktree directory is not deleted when worktree removal fails"
  assert_not_contains "$out" "could not delete branch" \
    "branch deletion is not attempted when worktree removal fails"
}

test_reclaim_reports_directory_remove_failure() {
  local repo; repo="$(mkrepo rmfail)"
  local wscript="${TMP}/w-rmfail.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-rmfail.json" "$wscript" true
  mkspec "$TMP/rmfail.json" "$repo" nh/loop-rmfail "true"

  # Create branch, ownership marker, and unregistered leftover directory
  git -C "$repo" branch nh/loop-rmfail
  local key; key="$(branch_key "nh/loop-rmfail")"
  git -C "$repo" update-ref "refs/ceo-loop/owned/$key" "$(git -C "$repo" rev-parse refs/heads/nh/loop-rmfail)"
  local wt="$repo/.ceo-loop/nh_loop-rmfail-${key:0:12}"
  mkdir -p "$wt"
  echo "leftover" > "$wt/leftover.txt"

  # Stub rm on PATH to fail when targeting .ceo-loop
  local stub_bin="$TMP/bin-rmfail"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/rm" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == *".ceo-loop"* ]]; then
    echo "rm: simulated deletion failure" >&2
    exit 1
  fi
done
exec /bin/rm "$@"
EOF
  chmod +x "$stub_bin/rm"

  local out rc=0
  out=$(PATH="$stub_bin:$PATH" bash "$LOOP" run --spec "$TMP/rmfail.json" --routes "$TMP/routes-rmfail.json" --target main 2>&1) || rc=$?
  assert_contains "$out" "could not remove directory at $wt" \
    "failure to remove worktree directory is surfaced by name"
  assert_contains "$out" "rm: simulated deletion failure" \
    "rm's own stderr is preserved"
  assert_eq "$([ -d "$wt" ] && echo PRESENT || echo GONE)" "PRESENT" \
    "worktree directory remains on disk when removal fails"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-rmfail >/dev/null 2>&1 && echo PRESENT || echo GONE)" \
    "PRESENT" "branch is not deleted when directory removal fails"
  assert_not_contains "$out" "could not delete branch" \
    "branch deletion is not attempted when directory removal fails"
}

test_reclaim_reports_branch_delete_failure() {
  local repo; repo="$(mkrepo bdfail)"
  local wscript="${TMP}/w-bdfail.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-bdfail.json" "$wscript" true
  mkspec "$TMP/bdfail.json" "$repo" nh/loop-bdfail "true"

  # Initial run to create worktree and branch
  bash "$LOOP" run --spec "$TMP/bdfail.json" --routes "$TMP/routes-bdfail.json" --target main >/dev/null 2>&1 || true

  # Lock the branch ref so git branch -D fails
  touch "$repo/.git/refs/heads/nh/loop-bdfail.lock"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/bdfail.json" --routes "$TMP/routes-bdfail.json" --target main 2>&1) || rc=$?
  rm -f "$repo/.git/refs/heads/nh/loop-bdfail.lock"
  assert_contains "$out" "could not delete branch nh/loop-bdfail" \
    "failure to delete loop-owned branch is surfaced by name"
  assert_contains "$out" "cannot lock ref" \
    "git's own branch -D stderr is preserved"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-bdfail >/dev/null 2>&1 && echo PRESENT || echo GONE)" \
    "PRESENT" "branch remains present in refs when deletion fails"
}

test_fresh_run_does_not_emit_branch_deletion_warning() {
  local repo; repo="$(mkrepo freshrun)"
  local wscript="${TMP}/w-fresh.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-fresh.json" "$wscript" true
  mkspec "$TMP/fresh.json" "$repo" nh/loop-fresh "true"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/fresh.json" --routes "$TMP/routes-fresh.json" --target main 2>&1) || rc=$?
  assert_not_contains "$out" "could not delete branch" \
    "clean run on non-existent branch does not report branch deletion failure"
}

test_reclaim_removes_dangling_symlink_directory() {
  local repo; repo="$(mkrepo danglingsym)"
  local wscript="${TMP}/w-dang.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-dang.json" "$wscript" true
  mkspec "$TMP/dang.json" "$repo" nh/loop-dang "true"

  local key; key="$(branch_key "nh/loop-dang")"
  local wt="$repo/.ceo-loop/nh_loop-dang-${key:0:12}"
  mkdir -p "$repo/.ceo-loop"
  ln -s "$TMP/nonexistent-target" "$wt"
  assert_eq "$([ -L "$wt" ] && echo PRESENT || echo GONE)" "PRESENT" \
    "dangling symlink exists before reclaim"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/dang.json" --routes "$TMP/routes-dang.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "0" "reclaim succeeds when cleaning up dangling symlink"
  assert_eq "$([ -L "$wt" ] && echo PRESENT || echo GONE)" "GONE" \
    "dangling symlink directory is removed by ceo_remove_dir"
}

test_reclaim_deletes_broken_symref_branch() {
  local repo; repo="$(mkrepo brokensym)"
  local wscript="${TMP}/w-brok.sh"; write_script "$wscript" "$WORKER_WRITE"
  mkroutes "$TMP/routes-brok.json" "$wscript" true
  mkspec "$TMP/brok.json" "$repo" nh/loop-brok "true"

  git -C "$repo" symbolic-ref refs/heads/nh/loop-brok refs/heads/nonexistent
  assert_eq "$(git -C "$repo" symbolic-ref -q refs/heads/nh/loop-brok >/dev/null && echo PRESENT || echo GONE)" "PRESENT" \
    "broken symref exists before reclaim"

  local out rc=0
  out=$(bash "$LOOP" run --spec "$TMP/brok.json" --routes "$TMP/routes-brok.json" --target main 2>&1) || rc=$?
  assert_eq "$rc" "0" "reclaim succeeds and deletes broken symref"
  assert_eq "$(git -C "$repo" symbolic-ref -q refs/heads/nh/loop-brok >/dev/null && echo PRESENT || echo GONE)" "GONE" \
    "broken symref is deleted by ceo_delete_branch"
}

test_in_flight_worker_on_same_branch_refuses_before_reclaim() {
  # Issue #336: Reclaim must not destroy an in-flight worker on the same branch.
  local repo; repo="$(mkrepo inflight)"
  local wscript="${TMP}/w-inflight.sh"
  write_script "$wscript" 'cd "$WT" && echo step1 > f.txt && sleep 2 && echo step2 >> f.txt'
  mkroutes "$TMP/routes-inflight.json" "$wscript" true
  mkspec "$TMP/inflight.json" "$repo" nh/loop-inflight "true"

  # Launch Run 1 in the background
  local out1_log="$TMP/run1.log"
  bash "$LOOP" run --spec "$TMP/inflight.json" --routes "$TMP/routes-inflight.json" --target main > "$out1_log" 2>&1 &
  local pid1=$!

  # Wait for Run 1 to register and create its worktree
  local wt1=""
  for _ in $(seq 1 50); do
    wt1="$(git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' | head -1)"
    if [ -n "$wt1" ] && [ -d "$wt1" ]; then break; fi
    sleep 0.1
  done
  [ -n "$wt1" ] || { fail_test "run 1 worktree must be registered"; wait "$pid1" || true; return 1; }

  # Run 2 targeting the same branch while Run 1 is in-flight
  local out2 rc2=0
  out2=$(bash "$LOOP" run --spec "$TMP/inflight.json" --routes "$TMP/routes-inflight.json" --target main 2>&1) || rc2=$?
  assert_eq "$rc2" "6" "concurrent run on same branch exits 6"
  assert_contains "$out2" "already has an in-flight worker" \
    "in-flight worker conflict is surfaced by name"

  # Assert Run 1's worktree was NOT destroyed by Run 2
  assert_eq "$([ -d "$wt1" ] && echo PRESENT || echo GONE)" "PRESENT" \
    "in-flight worktree is not deleted by concurrent run"
  assert_eq "$(git -C "$repo" worktree list --porcelain | grep -c "$wt1" || true)" "1" \
    "in-flight worktree remains registered in git metadata"

  # Wait for Run 1 to complete cleanly
  local rc1=0
  wait "$pid1" || rc1=$?
  assert_eq "$rc1" "0" "in-flight run completes successfully without interruption"
}

test_uncommitted_run_does_not_authorize_deleting_human_branch_at_main() {
  # Issue #336: A run that dies before committing leaves no marker pointing at
  # the target tip, so a human branch at main is never matched and deleted.
  local repo; repo="$(mkrepo humanguard)"
  local wscript="${TMP}/w-fail.sh"
  write_script "$wscript" 'exit 1'
  mkroutes "$TMP/routes-fail.json" "$wscript" "$wscript"
  mkspec "$TMP/fail.json" "$repo" nh/loop-humanguard "true"

  local out1 rc1=0
  out1=$(bash "$LOOP" run --spec "$TMP/fail.json" --routes "$TMP/routes-fail.json" --target main 2>&1) || rc1=$?
  assert_eq "$rc1" "4" "worker failure exits 4 before committing"
  assert_contains "$out1" "every routed candidate failed"

  # Cleanup worktree and branch from the failed run
  git -C "$repo" worktree list --porcelain | awk '/^worktree .*\.ceo-loop/{print $2}' \
    | while read -r w; do git -C "$repo" worktree remove --force --force "$w" 2>/dev/null || true; done
  git -C "$repo" branch -D nh/loop-humanguard >/dev/null 2>&1 || true

  # A human now creates a branch from main with the same name
  git -C "$repo" branch nh/loop-humanguard main
  local human_sha; human_sha="$(git -C "$repo" rev-parse refs/heads/nh/loop-humanguard)"

  local out2 rc2=0
  out2=$(bash "$LOOP" run --spec "$TMP/fail.json" --routes "$TMP/routes-fail.json" --target main 2>&1) || rc2=$?
  assert_eq "$rc2" "6" "loop refuses to delete human branch at base tip"
  assert_contains "$out2" "already exists and was not created by ceo-loop"
  assert_eq "$(git -C "$repo" rev-parse refs/heads/nh/loop-humanguard 2>/dev/null)" "$human_sha" \
    "human branch remains untouched at its commit"
}

test_early_registration_without_declared_files_prevents_same_branch_collision() {
  # Issue #336: Specs without declared files must still register under state lock
  # to prevent same-branch concurrency races.
  local repo; repo="$(mkrepo nofiles)"
  local wscript="${TMP}/w-nofiles.sh"
  write_script "$wscript" 'cd "$WT" && echo work > w.txt && sleep 2'
  mkroutes "$TMP/routes-nofiles.json" "$wscript" true
  # Spec explicitly omits .files
  mkspec "$TMP/nofiles.json" "$repo" nh/loop-nofiles "true"

  bash "$LOOP" run --spec "$TMP/nofiles.json" --routes "$TMP/routes-nofiles.json" --target main > "$TMP/nofiles1.log" 2>&1 &
  local pid1=$!

  local repo_slug; repo_slug="$(jq -r .repo "$TMP/nofiles.json" | tr '/' '-')"
  local sdir; sdir="$(ceo_loop_state_dir "$repo_slug")"
  for _ in $(seq 1 50); do
    if [ -s "$sdir/workers.jsonl" ]; then break; fi
    sleep 0.1
  done

  local out2 rc2=0
  out2=$(bash "$LOOP" run --spec "$TMP/nofiles.json" --routes "$TMP/routes-nofiles.json" --target main 2>&1) || rc2=$?
  assert_eq "$rc2" "6" "concurrent run without declared files exits 6 on same branch"
  assert_contains "$out2" "already has an in-flight worker"

  wait "$pid1" || true
}

test_a_failed_runs_leftover_branch_is_reclaimed_by_the_next_run() {
  # An ordinary worker failure — no kill needed — leaves a branch and worktree
  # with no ownership marker, because the marker is only written once output is
  # committed. If nothing distinguishes that leftover from a human's branch at
  # the same tip, every failed run wedges its branch until a person intervenes.
  local repo; repo="$(mkrepo selfheal)"
  local failing="${TMP}/w-selfheal-fail.sh"
  write_script "$failing" 'exit 1'
  mkroutes "$TMP/routes-selfheal-fail.json" "$failing" "$failing"
  mkspec "$TMP/selfheal.json" "$repo" nh/loop-selfheal "true"

  local rc1=0
  bash "$LOOP" run --spec "$TMP/selfheal.json" --routes "$TMP/routes-selfheal-fail.json" --target main >/dev/null 2>&1 || rc1=$?
  assert_eq "$rc1" "4" "the worker fails before anything is committed"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/loop-selfheal >/dev/null 2>&1 && echo PRESENT || echo GONE)" \
    "PRESENT" "the failed run leaves its branch behind"
  assert_eq "$(git -C "$repo" for-each-ref --format='%(refname)' 'refs/ceo-loop/owned/**' | wc -l | tr -d ' ')" "0" \
    "and leaves no ownership marker, because nothing was committed"

  # The next run must reclaim its own leftover rather than refuse forever.
  local working="${TMP}/w-selfheal-ok.sh"
  write_script "$working" 'cd "$WT" && echo ok > f.txt'
  mkroutes "$TMP/routes-selfheal-ok.json" "$working" true
  local out2 rc2=0
  out2=$(bash "$LOOP" run --spec "$TMP/selfheal.json" --routes "$TMP/routes-selfheal-ok.json" --target main 2>&1) || rc2=$?
  assert_eq "$rc2" "0" "the next run reclaims the leftover instead of wedging"
  assert_not_contains "$out2" "was not created by ceo-loop" \
    "the loop does not mistake its own leftover for a human's branch"
}

test_a_refused_run_leaves_the_incumbent_registration_intact() {
  # The refused run still runs its EXIT cleanup. If that release matched on the
  # branch name alone it would delete the incumbent's row, so the guard would
  # fire once and then wave the next run straight through.
  local repo; repo="$(mkrepo refused)"
  local wscript="${TMP}/w-refused.sh"
  write_script "$wscript" 'cd "$WT" && echo a > f.txt && sleep 6'
  mkroutes "$TMP/routes-refused.json" "$wscript" true
  mkspec "$TMP/refused.json" "$repo" nh/loop-refused "true"

  bash "$LOOP" run --spec "$TMP/refused.json" --routes "$TMP/routes-refused.json" --target main > "$TMP/refused1.log" 2>&1 &
  local pid1=$!
  local slug; slug="$(jq -r .repo "$TMP/refused.json" | tr '/' '-')"
  local sdir; sdir="$(ceo_loop_state_dir "$slug")"
  for _ in $(seq 1 60); do [ -s "$sdir/workers.jsonl" ] && break; sleep 0.1; done
  assert_eq "$(jq -r .branch "$sdir/workers.jsonl" | head -1)" "nh/loop-refused" "the incumbent is registered"

  local rc2=0
  bash "$LOOP" run --spec "$TMP/refused.json" --routes "$TMP/routes-refused.json" --target main >/dev/null 2>&1 || rc2=$?
  assert_eq "$rc2" "6" "the second run is refused"
  assert_eq "$(jq -r .branch "$sdir/workers.jsonl" | head -1)" "nh/loop-refused" \
    "the incumbent's registration row survives the refused run's cleanup"
  wait "$pid1" || true
}

test_a_run_that_exits_before_registering_leaves_the_incumbent_row() {
  # Every exit between the cleanup trap being installed and registration — a
  # stale base, an unresolvable target, no candidate configured — used to reach
  # the same unconditional release, so a run that never registered could still
  # free somebody else's slot.
  local repo; repo="$(mkrepo neverreg)"
  local wscript="${TMP}/w-neverreg.sh"
  write_script "$wscript" 'cd "$WT" && echo a > f.txt && sleep 6'
  mkroutes "$TMP/routes-neverreg.json" "$wscript" true
  mkspec "$TMP/neverreg.json" "$repo" nh/loop-neverreg "true"

  bash "$LOOP" run --spec "$TMP/neverreg.json" --routes "$TMP/routes-neverreg.json" --target main > "$TMP/neverreg1.log" 2>&1 &
  local pid1=$!
  local slug; slug="$(jq -r .repo "$TMP/neverreg.json" | tr '/' '-')"
  local sdir; sdir="$(ceo_loop_state_dir "$slug")"
  for _ in $(seq 1 60); do [ -s "$sdir/workers.jsonl" ] && break; sleep 0.1; done

  echo '{"candidates":[]}' > "$TMP/routes-empty.json"
  local rc2=0
  bash "$LOOP" run --spec "$TMP/neverreg.json" --routes "$TMP/routes-empty.json" --target main >/dev/null 2>&1 || rc2=$?
  assert_eq "$rc2" "4" "the second run dies before it ever registers"
  assert_eq "$(jq -r .branch "$sdir/workers.jsonl" | head -1)" "nh/loop-neverreg" \
    "a run that never registered does not free the incumbent's slot"
  wait "$pid1" || true
}

run_tests
