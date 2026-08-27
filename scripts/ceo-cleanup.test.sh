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

run_tests
