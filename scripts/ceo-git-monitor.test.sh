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
  mkdir -p "$TMP/repos"
  
  git config --global user.email "test@example.com"
  git config --global user.name "Test User"
}

teardown() {
  rm -rf "$TMP"
  unset CEO_VAULT CEO_DIR CEO_GIT_DIRS
}

test_git_monitor_clean_state() {
  local repo_dir="$TMP/repos/clean-repo"
  mkdir -p "$repo_dir"
  cd "$repo_dir"
  git init -q
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
  git init -q
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
