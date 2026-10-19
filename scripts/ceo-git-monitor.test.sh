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
  unset CEO_VAULT CEO_DIR CEO_GIT_DIRS CEO_RUNNER_OUTCOME_FILE
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

# Every fixture advertised as clean must have an observable upstream. The bare
# remote is outside CEO_GIT_DIRS and only ever uses the local filesystem.
configure_fixture_upstream() {
  local repo_dir="$1"
  local remote_dir
  remote_dir="$TMP/remotes/$(basename "$repo_dir").git"
  mkdir -p "$remote_dir"
  git -C "$remote_dir" init --bare -q
  git -C "$repo_dir" remote add origin "$remote_dir"
  git -C "$repo_dir" push -q -u origin HEAD:main
  git -C "$remote_dir" symbolic-ref HEAD refs/heads/main
}

create_tracked_fixture() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "fixture baseline"
  configure_fixture_upstream "$repo_dir"
}

test_git_monitor_clean_state() {
  local repo_dir="$TMP/repos/clean-repo"
  mkdir -p "$repo_dir"
  cd "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "test" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  configure_fixture_upstream "$repo_dir"
  
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
  configure_fixture_upstream "$repo_dir"
  
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
  configure_fixture_upstream "$repo_dir"
  echo "dirty" > "$repo_dir/README.md"

  # Run 1: initial transition into firing
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >/dev/null 2>&1
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  assert_file_exists "$state_file" "state file must exist"

  local since_1
  since_1=$(awk '/^since:/ {print $2}' "$state_file" || echo "")
  [ -n "$since_1" ] || fail_test "since field must be present in state file"

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
  configure_fixture_upstream "$repo_dir"

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
  # The tracking ref must resolve or the monitor never reaches fetch.
  git -C "$repo_dir" update-ref refs/remotes/origin/main HEAD

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
  assert_eq "$(state_field status)" "firing" "missing upstream on first run is not verified clean"
  assert_eq "$(state_field observation_failed)" "1" "missing upstream must record failed observation"
  assert_eq "$(state_field unconfigured_count)" "1" "missing upstream must be counted"
  assert_not_contains "$content" "clean and up to date" "unknown upstream must not assert successful verification"
}

test_git_monitor_inbox_repeat_runs_do_not_duplicate_or_re_escalate() {
  local repo_dir="$TMP/repos/dirty-inbox-repo"
  mkdir -p "$repo_dir"
  create_tracked_fixture "$repo_dir"
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
  create_tracked_fixture "$repo_dir"
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
  configure_fixture_upstream "$main_repo"

  # Create a linked worktree (where .git is a file, not a directory)
  git -C "$main_repo" worktree add "$wt_dir" -q -b worktree-branch
  git -C "$wt_dir" branch --set-upstream-to origin/main >/dev/null
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
  configure_fixture_upstream "$repo_dir"

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

# -----------------------------------------------------------------------------
# Unknown observations must never synthesize recovery.
# -----------------------------------------------------------------------------

state_field() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "$CEO_DIR/alerts/git-monitor.md"
}

inbox_marker_count() {
  grep -c '<!-- git-monitor -->' "$CEO_DIR/inbox/git-monitor.md" || true
}

run_monitor() {
  bash "$SCRIPT_DIR/ceo-git-monitor.sh" >"$TMP/monitor.log" 2>&1
}

exercise_unobservable_upstream() {
  local reason="$1"
  local repo_dir="$TMP/repos/unknown-upstream-repo"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  assert_eq "$(state_field status)" "firing" "fixture must begin with an active incident"
  local before
  before=$(cat "$inbox_file")
  local historical_since="2026-10-15T00:00:00-0400"
  sed -i.bak "s|^since: .*|since: $historical_since|" "$CEO_DIR/alerts/git-monitor.md"
  rm -f "$CEO_DIR/alerts/git-monitor.md.bak"
  git -C "$repo_dir" checkout -- README.md

  case "$reason" in
    missing) git -C "$repo_dir" branch --unset-upstream ;;
    detached) git -C "$repo_dir" checkout -q --detach ;;
    unresolvable) git -C "$repo_dir" config branch.main.merge refs/heads/not-present ;;
  esac

  run_monitor
  assert_eq "$(state_field status)" "firing" "$reason upstream must not clear prior firing"
  assert_eq "$(state_field observation_failed)" "1" "$reason upstream is an unknown observation"
  if [ "$reason" = unresolvable ]; then
    local fetch_failures observation_failures
    fetch_failures=$(state_field fetch_failed_count)
    observation_failures=$(state_field observation_failed_count)
    assert_eq "$(( ${fetch_failures:-0} + ${observation_failures:-0} ))" "1" \
      "configured but unresolvable upstream must disclose a fetch or resolution failure"
  else
    assert_eq "$(state_field unconfigured_count)" "1" "$reason upstream must be disclosed"
  fi
  assert_eq "$(state_field since)" "$historical_since" "unknown observation must preserve incident age"
  assert_eq "$(cat "$inbox_file")" "$before" "unknown observation must not complete the inbox task"
  assert_not_contains "$(cat "$CEO_DIR/alerts/git-monitor.md")" "clean and up to date" \
    "unknown observation must not claim a clean upstream"

  run_monitor
  assert_eq "$(cat "$inbox_file")" "$before" "repeated unknown observations must preserve the inbox task"

  case "$reason" in
    missing) git -C "$repo_dir" branch --set-upstream-to origin/main >/dev/null ;;
    detached) git -C "$repo_dir" checkout -q main ;;
    unresolvable) git -C "$repo_dir" config branch.main.merge refs/heads/main ;;
  esac
  run_monitor
  assert_eq "$(state_field status)" "clear" "verified upstream recovery must clear"
  assert_eq "$(state_field observation_failed)" "0" "verified recovery must reset failed observation"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "verified recovery must complete exactly one task"
}

test_git_monitor_missing_upstream_does_not_clear_firing() {
  exercise_unobservable_upstream missing
}

test_git_monitor_detached_head_does_not_clear_firing() {
  exercise_unobservable_upstream detached
}

test_git_monitor_unresolvable_upstream_does_not_clear_firing() {
  exercise_unobservable_upstream unresolvable
}

# Faults are scoped to one monitor process. All non-fault operations delegate to
# real local tools; no global Git configuration, permissions, or timing races.
# Every injected operation leaves a sentinel, making an unreached fault fail.
install_fault_tools() {
  mkdir -p "$TMP/fault-bin"
  export TEST_REAL_GIT TEST_REAL_MV TEST_REAL_AWK TEST_REAL_FIND TEST_FAULT_ROOT
  TEST_REAL_GIT=$(command -v git)
  TEST_REAL_MV=$(command -v mv)
  TEST_REAL_AWK=$(command -v awk)
  TEST_REAL_FIND=$(command -v find)
  TEST_FAULT_ROOT="$TMP"
  cat > "$TMP/fault-bin/git" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = rev-list ]; then
    case "${TEST_FAULT_MODE:-}" in
      rev-list)
        echo reached > "$TEST_FAULT_ROOT/fault-hit"
        exit 73
        ;;
      invalid-rev-list)
        echo reached > "$TEST_FAULT_ROOT/fault-hit"
        echo not-a-count
        exit 0
        ;;
    esac
  fi
  if [ "$arg" = rev-parse ] && [ "${TEST_FAULT_MODE:-}" = upstream-resolve ]; then
    for ref in "$@"; do
      if [ "$ref" = '@{u}' ]; then
        echo reached > "$TEST_FAULT_ROOT/fault-hit"
        # Real rev-parse failures can emit this misleading nonempty stdout.
        echo '@{u}'
        exit 73
      fi
    done
  fi
  if [ "$arg" = fetch ]; then
    "$TEST_REAL_GIT" "$@"
    rc=$?
    [ "$rc" -eq 0 ] && echo fetched > "$TEST_FAULT_ROOT/fetch-succeeded"
    exit "$rc"
  fi
 done
exec "$TEST_REAL_GIT" "$@"
SH
  cat > "$TMP/fault-bin/mv" <<'SH'
#!/bin/bash
for dest in "$@"; do :; done
if [ "$dest" = "$CEO_DIR/inbox/git-monitor.md" ] && [ "${TEST_FAULT_MODE:-}" = inbox-replace ]; then
  echo reached > "$TEST_FAULT_ROOT/fault-hit"
  exit 73
fi
if [ "$dest" = "$CEO_DIR/alerts/git-monitor.md" ] && [ "${TEST_FAULT_MODE:-}" = state-ack ]; then
  count=0
  [ ! -f "$TEST_FAULT_ROOT/state-moves" ] || read -r count < "$TEST_FAULT_ROOT/state-moves"
  count=$((count + 1))
  echo "$count" > "$TEST_FAULT_ROOT/state-moves"
  if [ "$count" -eq 2 ]; then
    echo reached > "$TEST_FAULT_ROOT/fault-hit"
    exit 73
  fi
fi
exec "$TEST_REAL_MV" "$@"
SH
  cat > "$TMP/fault-bin/awk" <<'SH'
#!/bin/bash
has_inbox=0
has_transform=0
has_state=0
has_field=0
for arg in "$@"; do
  [ "$arg" != "$CEO_DIR/inbox/git-monitor.md" ] || has_inbox=1
  [ "$arg" != "$CEO_DIR/alerts/git-monitor.md" ] || has_state=1
  [ "$arg" != "f=${TEST_FAULT_FIELD:-}" ] || has_field=1
  case "$arg" in *'{ print }'*) has_transform=1 ;; esac
 done
if [ "${TEST_FAULT_MODE:-}" = state-read ] && [ "$has_state" -eq 1 ] && [ "$has_field" -eq 1 ]; then
  echo reached > "$TEST_FAULT_ROOT/fault-hit"
  exit "${TEST_FAULT_EXIT:-73}"
fi
if [ "${TEST_FAULT_MODE:-}" = inbox-rewrite ] && [ "$has_inbox" -eq 1 ] && [ "$has_transform" -eq 1 ]; then
  echo reached > "$TEST_FAULT_ROOT/fault-hit"
  exit 73
fi
exec "$TEST_REAL_AWK" "$@"
SH
  cat > "$TMP/fault-bin/find" <<'SH'
#!/bin/bash
case "${TEST_FAULT_MODE:-}" in
  discovery|partial-discovery)
    echo reached > "$TEST_FAULT_ROOT/fault-hit"
    if [ "$TEST_FAULT_MODE" = partial-discovery ]; then
      "$TEST_REAL_FIND" "$@" || exit $?
    fi
    exit 73
    ;;
esac
exec "$TEST_REAL_FIND" "$@"
SH
  # printf is a Bash builtin, so PATH alone cannot inject an append failure.
  # BASH_ENV overrides only this monitor invocation and only the task emission.
  cat > "$TMP/fault-env.sh" <<'SH'
printf() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *'- [ ]'*'<!-- git-monitor -->'*)
        if [ "${TEST_FAULT_MODE:-}" = inbox-append ]; then
          builtin printf 'reached\n' > "$TEST_FAULT_ROOT/fault-hit"
          builtin printf '%s' 'incomplete task write'
          return 73
        fi
        ;;
    esac
  done
  builtin printf "$@"
}
SH
  chmod +x "$TMP/fault-bin/git" "$TMP/fault-bin/mv" "$TMP/fault-bin/awk" "$TMP/fault-bin/find"
}

run_monitor_with_fault() {
  TEST_FAULT_MODE="$1" _CEO_PATH_AUGMENTED=1 \
    PATH="$TMP/fault-bin:$PATH" BASH_ENV="$TMP/fault-env.sh" \
    bash "$SCRIPT_DIR/ceo-git-monitor.sh" >"$TMP/monitor-fault.log" 2>&1
}

assert_fault_failed() {
  local mode="$1" rc=0
  rm -f "$TMP/fault-hit" "$TMP/state-moves"
  run_monitor_with_fault "$mode" || rc=$?
  [ "$rc" -ne 0 ] || fail_test "$mode failure must fail the monitor invocation"
  assert_file_exists "$TMP/fault-hit" "$mode injection must actually be reached"
}

assert_incident_recorded() {
  local incident="$1"
  [ -n "$incident" ] && [ "$incident" != none ] || fail_test "firing incident must have a nonempty stable token"
}

exercise_comparison_failure() {
  local fault="$1"
  local repo_dir="$TMP/repos/rev-list-failure"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  local before
  before=$(cat "$CEO_DIR/inbox/git-monitor.md")
  git -C "$repo_dir" checkout -- README.md
  install_fault_tools
  run_monitor_with_fault "$fault"
  assert_file_exists "$TMP/fetch-succeeded" "fixture must successfully fetch before $fault fails"
  assert_file_exists "$TMP/fault-hit" "$fault injection must actually be reached"
  assert_eq "$(state_field status)" "firing" "failed upstream comparison must not synthesize recovery"
  assert_eq "$(state_field observation_failed)" "1" "$fault failure must be recorded as unknown"
  assert_eq "$(state_field fetch_failed_count)" "0" "comparison fixture must not fail at fetch"
  assert_eq "$(state_field observation_failed_count)" "1" "post-fetch comparison failure must be counted"
  assert_eq "$(cat "$CEO_DIR/inbox/git-monitor.md")" "$before" "rev-list failure must not complete the task"
  assert_not_contains "$(cat "$CEO_DIR/alerts/git-monitor.md")" "clean and up to date" \
    "failed comparison cannot claim zero behind"
  run_monitor
  assert_eq "$(state_field status)" "clear" "successful comparison must permit recovery"
}

test_git_monitor_successful_fetch_failed_rev_list_is_unknown() {
  exercise_comparison_failure rev-list
}

test_git_monitor_successful_fetch_unresolvable_upstream_is_unknown() {
  exercise_comparison_failure upstream-resolve
}

test_git_monitor_successful_fetch_invalid_rev_list_is_unknown() {
  exercise_comparison_failure invalid-rev-list
}

# -----------------------------------------------------------------------------
# Durable inbox intent: state -> inbox mutation -> acknowledgment, with retries.
# -----------------------------------------------------------------------------

exercise_open_retry() {
  local fault="$1"
  local repo_dir="$TMP/repos/open-retry"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$CEO_DIR/inbox"
  echo '- [ ] Keep my unrelated task' > "$inbox_file"
  local before
  before=$(cat "$inbox_file")
  export CEO_RUNNER_OUTCOME_FILE="$TMP/runner-outcome"
  install_fault_tools
  assert_fault_failed "$fault"
  assert_eq "$(state_field status)" "firing" "failed escalation must retain observed firing state"
  assert_eq "$(state_field inbox_pending)" "open" "failed escalation must leave durable open intent"
  local incident
  incident=$(state_field inbox_incident)
  assert_incident_recorded "$incident"
  assert_eq "$(cat "$inbox_file")" "$before" "failed atomic escalation must preserve the original inbox"

  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "successful escalation retry must acknowledge intent"
  assert_eq "$(state_field inbox_incident)" "$incident" "retry must preserve firing incident identity"
  assert_eq "$(inbox_marker_count)" "1" "retry must create exactly one task"
  assert_eq "$(grep -c '^- \[ \].*<!-- git-monitor -->' "$inbox_file" || true)" "1" "retry must create an open task"
  assert_contains "$(cat "$inbox_file")" "<!-- git-monitor-incident: $incident -->" "task must carry the durable incident token"
  assert_contains "$(cat "$inbox_file")" "$before" "retry must preserve unrelated inbox entries"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "fired" "successful retried inbox mutation must report fired"

  run_monitor
  assert_eq "$(inbox_marker_count)" "1" "a second successful run must not duplicate the retried task"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "noop" "steady state after retry must report noop"
}

test_git_monitor_retries_failed_inbox_append() {
  exercise_open_retry inbox-append
}

test_git_monitor_retries_failed_inbox_replace() {
  exercise_open_retry inbox-replace
}

exercise_close_retry() {
  local fault="$1"
  local repo_dir="$TMP/repos/close-retry"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  echo '- [ ] Keep my unrelated task' >> "$inbox_file"
  local before incident
  before=$(cat "$inbox_file")
  incident=$(state_field inbox_incident)
  assert_incident_recorded "$incident"
  git -C "$repo_dir" checkout -- README.md
  export CEO_RUNNER_OUTCOME_FILE="$TMP/runner-outcome"
  install_fault_tools
  assert_fault_failed "$fault"
  assert_eq "$(state_field status)" "clear" "failed completion must retain verified recovery state"
  assert_eq "$(state_field inbox_pending)" "close" "failed completion must leave durable close intent"
  assert_eq "$(state_field inbox_incident)" "$incident" "completion intent must refer to the original incident"
  assert_eq "$(cat "$inbox_file")" "$before" "failed atomic completion must preserve original inbox"

  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "successful completion retry must acknowledge intent"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" "retry must complete exactly one task"
  assert_eq "$(grep -c '^- \[ \].*<!-- git-monitor -->' "$inbox_file" || true)" "0" "retry must leave no stale active task"
  assert_contains "$(cat "$inbox_file")" '- [ ] Keep my unrelated task' "completion must preserve unrelated inbox entries"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "fired" "successful retried completion must report fired"
  run_monitor
  assert_eq "$(inbox_marker_count)" "1" "repeated completion must not duplicate done lines"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "noop" "acknowledged completion must become noop"
}

test_git_monitor_retries_failed_recovery_rewrite() {
  exercise_close_retry inbox-rewrite
}

test_git_monitor_retries_failed_recovery_replace() {
  exercise_close_retry inbox-replace
}

test_git_monitor_failed_open_ack_does_not_reopen_checked_task() {
  local repo_dir="$TMP/repos/open-ack-retry"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  install_fault_tools
  assert_fault_failed state-ack
  assert_eq "$(state_field inbox_pending)" "open" "failed acknowledgment must leave open intent durable"
  local incident
  incident=$(state_field inbox_incident)
  assert_incident_recorded "$incident"
  assert_eq "$(inbox_marker_count)" "1" "inbox mutation must succeed before acknowledgment fault"
  assert_contains "$(cat "$inbox_file")" "<!-- git-monitor-incident: $incident -->" "created task must carry its incident identity"
  sed -i.bak 's/^- \[ \]/- [x]/' "$inbox_file"
  rm -f "$inbox_file.bak"
  local checked_off
  checked_off=$(cat "$inbox_file")
  export CEO_RUNNER_OUTCOME_FILE="$TMP/runner-outcome"
  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "retry must acknowledge the already-present incident"
  assert_eq "$(state_field inbox_incident)" "$incident" "ack retry must preserve incident identity"
  assert_eq "$(cat "$inbox_file")" "$checked_off" "ack retry must not duplicate or reopen a checked-off task"
  assert_eq "$(inbox_marker_count)" "1" "ack retry must keep exactly one incident entry"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "noop" "ack-only retry must not report an inbox mutation"
  run_monitor
  assert_eq "$(cat "$inbox_file")" "$checked_off" "later steady state must continue respecting the checked task"
}

test_git_monitor_failed_close_ack_does_not_duplicate_done_task() {
  local repo_dir="$TMP/repos/close-ack-retry"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  local incident
  incident=$(state_field inbox_incident)
  assert_incident_recorded "$incident"
  git -C "$repo_dir" checkout -- README.md
  install_fault_tools
  assert_fault_failed state-ack
  assert_eq "$(state_field inbox_pending)" "close" "failed acknowledgment must leave close intent durable"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" "completion must succeed before acknowledgment fault"
  local completed
  completed=$(cat "$inbox_file")
  export CEO_RUNNER_OUTCOME_FILE="$TMP/runner-outcome"
  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "retry must acknowledge already-completed task"
  assert_eq "$(cat "$inbox_file")" "$completed" "ack retry must not duplicate or change completed task"
  assert_eq "$(inbox_marker_count)" "1" "recovery acknowledgment retry must keep one entry"
  assert_eq "$(cat "$CEO_RUNNER_OUTCOME_FILE")" "noop" "completion ack-only retry must report noop"
}

test_git_monitor_failed_adoption_ack_respects_checked_legacy_task() {
  local repo_dir="$TMP/repos/legacy-ack-retry"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$CEO_DIR/inbox"
  echo '- [ ] Existing legacy git task <!-- git-monitor -->' > "$inbox_file"
  echo '- [ ] Keep my unrelated task' >> "$inbox_file"
  install_fault_tools
  assert_fault_failed state-ack
  assert_eq "$(state_field inbox_pending)" "open" "failed adoption acknowledgment must preserve open intent"
  local incident
  incident=$(state_field inbox_incident)
  assert_incident_recorded "$incident"
  assert_eq "$(inbox_marker_count)" "1" "adoption must not append a duplicate active task"
  assert_contains "$(cat "$inbox_file")" "<!-- git-monitor-incident: $incident -->" \
    "legacy task must acquire current incident identity before acknowledgment"
  sed -i.bak '/<!-- git-monitor -->/s/^- \[ \]/- [x]/' "$inbox_file"
  rm -f "$inbox_file.bak"
  local checked_off
  checked_off=$(cat "$inbox_file")
  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "adoption retry must acknowledge existing checked incident"
  assert_eq "$(cat "$inbox_file")" "$checked_off" "adoption retry must not reopen the checked legacy task"
  assert_eq "$(inbox_marker_count)" "1" "adoption retry must preserve exactly one task"
}

test_git_monitor_pending_open_is_cancelled_by_verified_recovery() {
  local repo_dir="$TMP/repos/recovered-before-open"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$CEO_DIR/inbox"
  echo '- [ ] Keep my unrelated task' > "$inbox_file"
  local before
  before=$(cat "$inbox_file")
  install_fault_tools
  assert_fault_failed inbox-append
  assert_eq "$(state_field inbox_pending)" "open" "failed open must be durable before observation changes"
  git -C "$repo_dir" checkout -- README.md
  run_monitor
  assert_eq "$(state_field status)" "clear" "verified recovery must supersede pending escalation"
  assert_eq "$(state_field inbox_pending)" "none" "recovered pending escalation must settle"
  assert_eq "$(cat "$inbox_file")" "$before" "recovery must not append a stale open or done task"
  run_monitor
  assert_eq "$(cat "$inbox_file")" "$before" "later clear runs must not resurrect cancelled escalation"
}

test_git_monitor_pending_close_is_superseded_by_new_firing() {
  local repo_dir="$TMP/repos/refired-before-close"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  git -C "$repo_dir" checkout -- README.md
  install_fault_tools
  assert_fault_failed inbox-replace
  assert_eq "$(state_field inbox_pending)" "close" "failed close must be durable before observation changes"
  echo "dirty again" >> "$repo_dir/README.md"
  run_monitor
  assert_eq "$(state_field status)" "firing" "new firing must supersede stale completion intent"
  assert_eq "$(state_field inbox_pending)" "none" "new firing must settle its inbox intent"
  assert_eq "$(grep -c '^- \[ \].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "new firing must retain exactly one active task"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "0" \
    "stale completion intent must not mark the active incident done"
  assert_eq "$(inbox_marker_count)" "1" "new firing must adopt rather than duplicate the active task"
  git -C "$repo_dir" checkout -- README.md
  run_monitor
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "subsequent verified recovery must still complete the active task"
}

test_git_monitor_preserves_unrelated_task_without_final_newline() {
  local repo_dir="$TMP/repos/no-final-newline"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  local unrelated='- [ ] Keep my unrelated task'
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$CEO_DIR/inbox"
  printf '%s' "$unrelated" > "$inbox_file"
  run_monitor
  assert_eq "$(awk 'NR == 1 { print; exit }' "$inbox_file")" "$unrelated" \
    "new escalation must not concatenate onto unrelated final line"
  assert_eq "$(grep -c '^- \[ \].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "new escalation must occupy its own recognizable task line"
  git -C "$repo_dir" checkout -- README.md
  run_monitor
  assert_eq "$(awk 'NR == 1 { print; exit }' "$inbox_file")" "$unrelated" \
    "recovery must not overwrite the unrelated newline-less task"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "recovery must complete the monitor task on its separate line"
  assert_eq "$(awk 'END { print NR }' "$inbox_file")" "2" "append and recovery must preserve exactly two entries"
}

test_git_monitor_rejects_directory_state_without_mutation() {
  local repo_dir="$TMP/repos/directory-state"
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$state_file" "$CEO_DIR/inbox"
  echo 'Preserve state directory contents' > "$state_file/sentinel"
  echo '- [ ] Preserve existing inbox task <!-- git-monitor -->' > "$inbox_file"
  local before rc=0
  before=$(cat "$inbox_file")
  run_monitor || rc=$?
  [ "$rc" -ne 0 ] || fail_test "a directory at the state path must fail rather than masquerade as a state write"
  [ -d "$state_file" ] || fail_test "state directory must remain unchanged"
  assert_eq "$(cat "$state_file/sentinel")" 'Preserve state directory contents' "existing directory contents must be untouched"
  assert_eq "$(find "$state_file" -type f | wc -l | tr -d ' ')" "1" "state write must not move a temporary file into the directory"
  assert_eq "$(cat "$inbox_file")" "$before" "invalid state path must prevent all inbox mutation"
}

test_git_monitor_retries_after_rejected_dangling_inbox_link() {
  local repo_dir="$TMP/repos/dangling-inbox"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  mkdir -p "$CEO_DIR/inbox"
  ln -s "$TMP/nonexistent-inbox-target" "$inbox_file"
  local rc=0
  run_monitor || rc=$?
  [ "$rc" -ne 0 ] || fail_test "dangling inbox symlink must fail rather than be followed or replaced"
  [ -L "$inbox_file" ] || fail_test "failed inbox write must preserve the dangling link"
  [ ! -e "$TMP/nonexistent-inbox-target" ] || fail_test "failed inbox write must not create a symlink target"
  assert_eq "$(state_field inbox_pending)" "open" "rejected inbox path must retain durable intent"
  rm "$inbox_file"
  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "fixed inbox path must permit acknowledgment"
  assert_eq "$(inbox_marker_count)" "1" "fixed inbox path must receive exactly one retried task"
}

test_git_monitor_deleted_remote_branch_does_not_trust_cached_ref() {
  local repo_dir="$TMP/repos/deleted-upstream"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  local before remote_dir
  before=$(cat "$inbox_file")
  remote_dir=$(git -C "$repo_dir" remote get-url origin)
  git -C "$repo_dir" checkout -- README.md
  git --git-dir="$remote_dir" update-ref -d refs/heads/main
  git -C "$repo_dir" rev-parse --verify refs/remotes/origin/main >/dev/null
  run_monitor
  assert_eq "$(state_field status)" "firing" "deleted upstream branch must not trust cached local tracking ref"
  assert_eq "$(state_field observation_failed)" "1" "deleted upstream branch makes freshness unverified"
  assert_eq "$(cat "$inbox_file")" "$before" "deleted upstream branch must not complete the incident"
  assert_not_contains "$(cat "$CEO_DIR/alerts/git-monitor.md")" "clean and up to date" \
    "stale cached upstream cannot prove recovery"
  git -C "$repo_dir" push -q origin HEAD:main
  run_monitor
  assert_eq "$(state_field status)" "clear" "restored verified upstream must permit recovery"
  assert_eq "$(grep -c '^- \[done\].*<!-- git-monitor -->' "$inbox_file" || true)" "1" \
    "restored upstream must complete exactly one task"
}

test_git_monitor_local_dot_upstream_is_verified_clean() {
  local repo_dir="$TMP/repos/local-upstream"
  mkdir -p "$repo_dir"
  init_fixture_repo "$repo_dir"
  echo "base" > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "local upstream baseline"
  git -C "$repo_dir" branch local-base
  git -C "$repo_dir" config branch.main.remote .
  git -C "$repo_dir" config branch.main.merge refs/heads/local-base
  run_monitor
  assert_eq "$(state_field status)" "clear" "local dot upstream must remain a valid clean configuration"
  assert_eq "$(state_field observation_failed)" "0" "successful local comparison must be verified"
  assert_eq "$(state_field fetch_failed_count)" "0" "local upstream fetch must succeed"
  assert_eq "$(state_field behind_count)" "0" "equal local upstream must not be behind"
}

test_git_monitor_unreadable_state_preserves_checked_task() {
  local repo_dir="$TMP/repos/unreadable-state"
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  sed -i.bak 's/^- \[ \]/- [x]/' "$inbox_file"
  rm -f "$inbox_file.bak"
  cp "$state_file" "$TMP/state-before"
  local before rc=0
  before=$(cat "$inbox_file")
  chmod 000 "$state_file"
  if [ -r "$state_file" ]; then
    chmod 600 "$state_file"
    skip_test "process can read mode-000 files; deterministic state-reader fault tests cover this path"
    return 0
  fi
  run_monitor || rc=$?
  chmod 600 "$state_file"
  [ "$rc" -ne 0 ] || fail_test "unreadable existing state must abort, not be treated as first run"
  cmp -s "$state_file" "$TMP/state-before" || fail_test "unreadable state failure must preserve exact prior state bytes"
  assert_eq "$(cat "$inbox_file")" "$before" "unreadable state must not reopen the checked task"
  run_monitor
  assert_eq "$(cat "$inbox_file")" "$before" "retry after state readability returns must respect checked task"
}

exercise_state_read_failure() {
  local field="$1" error_code="$2"
  local repo_dir="$TMP/repos/read-$field-$error_code"
  local state_file="$CEO_DIR/alerts/git-monitor.md"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  export CEO_GIT_DIRS="$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  sed -i.bak 's/^- \[ \]/- [x]/' "$inbox_file"
  rm -f "$inbox_file.bak"
  # A delivered-but-unacknowledged intent must survive optional field failures.
  if [ "$field" != status ]; then
    sed -i.bak 's/^inbox_pending: none$/inbox_pending: open/' "$state_file"
    rm -f "$state_file.bak"
  fi
  cp "$state_file" "$TMP/state-before"
  local before
  before=$(cat "$inbox_file")
  install_fault_tools
  export TEST_FAULT_FIELD="$field" TEST_FAULT_EXIT="$error_code"
  assert_fault_failed state-read
  cmp -s "$state_file" "$TMP/state-before" || fail_test "$field reader rc$error_code must preserve exact state bytes"
  assert_eq "$(cat "$inbox_file")" "$before" "$field reader rc$error_code must preserve checked task"
  run_monitor
  assert_eq "$(state_field inbox_pending)" "none" "successful retry must settle preserved intent"
  assert_eq "$(cat "$inbox_file")" "$before" "successful retry must not reopen or duplicate a checked task"
}

test_git_monitor_state_reader_rc2_is_not_missing_state() {
  exercise_state_read_failure status 2
}

test_git_monitor_unexpected_state_reader_error_preserves_state() {
  exercise_state_read_failure status 73
}

test_git_monitor_optional_state_reader_errors_preserve_intent() {
  local field error_code
  for field in since inbox_pending inbox_incident; do
    for error_code in 2 73; do
      exercise_state_read_failure "$field" "$error_code"
    done
  done
}

exercise_discovery_failure() {
  local fault="$1"
  local repo_dir="$TMP/repos/discovery-failure"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  local before historical_since="2026-10-15T00:00:00-0400"
  before=$(cat "$inbox_file")
  sed -i.bak "s|^since: .*|since: $historical_since|" "$CEO_DIR/alerts/git-monitor.md"
  rm -f "$CEO_DIR/alerts/git-monitor.md.bak"
  if [ "$fault" != partial-discovery ]; then
    git -C "$repo_dir" checkout -- README.md
  fi
  install_fault_tools
  run_monitor_with_fault "$fault"
  assert_file_exists "$TMP/fault-hit" "$fault injection must actually be reached"
  assert_eq "$(state_field status)" "firing" "$fault must not synthesize recovery from an incomplete scan"
  assert_eq "$(state_field observation_failed)" "1" "$fault must be recorded as an unknown observation"
  assert_eq "$(state_field since)" "$historical_since" "$fault must preserve incident age"
  assert_eq "$(cat "$inbox_file")" "$before" "$fault must not complete existing task"
  if [ "$fault" = partial-discovery ]; then
    assert_eq "$(state_field dirty_count)" "1" "valid partial discovery results must still be inspected"
  fi
  git -C "$repo_dir" checkout -- README.md
  run_monitor
  assert_eq "$(state_field status)" "clear" "complete successful scan must permit recovery"
}

test_git_monitor_failed_discovery_does_not_clear_firing() {
  exercise_discovery_failure discovery
}

test_git_monitor_partial_discovery_failure_inspects_available_repositories() {
  exercise_discovery_failure partial-discovery
}

test_git_monitor_missing_configured_search_directory_is_unknown() {
  local repo_dir="$TMP/repos/missing-search-directory"
  local inbox_file="$CEO_DIR/inbox/git-monitor.md"
  create_tracked_fixture "$repo_dir"
  echo "dirty" >> "$repo_dir/README.md"
  run_monitor
  local before
  before=$(cat "$inbox_file")
  git -C "$repo_dir" checkout -- README.md
  export CEO_GIT_DIRS="$TMP/missing-configured-directory"
  run_monitor
  assert_eq "$(state_field status)" "firing" "missing explicitly configured directory must not imply recovery"
  assert_eq "$(state_field observation_failed)" "1" "missing configured directory must be reported as unknown"
  assert_eq "$(cat "$inbox_file")" "$before" "missing configured directory must not complete existing task"
  export CEO_GIT_DIRS="$TMP/repos"
  run_monitor
  assert_eq "$(state_field status)" "clear" "restored configured directory must permit verified recovery"
}

run_tests

