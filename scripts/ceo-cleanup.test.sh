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

run_tests
