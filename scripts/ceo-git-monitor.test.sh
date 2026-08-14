#!/bin/bash
# Tests for ceo-git-monitor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  export CEO_VAULT="$TMP"
  export CEO_DIR="$TMP/CEO"
  mkdir -p "$CEO_DIR"
  
  
  export CEO_GIT_DIRS="$TMP/repos"
  mkdir -p "$TMP/repos" "$TMP/hooks-none"
  
  # Per-process, not `git config --global`. The global form wrote a placeholder
  # identity into the developer's own ~/.gitconfig and left it there — teardown
  # never restored it, and on a machine whose repos inherit the global identity
  # that byline then lands on real commits (nhangen/llm-tools#397).
  export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
  export GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com"
}

teardown() {
  rm -rf "$TMP"
  unset CEO_VAULT CEO_DIR CEO_GIT_DIRS
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

# A fixture repo, with hooks pointed at an empty dir of its own. A machine with a
# global `core.hooksPath` identity gate installed refuses a placeholder committer,
# which is correct for a repo you might push and wrong for one that lives inside
# `mktemp -d` for the length of one assertion. Opting out here — explicitly, in
# the throwaway repo — beats teaching the gate to guess which repos are real.
# The empty hooks dir lives outside the repo: inside it, it is one stray file away
# from making a "clean worktree" fixture dirty and quietly inverting an assertion.
init_fixture_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config core.hooksPath "$TMP/hooks-none"
}

test_git_monitor_clean_state() {
  local repo_dir="$TMP/repos/clean-repo"
  mkdir -p "$repo_dir"
  cd "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "test" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  assert_file_exists "$state_file" "state file must be created"
  
  local status
  status=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status" "clear" "clean repo must yield clear status"
}

test_git_monitor_dirty_worktree() {
  local repo_dir="$TMP/repos/dirty-repo"
  mkdir -p "$repo_dir"
  cd "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "test" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  
  echo "dirty" > README.md
  
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  
  local status
  status=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status" "firing" "dirty repo must yield firing status"
  
  local content
  content=$(cat "$state_file")
  assert_contains "$content" "dirty-repo" "state file must mention the dirty repo"
}

run_tests
