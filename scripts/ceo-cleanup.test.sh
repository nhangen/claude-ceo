#!/usr/bin/env bash
# ceo-cleanup.test.sh — tests for ceo-cleanup.sh merged branch reaping and default branch resolution.
set -euo pipefail
cd "$(dirname "$0")"
source ./test-harness.sh
# shellcheck source=ceo-loop-lib.sh
source ./ceo-loop-lib.sh

SCRIPT_DIR="$(pwd)"
CLEANUP="$SCRIPT_DIR/ceo-cleanup.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CEO_VAULT="$TMP/vault"
export CEO_VAULT
mkdir -p "$CEO_VAULT/CEO/log"

mkrepo_cleanup() {
  local name="$1" default_branch="$2"
  local dir="$TMP/repos/$name"
  # A second call on the same name re-inits, and `git commit` then writes
  # "nothing to commit" to STDOUT, which is captured into the returned path.
  # Every later `git -C "$repo"` dies on it and the arm still reports pass.
  #
  # Convention (#351): a fixture-builder guard is tested beside its builder, in
  # the suite that defines it — not in test-harness.test.sh. The three builders
  # are three different functions in two suites, so moving the arms without
  # moving the builders would separate each guard from the thing it guards.
  [ ! -e "$dir" ] || { echo "mkrepo_cleanup: duplicate fixture name '$name'" >&2; return 1; }
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$default_branch"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo "init" > "$dir/base.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm "init"
  echo "$dir"
}

set_repos_md() { # <repo-path>...
  local md="$CEO_VAULT/CEO/repos.md"
  {
    echo "| Repo | Local Path | Description |"
    echo "|---|---|---|"
    for p in "$@"; do
      echo "| $(basename "$p") | $p | test repo |"
    done
  } > "$md"
}

test_cleanup_resolves_and_reaps_merged_branch_on_main_default() {
  local repo; repo="$(mkrepo_cleanup repo-main-1 main)"
  set_repos_md "$repo"

  # Create a ceo branch with a commit
  git -C "$repo" checkout -q -b ceo/test-feature
  echo "feature" > "$repo/feat.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "add feature"

  # Merge into main
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/test-feature -m "merge feature"

  # Run cleanup
  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH: main" "must report main as default branch"
  assert_contains "$out" "MERGED: ceo/test-feature" "must identify branch as merged"
  assert_contains "$out" "BRANCH_DELETED: ceo/test-feature" "must report branch deletion"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/test-feature 2>/dev/null || echo GONE)" "GONE" \
    "merged branch must actually be deleted from git refs"
  # The counters need pinning at their quiet values too: an arm that only ever
  # asserts a non-zero count cannot catch a counter that never increments, or
  # one that increments always.
  assert_contains "$out" "MERGED_TOTAL: 1" "a reaped branch is counted"
  assert_contains "$out" "REAP_FAILED: 0" "nothing failed, so nothing is reported failed"
  assert_contains "$out" "STALE_STATE: 0" "no stale-state warning on a clean run"
  assert_contains "$out" "AI_NEEDED: no" "a clean run needs no human"
  assert_not_contains "$out" "FETCH_FAILED" "a healthy run raises no fetch alarm"
}

test_cleanup_resolves_and_reaps_merged_branch_on_master_default() {
  local repo; repo="$(mkrepo_cleanup repo-master-1 master)"
  set_repos_md "$repo"

  # Create a ceo branch with a commit
  git -C "$repo" checkout -q -b ceo/master-feature
  echo "feature" > "$repo/feat.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "add feature"

  # Merge into master
  git -C "$repo" checkout -q master
  git -C "$repo" merge -q --no-ff ceo/master-feature -m "merge feature"

  # Run cleanup
  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH: master" "must report master as default branch"
  assert_contains "$out" "MERGED: ceo/master-feature" "must identify branch as merged"
  assert_contains "$out" "BRANCH_DELETED: ceo/master-feature" "must report branch deletion"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/master-feature 2>/dev/null || echo GONE)" "GONE" \
    "merged branch must actually be deleted from git refs"
}

test_cleanup_resolves_origin_head_symref() {
  local origin="$TMP/repos/origin-trunk.git"
  git init -q --bare -b trunk "$origin"
  local seed="$TMP/repos/seed-trunk"
  git clone -q "$origin" "$seed"
  git -C "$seed" config user.email t@t
  git -C "$seed" config user.name t
  echo "init" > "$seed/base.txt"
  git -C "$seed" add -A && git -C "$seed" commit -qm "init"
  git -C "$seed" push -q origin trunk
  git -C "$origin" symbolic-ref HEAD refs/heads/trunk
  rm -rf "$seed"

  local clone="$TMP/repos/clone-trunk"
  git clone -q "$origin" "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  set_repos_md "$clone"

  # Create a ceo branch in clone
  git -C "$clone" checkout -q -b ceo/trunk-feature
  echo "feature" > "$clone/feat.txt"
  git -C "$clone" add -A && git -C "$clone" commit -qm "add trunk feature"

  # Merge into trunk and push to origin
  git -C "$clone" checkout -q trunk
  git -C "$clone" merge -q --no-ff ceo/trunk-feature -m "merge trunk feature"
  git -C "$clone" push -q origin trunk

  # Run cleanup
  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH: trunk" "must resolve trunk from origin/HEAD symref"
  assert_contains "$out" "MERGED: ceo/trunk-feature" "must identify branch as merged"
  assert_eq "$(git -C "$clone" rev-parse --verify -q refs/heads/ceo/trunk-feature 2>/dev/null || echo GONE)" "GONE" \
    "merged branch must actually be deleted from git refs"
}

test_cleanup_removes_worktree_for_merged_branch() {
  local repo; repo="$(mkrepo_cleanup repo-wt-1 main)"
  set_repos_md "$repo"

  # Create a ceo branch and worktree
  local wt="$TMP/wt/ceo-test-wt"
  git -C "$repo" worktree add -q -b ceo/test-wt "$wt" main
  echo "wt" > "$wt/wt.txt"
  git -C "$wt" add -A && git -C "$wt" commit -qm "add wt feature"

  # Merge branch into main
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/test-wt -m "merge wt feature"

  # Verify worktree exists before cleanup
  assert_eq "$(git -C "$repo" worktree list | grep -c "ceo/test-wt" || true)" "1"

  # Run cleanup
  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "WORKTREE_REMOVED"
  assert_eq "$(git -C "$repo" worktree list | grep -c "ceo/test-wt" || true)" "0" \
    "worktree must be deregistered"
  assert_eq "$([ -d "$wt" ] && echo exists || echo gone)" "gone" "worktree directory must be removed"
}

test_cleanup_deletes_owned_ref_for_merged_branch() {
  local repo; repo="$(mkrepo_cleanup repo-owned-1 main)"
  set_repos_md "$repo"

  # Create a ceo branch with a commit
  git -C "$repo" checkout -q -b ceo/owned-feature
  echo "owned" > "$repo/owned.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "add owned feature"

  # Create the loop ownership marker as ceo-loop would
  local key; key="$(branch_key "ceo/owned-feature")"
  local owned_ref="refs/ceo-loop/owned/$key"
  git -C "$repo" update-ref "$owned_ref" "$(git -C "$repo" rev-parse ceo/owned-feature)"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$owned_ref" 2>/dev/null || echo GONE)" \
    "$(git -C "$repo" rev-parse ceo/owned-feature)" "ownership marker must exist before cleanup"

  # Merge branch into main
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/owned-feature -m "merge owned feature"

  # Run cleanup
  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "MERGED: ceo/owned-feature"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$owned_ref" 2>/dev/null || echo GONE)" "GONE" \
    "ownership marker must be deleted when branch is reaped"
  assert_eq "$(git -C "$repo" for-each-ref refs/ceo-loop/owned | wc -l | tr -d ' ')" "0" \
    "for-each-ref refs/ceo-loop/owned must be empty"
}

# A repo cloned from a bare origin, with `main` already carrying a merged ceo
# branch on the remote. `local_lag` rewinds the clone's local main so the merge
# is visible ONLY through origin/main — the state every one of the four original
# arms lacked, and the reason reverting the remote half of the fix left them green.
mkclone_cleanup() { # <name> <default-branch> <ceo-branch> <local_lag|no_lag>
  local name="$1" default_branch="$2" ceo_branch="$3" mode="$4"
  local origin="$TMP/repos/$name.git" clone="$TMP/repos/$name"
  # Guarded and tested beside the builder, per the convention noted at
  # mkrepo_cleanup above (#351).
  [ ! -e "$clone" ] || { echo "mkclone_cleanup: duplicate fixture name '$name'" >&2; return 1; }
  git init -q --bare -b "$default_branch" "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  echo init > "$clone/base.txt"
  /usr/bin/git -C "$clone" add -A && git -C "$clone" commit -qm init
  git -C "$clone" push -q origin "$default_branch"
  git -C "$origin" symbolic-ref HEAD "refs/heads/$default_branch"
  git -C "$clone" checkout -q -b "$ceo_branch"
  echo feature > "$clone/feat.txt"
  /usr/bin/git -C "$clone" add -A && git -C "$clone" commit -qm feature
  git -C "$clone" checkout -q "$default_branch"
  git -C "$clone" merge -q --no-ff "$ceo_branch" -m merge
  git -C "$clone" push -q origin "$default_branch"
  if [ "$mode" = "local_lag" ]; then
    git -C "$clone" reset -q --hard HEAD~1
  fi
  echo "$clone"
}

mkmarker() { # <repo> <branch> -> echoes the ref name
  local ref
  ref="refs/ceo-loop/owned/$(branch_key "$2")"
  git -C "$1" update-ref "$ref" "$(git -C "$1" rev-parse "$2")"
  echo "$ref"
}

test_cleanup_reaps_a_merge_visible_only_through_the_remote() {
  local repo; repo="$(mkclone_cleanup remote-only main ceo/remote-only local_lag)"
  # Detach onto the remote's tip so `branch -d` agrees the branch is merged
  # while local main still lags — isolating the remote ancestry arm.
  git -C "$repo" checkout -q --detach origin/main
  local ref; ref="$(mkmarker "$repo" ceo/remote-only)"
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "MERGED: ceo/remote-only" \
    "a merge reachable only through origin/main must be seen as merged"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/remote-only 2>/dev/null || echo GONE)" "GONE" \
    "the branch must actually be deleted"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" 2>/dev/null || echo GONE)" "GONE" \
    "the ownership marker must be deleted alongside it"
  assert_contains "$out" "MARKER_DELETED" "the marker deletion must be reported"
}

test_cleanup_keeps_the_marker_when_the_branch_delete_fails() {
  # Local main lags origin/main, so the ancestry probe says merged and
  # `git branch -d` refuses. Deleting the marker here would leave the branch
  # standing with no ownership record and lock ceo-loop out of it forever.
  local repo; repo="$(mkclone_cleanup lagging main ceo/lagging local_lag)"
  local ref; ref="$(mkmarker "$repo" ceo/lagging)"
  local before; before="$(git -C "$repo" rev-parse "$ref")"
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "BRANCH_DELETE_FAILED: ceo/lagging"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/lagging 2>/dev/null || echo GONE)" \
    "$(git -C "$repo" rev-parse ceo/lagging)" "the branch must survive a failed delete"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" 2>/dev/null || echo GONE)" "$before" \
    "the ownership marker must survive when its branch did"
  assert_not_contains "$out" "MARKER_DELETED"
}

test_cleanup_keeps_the_marker_for_an_unmerged_branch() {
  local repo; repo="$(mkrepo_cleanup unmerged-1 main)"
  git -C "$repo" checkout -q -b ceo/never-merged
  echo x > "$repo/x.txt"
  /usr/bin/git -C "$repo" add -A && git -C "$repo" commit -qm x
  local ref; ref="$(mkmarker "$repo" ceo/never-merged)"
  local before; before="$(git -C "$repo" rev-parse "$ref")"
  git -C "$repo" checkout -q main
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_not_contains "$out" "MERGED: ceo/never-merged"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" 2>/dev/null || echo GONE)" "$before" \
    "an unmerged branch keeps its ownership marker"
}

test_cleanup_falls_through_a_stale_origin_head_symref() {
  # The remote renamed its default branch; the clone's origin/HEAD still names
  # the old one, which no longer resolves. Trusting it unchecked reproduces the
  # very bug this reaper exists to fix.
  local repo; repo="$(mkclone_cleanup renamed main ceo/renamed no_lag)"
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  local ref; ref="$(mkmarker "$repo" ceo/renamed)"
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH: main" \
    "a stale origin/HEAD must fall through to the main/master chain"
  assert_contains "$out" "MERGED: ceo/renamed"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/renamed 2>/dev/null || echo GONE)" "GONE" \
    "the branch must be reaped despite the stale symref"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" 2>/dev/null || echo GONE)" "GONE" \
    "the marker must be reaped with it"
}

test_cleanup_reports_an_unresolvable_default_branch() {
  # No origin/HEAD, no main, no master. Inventing "main" here would hand both
  # ancestry probes a dead ref and report the repo as all-active.
  local repo; repo="$(mkrepo_cleanup trunk-only trunk)"
  git -C "$repo" checkout -q -b ceo/orphaned
  echo x > "$repo/x.txt"
  /usr/bin/git -C "$repo" add -A && git -C "$repo" commit -qm x
  git -C "$repo" checkout -q trunk
  git -C "$repo" merge -q --no-ff ceo/orphaned -m merge
  local ref; ref="$(mkmarker "$repo" ceo/orphaned)"
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH_UNRESOLVED" \
    "an unresolvable default branch must be reported, not invented"
  assert_not_contains "$out" "DEFAULT_BRANCH: main"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" 2>/dev/null || echo GONE)" \
    "$(git -C "$repo" rev-parse ceo/orphaned)" "nothing is reaped when the default branch is unknown"
}

test_cleanup_counts_deletions_not_detections_and_reports_reap_failure() {
  # Local main lags origin/main: ancestry probe says merged, but git branch -d
  # fails. MERGED_TOTAL must report 0 (actual reaps), REAP_FAILED must report 1,
  # and AI_NEEDED must flip to yes naming the failure.
  local repo; repo="$(mkclone_cleanup countfail main ceo/countfail local_lag)"
  local ref; ref="$(mkmarker "$repo" ceo/countfail)"
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "MERGED: ceo/countfail" "branch is detected as merged"
  assert_contains "$out" "BRANCH_DELETE_FAILED: ceo/countfail" "branch delete fails"
  assert_contains "$out" "MERGED_TOTAL: 0" "MERGED_TOTAL counts actual reaps, not detections"
  assert_contains "$out" "REAP_FAILED: 1" "REAP_FAILED reports un-reaped branches"
  assert_contains "$out" "AI_NEEDED: yes" "AI_NEEDED must flip to yes on reap failure"
  assert_contains "$out" "1 merged branch(es) failed to reap" "AI_NEEDED reason names reap failures"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/countfail 2>/dev/null || echo GONE)" \
    "$(git -C "$repo" rev-parse ceo/countfail)" "the un-reaped branch still exists"
}

test_cleanup_reports_fetch_failure_when_origin_fetch_fails() {
  local repo; repo="$(mkclone_cleanup fetchfail main ceo/fetchfail no_lag)"
  git -C "$repo" remote set-url origin /dev/null/does/not/exist
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed despite fetch failure"
  assert_contains "$out" "FETCH_FAILED: origin/main — merge state may be stale"
}

test_cleanup_prunes_stale_worktree_and_reaps_branch() {
  local repo; repo="$(mkrepo_cleanup stalewt-1 main)"
  set_repos_md "$repo"

  local wt="$TMP/wt/ceo-stale-wt"
  git -C "$repo" worktree add -q -b ceo/stale-wt "$wt" main
  echo "wt" > "$wt/wt.txt"
  git -C "$wt" add -A && git -C "$wt" commit -qm "add wt feature"

  # Merge branch into main
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/stale-wt -m "merge wt feature"

  # Remove directory manually so worktree becomes stale / missing on disk
  rm -rf "$wt"
  assert_eq "$(git -C "$repo" worktree list | grep -c "ceo/stale-wt" || true)" "1" \
    "worktree is still registered in git metadata"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "WORKTREE_STALE_REMOVED:" "must report the stale worktree it removed"
  assert_contains "$out" "BRANCH_DELETED: ceo/stale-wt" "branch must be deleted"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/stale-wt 2>/dev/null || echo GONE)" "GONE" \
    "branch must be reaped after pruning stale worktree"
  assert_eq "$(git -C "$repo" worktree list | grep -c "ceo/stale-wt" || true)" "0" \
    "worktree must be pruned from git metadata"
}

test_cleanup_suppresses_git_branch_d_stdout() {
  local repo; repo="$(mkrepo_cleanup suppress-1 main)"
  set_repos_md "$repo"

  git -C "$repo" checkout -q -b ceo/suppress-branch
  echo "sup" > "$repo/sup.txt"
  git -C "$repo" add -A && git -C "$repo" commit -qm "add sup"

  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/suppress-branch -m "merge sup"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "BRANCH_DELETED: ceo/suppress-branch"
  assert_not_contains "$out" "Deleted branch ceo/suppress-branch" \
    "raw git branch -d stdout must not leak into report"
}

test_cleanup_leaves_an_unrelated_absent_worktree_registered() {
  # The reaper must clear only the worktree blocking the branch in front of it.
  # `git worktree prune` is repo-wide and reads "directory missing" as "worktree
  # dead", which an unmounted volume also looks like -- it deletes that
  # worktree's admin dir, taking its index and HEAD with it, and `git worktree
  # repair` cannot undo that.
  local repo; repo="$(mkrepo_cleanup blastradius main)"
  set_repos_md "$repo"

  local ceo_wt="$TMP/wt/blast-ceo" human_wt="$TMP/vol/blast-human"
  git -C "$repo" worktree add -q -b ceo/blast "$ceo_wt" main
  echo wt > "$ceo_wt/wt.txt"
  /usr/bin/git -C "$ceo_wt" add -A && git -C "$ceo_wt" commit -qm "ceo work"
  git -C "$repo" worktree add -q -b nh/human-work "$human_wt" main

  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/blast -m merge

  rm -rf "$ceo_wt"                 # genuinely dead
  mv "$TMP/vol" "$TMP/vol-unmounted"   # merely unreachable right now

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "WORKTREE_STALE_REMOVED:"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/ceo/blast 2>/dev/null || echo GONE)" "GONE" \
    "the dead worktree is cleared so the merged branch can be reaped"
  assert_eq "$(git -C "$repo" worktree list --porcelain | grep -c 'blast-human' || true)" "1" \
    "an unreachable worktree the reaper was not asked about stays registered"
  assert_eq "$(git -C "$repo" rev-parse --verify -q refs/heads/nh/human-work >/dev/null 2>&1 && echo PRESENT || echo GONE)" \
    "PRESENT" "and its branch is untouched"

  mv "$TMP/vol-unmounted" "$TMP/vol"
  assert_eq "$(git -C "$human_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo BROKEN)" "nh/human-work" \
    "the remounted worktree is still a working checkout"
}

test_cleanup_reports_no_remote_rather_than_a_fetch_alarm() {
  # mkrepo_cleanup builds a repo with no origin. Blaming a fetch there fires the
  # warning on every remote-less repo and it stops meaning anything.
  local repo; repo="$(mkrepo_cleanup noremote main)"
  git -C "$repo" checkout -q -b ceo/noremote
  echo x > "$repo/x.txt"
  /usr/bin/git -C "$repo" add -A && git -C "$repo" commit -qm x
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/noremote -m merge
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "NO_REMOTE:" "a repo with no origin says so"
  assert_not_contains "$out" "FETCH_FAILED" "and raises no fetch alarm"
  assert_contains "$out" "STALE_STATE: 0"
}

test_cleanup_treats_a_local_only_default_branch_as_healthy() {
  # ceo_branch_resolves accepts a purely local refs/heads/<name>, so
  # DEFAULT_BRANCH can name a branch origin has never heard of. Fetching that
  # always fails against a perfectly healthy remote.
  local repo; repo="$(mkclone_cleanup localonly trunk ceo/localonly no_lag)"
  git -C "$repo" checkout -q -b main
  git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "DEFAULT_BRANCH: main" "the local-only branch is chosen"
  assert_not_contains "$out" "FETCH_FAILED" "a healthy origin raises no alarm"
  assert_contains "$out" "STALE_STATE: 0"
}

test_cleanup_surfaces_a_leaked_ownership_marker() {
  # The branch is gone but its marker survives. Counting that as a clean reap
  # is the report lying in the direction this ticket exists to stop.
  local repo; repo="$(mkrepo_cleanup leakedmarker main)"
  git -C "$repo" checkout -q -b ceo/leaked
  echo x > "$repo/x.txt"
  /usr/bin/git -C "$repo" add -A && git -C "$repo" commit -qm x
  local ref; ref="$(mkmarker "$repo" ceo/leaked)"
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff ceo/leaked -m merge
  set_repos_md "$repo"

  # Hold the ref's lock so `update-ref -d` cannot take it.
  local lock="$repo/.git/$ref.lock"
  mkdir -p "$(dirname "$lock")" && : > "$lock"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  rm -f "$lock"
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "BRANCH_DELETED: ceo/leaked"
  assert_contains "$out" "MARKER_DELETE_FAILED:"
  assert_contains "$out" "STALE_STATE: 1" "a leaked marker is counted"
  assert_contains "$out" "AI_NEEDED: yes" "and reaches a human"
  assert_eq "$(git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 && echo PRESENT || echo GONE)" \
    "PRESENT" "the marker really did leak"
}

test_cleanup_reports_every_reason_a_human_is_needed() {
  # Two problems in one run must both appear. The nested per-combination form
  # this replaced had arms no fixture could reach.
  local repo; repo="$(mkclone_cleanup tworeasons main ceo/tworeasons local_lag)"
  git -C "$repo" checkout -q -b ceo/abandoned
  echo x > "$repo/x.txt"
  /usr/bin/git -C "$repo" add -A && git -C "$repo" commit -qm x
  git -C "$repo" checkout -q main
  # Age it past the orphan threshold.
  local old; old="$(date -u -v-30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%S)"
  GIT_COMMITTER_DATE="$old" git -C "$repo" branch -f ceo/abandoned ceo/abandoned
  set_repos_md "$repo"

  local out rc=0
  out=$(bash "$CLEANUP" 2>&1) || rc=$?
  assert_eq "$rc" "0" "cleanup must succeed"
  assert_contains "$out" "REAP_FAILED: 1"
  assert_contains "$out" "failed to reap" "the reap failure is named"
  assert_contains "$out" "AI_NEEDED: yes"
}

test_mkrepo_cleanup_rejects_duplicate_fixture_name() {
  local repo; repo="$(mkrepo_cleanup dupname-mkrepo main)"
  assert_file_exists "$repo/base.txt" "first mkrepo_cleanup call must succeed"

  # Capture stdout and stderr separately. The harm the guard prevents is on
  # stdout: without it the second call re-inits, `git commit` writes "nothing to
  # commit" to STDOUT, and that text is returned to the caller as part of the
  # path. An arm that merges the streams cannot tell the refusal from the harm.
  local err out rc=0
  err="$TMP/dupname-mkrepo.err"
  out=$(mkrepo_cleanup dupname-mkrepo main 2>"$err") || rc=$?
  assert_eq "$rc" "1" "mkrepo_cleanup must return 1 on duplicate fixture name"
  assert_eq "$out" "" "a refused call returns no path on stdout"
  assert_contains "$(cat "$err")" "mkrepo_cleanup: duplicate fixture name 'dupname-mkrepo'"

  # And the first fixture is untouched by the refusal, not merely un-returned.
  assert_eq "$(cat "$repo/base.txt")" "init" "the first fixture's content survives"
  assert_eq "$(git -C "$repo" rev-list --count HEAD)" "1" \
    "the first fixture still has exactly its one init commit"
}

test_mkclone_cleanup_rejects_duplicate_fixture_name() {
  local repo; repo="$(mkclone_cleanup dupname-clone main ceo/dup no_lag)"
  assert_file_exists "$repo/base.txt" "first mkclone_cleanup call must succeed"
  local before; before="$(git -C "$repo" rev-parse HEAD)"

  local err out rc=0
  err="$TMP/dupname-clone.err"
  out=$(mkclone_cleanup dupname-clone main ceo/dup no_lag 2>"$err") || rc=$?
  assert_eq "$rc" "1" "mkclone_cleanup must return 1 on duplicate fixture name"
  assert_eq "$out" "" "a refused call returns no path on stdout"
  assert_contains "$(cat "$err")" "mkclone_cleanup: duplicate fixture name 'dupname-clone'"

  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$before" \
    "the first fixture's HEAD is unmoved by the refusal"
  assert_eq "$(cat "$repo/base.txt")" "init" "the first fixture's content survives"
}

run_tests
