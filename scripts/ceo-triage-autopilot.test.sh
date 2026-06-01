#!/bin/bash
# Self-contained test harness for ceo-triage-autopilot.sh — verifies the
# state machine, idempotency, and retry-cap invariants.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOPILOT="$SCRIPT_DIR/ceo-triage-autopilot.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR"
  touch "$CEO_DIR/inbox.md"

  # Build a fake repo list pointing at a local dummy repo path.
  mkdir -p "$TEST_HOME/repos/sample"
  mkdir -p "$TEST_HOME/repos/sample/.git"
  cat > "$TEST_HOME/repo-list.md" << EOF
# Discovered Repositories

| Repo | Local Path |
|------|------------|
| \`sample\` | \`$TEST_HOME/repos/sample\` |
EOF
  export CEO_TRIAGE_REPO_LIST="$TEST_HOME/repo-list.md"

  # Stubs directory.
  mkdir -p "$TEST_HOME/stubs"

  # getent stub so ceo_load_config's HOME-resolution path works regardless of
  # whether Homebrew's gnu-getent is on PATH.
  local user
  user=$(id -un)
  cat > "$TEST_HOME/stubs/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$TEST_HOME"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_HOME/stubs/getent"
  export PATH="$TEST_HOME/stubs:$PATH"

  # Default gh stub: emits nothing (no merges).
  cat > "$TEST_HOME/stubs/fake-gh-empty" << 'EOF'
#!/bin/bash
echo "[]"
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-empty"

  # Default gh stub: emits one merge row.
  cat > "$TEST_HOME/stubs/fake-gh-one" << 'EOF'
#!/bin/bash
# args: -C <path> pr list --search ... --json ... --limit 20
cat <<JSON
[{"number":42,"title":"Sample merge","mergedAt":"2026-06-01T00:00:00Z","url":"https://github.com/x/sample/pull/42"}]
JSON
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-one"

  # Claude stub: emits a valid JSON block by default.
  cat > "$TEST_HOME/stubs/fake-claude-ok" << 'EOF'
#!/bin/bash
cat <<OUT
Some preamble text.

\`\`\`json
{"tickets":[{"id":"OM-1","title":"First ticket","url":"https://zenhub/1","score":0.9,"reason":"adjacent to sample"},{"id":"OM-2","title":"Second ticket","url":"https://zenhub/2","score":0.8,"reason":"sibling area"},{"id":"OM-3","title":"Third ticket","url":"https://zenhub/3","score":0.7,"reason":"recent activity"}]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-ok"

  cat > "$TEST_HOME/stubs/fake-claude-empty" << 'EOF'
#!/bin/bash
cat <<OUT
\`\`\`json
{"tickets":[]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-empty"

  cat > "$TEST_HOME/stubs/fake-claude-bad" << 'EOF'
#!/bin/bash
echo "no json here, sorry"
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-bad"

  export CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-empty"
  export CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-ok"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP \
        CEO_GH_BIN CEO_TRIAGE_CLAUDE_BIN CEO_TRIAGE_REPO_LIST
}

run_autopilot() {
  bash "$AUTOPILOT" >/dev/null 2>&1
}

state_field() {
  awk "/^$1:/ { sub(/^$1:[[:space:]]*/, \"\"); print; exit }" \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md" | tr -d '[:space:]'
}

# ---------- tests ----------

test_first_run_creates_baseline_no_triage() {
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  assert_file_exists "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md" "state file should exist"
  assert_eq "$(state_field status)" "clear" "first run must be clear regardless of merges"
  assert_eq "$(state_field triage_ran)" "0" "first run must NOT spawn triage"
  if [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] first run must not write inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_second_tick_no_merges_stays_clear() {
  run_autopilot                                    # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-empty" run_autopilot
  assert_eq "$(state_field status)" "clear" "no merges should stay clear"
  assert_eq "$(state_field triage_ran)" "0" "no merges should not spawn triage"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_new_merge_triggers_triage_and_writes_top3() {
  run_autopilot                                    # baseline (clear)
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  assert_eq "$(state_field status)" "firing" "new merges should fire"
  assert_eq "$(state_field triage_ran)" "1" "new merges should spawn triage"
  assert_eq "$(state_field tickets_written)" "3" "top-3 should be written"
  local count
  count=$(grep -c '<!-- triage-autopilot:' "$CEO_DIR/inbox.md")
  assert_eq "$count" "3" "inbox should contain 3 marker lines"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_repeated_run_with_same_tickets_does_not_duplicate() {
  run_autopilot                                    # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  local count
  count=$(grep -c '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "OM-1 marker must appear only once across two firing runs"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_failure_does_not_advance_cursor() {
  run_autopilot                                    # baseline
  local cursor_before
  cursor_before=$(state_field last_merge_check)
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-bad" run_autopilot
  local cursor_after
  cursor_after=$(state_field last_merge_check)
  assert_eq "$cursor_after" "$cursor_before" "failed triage must NOT advance the merge-check cursor"
  assert_eq "$(state_field consec_failures)" "1" "consec_failures must increment"
  if [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] failed triage must not write inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_retry_cap_advances_cursor_after_3_failures() {
  run_autopilot                                    # baseline
  local cursor_before
  cursor_before=$(state_field last_merge_check)
  for _ in 1 2 3; do
    CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" \
      CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-bad" run_autopilot
  done
  local cursor_after
  cursor_after=$(state_field last_merge_check)
  if [ "$cursor_after" = "$cursor_before" ]; then
    printf '  FAIL [%s] cursor should advance after %d failed retries\n' "$CURRENT_TEST" 3
    FAILS=$((FAILS + 1))
  fi
  assert_eq "$(state_field consec_failures)" "0" "consec_failures must reset after give-up"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_empty_tickets_array_is_valid_and_writes_nothing() {
  run_autopilot                                    # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-empty" run_autopilot
  assert_eq "$(state_field tickets_written)" "0" "empty tickets array writes nothing"
  assert_eq "$(state_field consec_failures)" "0" "empty array is success, not failure"
  if [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] empty tickets must leave inbox empty\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_user_checked_off_marker_is_still_dedup() {
  run_autopilot                                    # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  # User checks off OM-1.
  sed -i.bak 's/^- \[ \] Triage: \*\*OM-1\*\*/- [x] Triage: **OM-1**/' "$CEO_DIR/inbox.md"
  rm -f "$CEO_DIR/inbox.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-one" run_autopilot
  local count
  count=$(grep -c '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "checked-off marker still counts for dedup"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_repo_list_does_not_crash() {
  rm -f "$TEST_HOME/repo-list.md"
  run_autopilot
  assert_file_exists "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md" "state file written even with no repo list"
  assert_eq "$(state_field status)" "clear" "no repos -> no merges -> clear"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_log_line_appended_each_run() {
  run_autopilot
  run_autopilot
  local log_file
  log_file="$CEO_DIR/log/triage-autopilot/$(date +%Y-%m).md"
  local count
  count=$(wc -l < "$log_file" | tr -d '[:space:]')
  assert_eq "$count" "2" "each run appends one log line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
