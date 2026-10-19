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
  git -C "$dir" init -b main -q 2>/dev/null || { git -C "$dir" init -q && git -C "$dir" checkout -q -b main 2>/dev/null || true; }
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

# -----------------------------------------------------------------------------
# Regression tests for issue #613
# -----------------------------------------------------------------------------

test_git_monitor_preserves_since_on_steady_state_firing() {
  local repo_dir="$TMP/repos/dirty-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "test" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "Initial commit"
  echo "dirty" > "$repo_dir/README.md"

  # Run 1: initial transition into firing
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  assert_file_exists "$state_file" "state file must exist"

  local since_1
  since_1=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  [ -n "$since_1" ] || fail "since field must be present in state file"

  # Simulate time passing by modifying last_check and manually backdating since
  local historical_since="2026-10-17T03:00:00-0400"
  sed -i.bak "s|^since: .*|since: $historical_since|" "$state_file"
  rm -f "${state_file}.bak"

  # Run 2: steady-state firing (dirty repo remains dirty)
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local status_2 since_2 last_check_2
  status_2=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  since_2=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  last_check_2=$(awk '/^last_check:/ {print $2}' "$state_file" || echo "")

  assert_eq "$status_2" "firing" "status must stay firing"
  assert_eq "$since_2" "$historical_since" "steady-state firing must preserve historical since timestamp"
  [ "$last_check_2" != "$historical_since" ] || fail_test "last_check must be updated on repeat run"
}

test_git_monitor_updates_since_on_transition() {
  local repo_dir="$TMP/repos/transition-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "clean" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "Initial commit"

  # Run 1: clean baseline
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local status_1 since_1
  status_1=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  since_1=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status_1" "clear" "run 1 must be clear"

  # Backdate since_1 to verify transition updates it
  local old_ts="2026-10-15T00:00:00-0400"
  sed -i.bak "s|^since: .*|since: $old_ts|" "$state_file"
  rm -f "${state_file}.bak"

  # Make dirty -> transition to firing
  echo "dirty change" >> "$repo_dir/README.md"
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local status_2 since_2
  status_2=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  since_2=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status_2" "firing" "run 2 must transition to firing"
  [ "$since_2" != "$old_ts" ] || fail_test "since must update on clear->firing transition"

  # Backdate since_2 to verify the transition to clear updates since again
  local firing_ts="2026-10-16T00:00:00-0400"
  sed -i.bak "s|^since: .*|since: $firing_ts|" "$state_file"
  rm -f "${state_file}.bak"

  # Recover to clean -> transition back to clear
  git -C "$repo_dir" checkout -- README.md
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local status_3 since_3
  status_3=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  since_3=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status_3" "clear" "run 3 must transition to clear"
  [ "$since_3" != "$firing_ts" ] || fail_test "since must update on firing->clear transition"
}

test_git_monitor_configured_upstream_non_origin_remote() {
  local remote_dir="$TMP/upstream-central.git"
  local repo_dir="$TMP/repos/non-origin-remote-repo"
  mkdir -p "$remote_dir" "$repo_dir"
  git -C "$remote_dir" init --bare -q

  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "base commit"
  git -C "$repo_dir" branch -M main

  # Add remote named 'upstream' (not origin!) and set tracking
  git -C "$repo_dir" remote add upstream "$remote_dir"
  git -C "$repo_dir" push -q -u upstream main:main
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

  # Clone another checkout to push 2 commits ahead to upstream
  local peer_dir="$TMP/peer-checkout"
  mkdir -p "$peer_dir"
  git clone -q -b main "$remote_dir" "$peer_dir"
  init_fixture_repo "$peer_dir"
  echo "update 1" >> "$peer_dir/README.md"
  git -C "$peer_dir" commit -q -am "peer commit 1"
  echo "update 2" >> "$peer_dir/README.md"
  git -C "$peer_dir" commit -q -am "peer commit 2"
  git -C "$peer_dir" push -q origin main

  # Now local repo_dir is 2 commits behind upstream/main
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local status
  status=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status" "firing" "repo behind non-origin remote must yield firing status"

  local content
  content=$(cat "$state_file")
  assert_contains "$content" "non-origin-remote-repo" "state file must mention the repo"
  assert_contains "$content" "2 commits behind" "state file must report 2 commits behind"
}

test_git_monitor_configured_upstream_different_branch_name() {
  local remote_dir="$TMP/branch-diff.git"
  local repo_dir="$TMP/repos/branch-diff-repo"
  mkdir -p "$remote_dir" "$repo_dir"
  git -C "$remote_dir" init --bare -q

  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "base commit"
  git -C "$repo_dir" branch -M main
  git -C "$repo_dir" remote add origin "$remote_dir"
  git -C "$repo_dir" push -q -u origin main:main
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main

  # Switch to local branch 'feature' tracking 'origin/main'
  git -C "$repo_dir" checkout -q -b feature --track origin/main

  # Peer pushes a commit to origin/main
  local peer_dir="$TMP/peer-diff"
  git clone -q -b main "$remote_dir" "$peer_dir"
  init_fixture_repo "$peer_dir"
  echo "update" >> "$peer_dir/README.md"
  git -C "$peer_dir" commit -q -am "peer commit"
  git -C "$peer_dir" push -q origin main

  # Now feature is 1 commit behind origin/main
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local status
  status=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status" "firing" "local branch tracking different remote branch must detect behind commits"

  local content
  content=$(cat "$state_file")
  assert_contains "$content" "branch-diff-repo" "state file must mention branch-diff-repo"
  assert_contains "$content" "1 commits behind" "state file must report 1 commit behind"
}

test_git_monitor_fetch_failure_explicit_and_does_not_masquerade_as_clean() {
  local repo_dir="$TMP/repos/unreachable-remote-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "base commit"

  # Configure remote pointing to a non-existent / unreachable path
  git -C "$repo_dir" remote add origin "$TMP/nonexistent-remote.git"
  # Artificially set upstream config for main
  git -C "$repo_dir" config branch.main.remote origin
  git -C "$repo_dir" config branch.main.merge refs/heads/main

  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local content
  content=$(cat "$state_file")

  # A failed fetch must NOT be silently ignored and declare everything clean & up to date
  assert_not_contains "$content" "All tracked repositories are clean and up to date" \
    "unverified remote must not be reported as clean and up to date"
  assert_contains "$content" "Fetch Failures" "alert body must disclose fetch failure"
}

test_git_monitor_missing_upstream_noted_in_state() {
  local repo_dir="$TMP/repos/no-upstream-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "base commit"

  # No remote or upstream configured
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local content
  content=$(cat "$state_file")
  assert_contains "$content" "no-upstream-repo" "state file must note unconfigured upstream repo"
}

test_git_monitor_inbox_repeat_runs_do_not_duplicate_or_re_escalate() {
  local repo_dir="$TMP/repos/dirty-inbox-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "dirty" > "$repo_dir/dirty.txt"

  local inbox_file="$CEO_DIR/inbox/git-monitor.md"

  # Run 1: clear -> firing transition
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  assert_file_exists "$inbox_file" "inbox file must be created"

  local count_1
  count_1=$(grep -c "<!-- git-monitor -->" "$inbox_file" || true)
  assert_eq "$count_1" "1" "first run must create exactly one inbox task"

  # Run 2: repeat run while still firing
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  local count_2
  count_2=$(grep -c "<!-- git-monitor -->" "$inbox_file" || true)
  assert_eq "$count_2" "1" "repeat run must not duplicate inbox task"

  # Simulate user checking off the task: - [ ] -> - [x]
  sed -i.bak 's/^- \[ \]/- [x]/' "$inbox_file"
  rm -f "${inbox_file}.bak"

  # Run 3: steady-state firing after user checked off task
  # Must NOT re-append a new task!
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  local open_count
  open_count=$(grep -c '^- \[ \].*<!-- git-monitor -->' "$inbox_file" || true)
  assert_eq "$open_count" "0" "steady state firing must not re-escalate checked off task"
}

test_git_monitor_inbox_recovery_does_not_duplicate_done_lines() {
  local repo_dir="$TMP/repos/recovery-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "dirty" > "$repo_dir/dirty.txt"

  local inbox_file="$CEO_DIR/inbox/git-monitor.md"

  # Run 1: firing
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  # Now clean the repo
  rm -f "$repo_dir/dirty.txt"

  # Run 2: recovery (firing -> clear)
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local done_count
  done_count=$(grep -c -- "- \[done\].*<!-- git-monitor -->" "$inbox_file" || true)
  assert_eq "$done_count" "1" "recovery must produce exactly one [done] line, not duplicate it"
}

test_git_monitor_detects_git_worktree() {
  local main_repo="$TMP/repos/main-repo"
  local wt_dir="$TMP/repos/linked-worktree"
  mkdir -p "$main_repo"
  init_fixture_repo "$main_repo"
  echo "test" > "$main_repo/README.md"
  git -C "$main_repo" add README.md
  git -C "$main_repo" commit -q -m "Initial commit"

  # Create a linked worktree (where .git is a file, not a directory)
  git -C "$main_repo" worktree add "$wt_dir" -q -b worktree-branch
  assert_file_exists "$wt_dir/.git" "linked worktree .git file must exist"
  assert_eq "$([ -f "$wt_dir/.git" ] && echo "file")" "file" ".git in worktree is a file"

  # Dirty the worktree
  echo "dirty in worktree" > "$wt_dir/scratch.txt"

  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1

  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local status
  status=$(awk '/^status:/ {print $2}' "$state_file" || echo "")
  assert_eq "$status" "firing" "dirty linked worktree must cause firing status"

  local content
  content=$(cat "$state_file")
  assert_contains "$content" "linked-worktree" "state file must mention dirty linked worktree"
}

test_git_monitor_outcome_file() {
  local outcome_file="$TMP/runner-outcome"
  export CEO_RUNNER_OUTCOME_FILE="$outcome_file"

  local repo_dir="$TMP/repos/outcome-repo"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "clean" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "Initial commit"

  # Run 1: clean baseline (no inbox task created) -> outcome is noop
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  assert_eq "$(cat "$outcome_file" 2>/dev/null)" "noop" "clear run with no inbox mutation must report noop"

  # Dirty repo -> transition to firing (inbox task created) -> outcome is fired
  echo "dirty" >> "$repo_dir/README.md"
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  assert_eq "$(cat "$outcome_file" 2>/dev/null)" "fired" "run with inbox task added must report fired"

  # Repeat run while still dirty (no new inbox mutation) -> outcome is noop
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  assert_eq "$(cat "$outcome_file" 2>/dev/null)" "noop" "steady-state firing run without inbox mutation must report noop"
}

run_tests

