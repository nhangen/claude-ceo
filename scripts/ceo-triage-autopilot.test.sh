#!/bin/bash
# Self-contained test harness for ceo-triage-autopilot.sh — verifies the
# state machine, idempotency, retry-cap invariants, error handling, and
# multi-repo aggregation. Stubs assert argv shape so a future revert that
# changes the production invocation fails the tests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOPILOT="$SCRIPT_DIR/ceo-triage-autopilot.sh"

source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

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

  # Real git repos so `git -C <path> config --get remote.origin.url` returns
  # a slug the production code can parse.
  for slug in test/sample test/sibling; do
    name=$(basename "$slug")
    git init -q "$TEST_HOME/repos/$name"
    git -C "$TEST_HOME/repos/$name" remote add origin "git@github.com:${slug}.git"
  done

  cat > "$TEST_HOME/repo-list.md" << EOF
# Discovered Repositories

| Repo | Local Path |
|------|------------|
| \`sample\` | \`$TEST_HOME/repos/sample\` |
EOF
  export CEO_TRIAGE_REPO_LIST="$TEST_HOME/repo-list.md"

  mkdir -p "$TEST_HOME/stubs"

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

  # gh stubs: validate argv shape, then emit canned JSON.
  # Production must invoke: gh pr list --repo OWNER/REPO --search ... --json ... --limit N
  cat > "$TEST_HOME/stubs/fake-gh-empty" << 'EOF'
#!/bin/bash
case "$*" in
  *"pr list"*"--repo "*"--search "*"--json "*) echo "[]" ;;
  *) echo "fake-gh-empty: unexpected argv: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-empty"

  # Branches on --repo so multi-repo tests can seed distinct merges per slug.
  cat > "$TEST_HOME/stubs/fake-gh-multi" << 'EOF'
#!/bin/bash
case "$*" in
  *"pr list"*"--repo test/sample"*)
    cat <<JSON
[{"number":42,"title":"Sample merge","mergedAt":"2026-06-01T00:00:00Z","url":"https://github.com/test/sample/pull/42"}]
JSON
    ;;
  *"pr list"*"--repo test/sibling"*)
    cat <<JSON
[{"number":7,"title":"Sibling merge","mergedAt":"2026-06-01T00:05:00Z","url":"https://github.com/test/sibling/pull/7"}]
JSON
    ;;
  *"pr list"*"--repo "*"--search "*"--json "*) echo "[]" ;;
  *) echo "fake-gh-multi: unexpected argv: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-multi"

  # gh fails on every repo (auth expiry, rate limit, etc.).
  cat > "$TEST_HOME/stubs/fake-gh-fail" << 'EOF'
#!/bin/bash
case "$*" in
  *"pr list"*"--repo "*"--search "*"--json "*)
    echo "HTTP 401: bad credentials" >&2; exit 1 ;;
  *) echo "fake-gh-fail: unexpected argv: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-fail"

  # claude stubs (also argv-validating).
  cat > "$TEST_HOME/stubs/fake-claude-ok" << 'EOF'
#!/bin/bash
case "$*" in
  "--print "*) ;;
  *) echo "fake-claude-ok: unexpected argv: $*" >&2; exit 99 ;;
esac
cat <<OUT
Some preamble text.

\`\`\`json
{"tickets":[{"id":"OM-1","title":"First","url":"https://zenhub/1","score":0.9,"reason":"adjacent"},{"id":"OM-2","title":"Second","url":"https://zenhub/2","score":0.8,"reason":"sibling"},{"id":"OM-3","title":"Third","url":"https://zenhub/3","score":0.7,"reason":"recent"}]}
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

  cat > "$TEST_HOME/stubs/fake-claude-exit1" << 'EOF'
#!/bin/bash
echo "claude: auth required" >&2
exit 1
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-exit1"

  cat > "$TEST_HOME/stubs/fake-claude-toomany" << 'EOF'
#!/bin/bash
cat <<OUT
\`\`\`json
{"tickets":[{"id":"A","title":"a","url":"u","score":0.9,"reason":"r"},{"id":"B","title":"b","url":"u","score":0.8,"reason":"r"},{"id":"C","title":"c","url":"u","score":0.7,"reason":"r"},{"id":"D","title":"d","url":"u","score":0.6,"reason":"r"}]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-toomany"

  cat > "$TEST_HOME/stubs/fake-claude-malformed" << 'EOF'
#!/bin/bash
cat <<OUT
\`\`\`json
{"tickets":"not-an-array"}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-malformed"

  # gh stub that returns one deterministic merge for ANY --repo slug, so
  # routing tests can seed merges for arbitrary owners.
  cat > "$TEST_HOME/stubs/fake-gh-any" << 'EOF'
#!/bin/bash
slug=""; prev=""
for a in "$@"; do [ "$prev" = "--repo" ] && slug="$a"; prev="$a"; done
case "$*" in
  *"pr list"*"--repo "*"--search "*"--json "*)
    n=$(printf '%s' "$slug" | cksum | cut -d' ' -f1); n=$((n % 900 + 100))
    printf '[{"number":%s,"title":"Merge in %s","mergedAt":"2026-06-01T00:00:00Z","url":"https://github.com/%s/pull/%s"}]\n' "$n" "$slug" "$slug" "$n" ;;
  *) echo "fake-gh-any: unexpected argv: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$TEST_HOME/stubs/fake-gh-any"

  # claude stub that records the prompt it was handed, then emits valid JSON.
  cat > "$TEST_HOME/stubs/fake-claude-record" << 'EOF'
#!/bin/bash
case "$1" in --print) ;; *) echo "fake-claude-record: bad argv: $*" >&2; exit 99 ;; esac
printf '%s\n----\n' "$2" >> "${CLAUDE_PROMPT_LOG:-/dev/null}"
cat <<OUT
\`\`\`json
{"tickets":[{"id":"OM-1","title":"First","url":"https://zenhub/1","score":0.9,"reason":"adjacent"}]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-record"

  # claude stub: records prompt; succeeds for ZenHub prompts, FAILS for the
  # GitHub-issues prompt (exercises per-source partial failure).
  cat > "$TEST_HOME/stubs/fake-claude-failgithub" << 'EOF'
#!/bin/bash
case "$1" in --print) ;; *) echo "fake-claude-failgithub: bad argv: $*" >&2; exit 99 ;; esac
printf '%s\n----\n' "$2" >> "${CLAUDE_PROMPT_LOG:-/dev/null}"
if printf '%s' "$2" | grep -q "GitHub-issues source"; then
  echo "fake-claude-failgithub: simulated github triage failure" >&2; exit 1
fi
cat <<OUT
\`\`\`json
{"tickets":[{"id":"OM-1","title":"First","url":"https://zenhub/1","score":0.9,"reason":"adjacent"}]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-failgithub"

  # claude stub: tickets array passes the type/length validation but an element
  # has a non-scalar field, so the @tsv extraction errors mid-stream.
  cat > "$TEST_HOME/stubs/fake-claude-badrow" << 'EOF'
#!/bin/bash
case "$1" in --print) ;; *) echo "fake-claude-badrow: bad argv: $*" >&2; exit 99 ;; esac
cat <<OUT
\`\`\`json
{"tickets":[{"id":"OM-9","title":"bad","url":{"nested":"object"},"score":0.5,"reason":"r"}]}
\`\`\`
OUT
EOF
  chmod +x "$TEST_HOME/stubs/fake-claude-badrow"

  export CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-empty"
  export CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-ok"
  # Route the test owner (`test/*`) to ZenHub so existing tests are unaffected;
  # `nhangen/*` to GitHub. Other owners fall through to skip.
  export CEO_TRIAGE_ZENHUB_OWNERS="awesomemotive nhangenam test"
  export CEO_TRIAGE_GITHUB_OWNERS="nhangen"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP \
        CEO_GH_BIN CEO_TRIAGE_CLAUDE_BIN CEO_TRIAGE_REPO_LIST \
        CEO_TRIAGE_ZENHUB_OWNERS CEO_TRIAGE_GITHUB_OWNERS CLAUDE_PROMPT_LOG
}

# Reset the repo list to exactly the given slugs (git-inits each repo).
reset_repo_list_with() {
  cat > "$TEST_HOME/repo-list.md" << 'EOF'
| Repo | Local Path |
|------|------------|
EOF
  local slug name dir
  for slug in "$@"; do
    name=$(basename "$slug")
    dir="$TEST_HOME/repos/$name"
    git init -q "$dir"
    git -C "$dir" remote remove origin 2>/dev/null || true
    git -C "$dir" remote add origin "git@github.com:${slug}.git"
    printf '| `%s` | `%s` |\n' "$name" "$dir" >> "$TEST_HOME/repo-list.md"
  done
}

run_autopilot() {
  bash "$AUTOPILOT" >/dev/null 2>&1
}

state_field() {
  ceo_read_alert_field "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md" "$1" \
    | tr -d '[:space:]'
}

seed_two_repo_list() {
  cat > "$TEST_HOME/repo-list.md" << EOF
| Repo | Local Path |
|------|------------|
| \`sample\` | \`$TEST_HOME/repos/sample\` |
| \`sibling\` | \`$TEST_HOME/repos/sibling\` |
EOF
}

# ---------- tests ----------

test_first_run_creates_baseline_no_triage() {
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
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
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-empty" run_autopilot
  assert_eq "$(state_field status)" "clear" "no merges should stay clear"
  assert_eq "$(state_field triage_ran)" "0" "no merges should not spawn triage"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_new_merge_triggers_triage_and_writes_top3() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  assert_eq "$(state_field status)" "firing" "new merges should fire"
  assert_eq "$(state_field triage_ran)" "1" "new merges should spawn triage"
  assert_eq "$(state_field tickets_written)" "3" "top-3 should be written"
  local count
  count=$(grep -c '<!-- triage-autopilot:' "$CEO_DIR/inbox.md")
  assert_eq "$count" "3" "inbox should contain 3 marker lines"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_multi_repo_aggregation() {
  # Two repos in the list. fake-gh-multi emits one row per repo.
  seed_two_repo_list
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  assert_eq "$(state_field new_merges)" "2" "two repos should aggregate to 2 merges"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_repeated_run_with_same_tickets_does_not_duplicate() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  local count
  count=$(grep -c '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "OM-1 marker must appear only once across two firing runs"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_no_json_does_not_advance_cursor() {
  run_autopilot
  local cursor_before
  cursor_before=$(state_field last_merge_check)
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-bad" run_autopilot
  local cursor_after
  cursor_after=$(state_field last_merge_check)
  assert_eq "$cursor_after" "$cursor_before" "failed triage must NOT advance cursor"
  assert_eq "$(state_field consec_failures)" "1" "consec_failures must increment"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_exit_nonzero_counts_as_failure() {
  run_autopilot
  local cursor_before
  cursor_before=$(state_field last_merge_check)
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-exit1" run_autopilot
  assert_eq "$(state_field last_merge_check)" "$cursor_before" "claude exit-non-zero must not advance cursor"
  assert_eq "$(state_field consec_failures)" "1" "claude exit-non-zero counts as failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_too_many_tickets_is_rejected_as_failure() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-toomany" run_autopilot
  assert_eq "$(state_field consec_failures)" "1" ">3 tickets must be rejected"
  if [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] >3 tickets must not write inbox\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_malformed_tickets_is_rejected() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-malformed" run_autopilot
  assert_eq "$(state_field consec_failures)" "1" "non-array tickets must be rejected"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_retry_cap_advances_cursor_and_writes_giveup_inbox() {
  run_autopilot
  sed -i.bak 's/^last_merge_check: .*/last_merge_check: 2026-01-01T00:00:00+0000/' \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md.bak"
  local stderr_capture
  for _ in 1 2 3; do
    stderr_capture=$(CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
      CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-bad" \
      bash "$AUTOPILOT" 2>&1 >/dev/null) || true
  done
  if [ "$(state_field last_merge_check)" = "2026-01-01T00:00:00+0000" ]; then
    printf '  FAIL [%s] cursor should advance after 3 failed retries\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  assert_eq "$(state_field consec_failures)" "0" "consec_failures must reset after give-up"
  assert_contains "$stderr_capture" "advancing cursor anyway" "give-up must log to stderr"
  if ! grep -q "triage-autopilot:giveup:" "$CEO_DIR/inbox.md"; then
    printf '  FAIL [%s] give-up must append a marker line to inbox.md\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_giveup_inbox_line_is_idempotent() {
  run_autopilot
  for _ in 1 2 3 4 5 6; do
    CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
      CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-bad" run_autopilot
  done
  local count
  count=$(grep -c "triage-autopilot:giveup:" "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "give-up marker must appear only once per day"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_empty_tickets_array_is_success_not_failure() {
  run_autopilot
  # Backdate the baseline cursor so a real advancement is visible despite
  # 1-second timestamp resolution.
  sed -i.bak 's/^last_merge_check: .*/last_merge_check: 2026-01-01T00:00:00+0000/' \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-empty" run_autopilot
  assert_eq "$(state_field tickets_written)" "0" "empty tickets array writes nothing"
  assert_eq "$(state_field consec_failures)" "0" "empty array is success"
  if [ "$(state_field last_merge_check)" = "2026-01-01T00:00:00+0000" ]; then
    printf '  FAIL [%s] empty array is success and must advance cursor\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_user_checked_off_marker_is_still_dedup() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  sed -i.bak 's/^- \[ \] Triage: \*\*OM-1\*\*/- [x] Triage: **OM-1**/' "$CEO_DIR/inbox.md"
  rm -f "$CEO_DIR/inbox.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  local count
  count=$(grep -c '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "checked-off marker still dedups"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_user_reformat_line_still_dedup() {
  run_autopilot
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  # User completely rewrites the line but keeps the marker.
  sed -i.bak 's|^- \[ \] Triage: \*\*OM-1\*\*.*|- some translated wording [ref](x) <!-- triage-autopilot:OM-1 -->|' "$CEO_DIR/inbox.md"
  rm -f "$CEO_DIR/inbox.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-multi" run_autopilot
  local count
  count=$(grep -c '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md")
  assert_eq "$count" "1" "reformatted line with marker must not be duplicated"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_gh_failure_holds_cursor_and_records_last_error() {
  run_autopilot
  local cursor_before
  cursor_before=$(state_field last_merge_check)
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-fail" run_autopilot
  assert_eq "$(state_field last_merge_check)" "$cursor_before" \
    "gh failure on every repo must NOT advance cursor"
  local last_err
  last_err=$(state_field last_error)
  if [[ "$last_err" != gh_failed:* ]]; then
    printf '  FAIL [%s] last_error should record gh_failed; got %q\n' "$CURRENT_TEST" "$last_err"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_repo_list_does_not_crash() {
  rm -f "$TEST_HOME/repo-list.md"
  run_autopilot
  assert_file_exists "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md" "state file written"
  assert_eq "$(state_field status)" "clear" "no repos -> clear"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_corrupted_consec_failures_emits_warning() {
  run_autopilot
  mkdir -p "$CEO_DIR/alerts"
  # Read the current state, then mutate consec_failures to garbage.
  local state_file="$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  sed -i.bak 's/^consec_failures: .*/consec_failures: notanumber/' "$state_file"
  rm -f "$state_file.bak"
  local stderr_out
  stderr_out=$(bash "$AUTOPILOT" 2>&1 >/dev/null) || true
  assert_contains "$stderr_out" "corrupted consec_failures field" "garbage field must warn"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_log_line_records_status_tokens() {
  run_autopilot
  local log_file
  log_file="$CEO_DIR/log/triage-autopilot/$(date +%Y-%m).md"
  local body
  body=$(cat "$log_file")
  assert_contains "$body" "status=" "log line must record status"
  assert_contains "$body" "new_merges=" "log line must record new_merges count"
  assert_contains "$body" "triage_ran=" "log line must record triage_ran"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_personal_owner_routes_to_github_source() {
  reset_repo_list_with "nhangen/personal-x"
  export CLAUDE_PROMPT_LOG="$TEST_HOME/prompts.log"; : > "$CLAUDE_PROMPT_LOG"
  run_autopilot   # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-record" run_autopilot
  assert_eq "$(state_field triage_ran)" "1" "personal merge should spawn triage"
  local prompts; prompts=$(cat "$CLAUDE_PROMPT_LOG")
  assert_contains "$prompts" "nhangen/personal-x" "github prompt must name the repo slug"
  assert_contains "$prompts" "GitHub-issues source" "github prompt must declare the github source"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_am_owner_routes_to_zenhub_pipeline() {
  reset_repo_list_with "awesomemotive/optin-monster-app"
  export CLAUDE_PROMPT_LOG="$TEST_HOME/prompts.log"; : > "$CLAUDE_PROMPT_LOG"
  run_autopilot   # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-record" run_autopilot
  assert_eq "$(state_field triage_ran)" "1" "AM merge should spawn triage"
  local prompts; prompts=$(cat "$CLAUDE_PROMPT_LOG")
  assert_contains "$prompts" "pipeline" "zenhub prompt must target a pipeline"
  if printf '%s' "$prompts" | grep -q "GitHub-issues source"; then
    printf '  FAIL [%s] AM repo must NOT use the github source\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_unknown_owner_is_skipped_but_advances_cursor() {
  reset_repo_list_with "altamira2/some-thing"
  export CLAUDE_PROMPT_LOG="$TEST_HOME/prompts.log"; : > "$CLAUDE_PROMPT_LOG"
  run_autopilot   # baseline
  sed -i.bak 's/^last_merge_check: .*/last_merge_check: 2026-01-01T00:00:00+0000/' \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-record" run_autopilot
  assert_eq "$(state_field triage_ran)" "0" "unknown-owner merge must NOT spawn triage"
  assert_eq "$(state_field status)" "clear" "skip-only tick is clear"
  if [ -s "$CLAUDE_PROMPT_LOG" ]; then
    printf '  FAIL [%s] skipped owner must not invoke claude\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  if [ "$(state_field last_merge_check)" = "2026-01-01T00:00:00+0000" ]; then
    printf '  FAIL [%s] skip-only merges must still advance the cursor\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_partial_source_failure_holds_cursor() {
  reset_repo_list_with "test/sample" "nhangen/personal-x"
  export CLAUDE_PROMPT_LOG="$TEST_HOME/prompts.log"; : > "$CLAUDE_PROMPT_LOG"
  run_autopilot   # baseline
  sed -i.bak 's/^last_merge_check: .*/last_merge_check: 2026-01-01T00:00:00+0000/' \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-failgithub" run_autopilot
  assert_eq "$(state_field last_merge_check)" "2026-01-01T00:00:00+0000" \
    "a failed github spawn must hold the cursor (don't drop the merge window)"
  assert_eq "$(state_field consec_failures)" "1" "partial failure counts as one failure"
  # Prove it's genuinely PARTIAL, not total: the surviving ZenHub source must
  # have written its ticket even though the GitHub source failed. Without this,
  # the test passes identically when both sources fail.
  assert_eq "$(state_field tickets_written)" "1" "surviving zenhub source still wrote its ticket"
  if ! grep -qF -- '<!-- triage-autopilot:OM-1 -->' "$CEO_DIR/inbox.md"; then
    printf '  FAIL [%s] zenhub ticket OM-1 must be in inbox despite github failure\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  # The held-cursor tick must record WHICH failure occurred, not last_error: none.
  if [ "$(state_field last_error)" = "none" ]; then
    printf '  FAIL [%s] spawn failure must set last_error, got none\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_spawn_cardinality_one_zenhub_spawn_per_tick() {
  # Two AM repos in one tick -> exactly ONE ZenHub spawn (unified board), and
  # two personal repos -> one GitHub spawn each. Prompts are '----'-separated
  # in the recording stub's log.
  reset_repo_list_with "awesomemotive/a" "nhangenam/b" "nhangen/p1" "nhangen/p2"
  export CLAUDE_PROMPT_LOG="$TEST_HOME/prompts.log"; : > "$CLAUDE_PROMPT_LOG"
  run_autopilot   # baseline
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-record" run_autopilot
  local zenhub_spawns github_spawns
  zenhub_spawns=$(grep -c '"inbox" pipeline' "$CLAUDE_PROMPT_LOG")
  github_spawns=$(grep -c 'GitHub-issues source' "$CLAUDE_PROMPT_LOG")
  assert_eq "$zenhub_spawns" "1" "two AM repos collapse to one ZenHub spawn"
  assert_eq "$github_spawns" "2" "two personal repos get one GitHub spawn each"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_validated_tickets_with_bad_row_is_failure_not_silent_advance() {
  # tickets array passes type/length validation but a row breaks @tsv. This must
  # be a recorded failure (cursor held), NOT a silent zero-row "success" that
  # advances the cursor and drops the merge window.
  reset_repo_list_with "test/sample"
  run_autopilot   # baseline
  sed -i.bak 's/^last_merge_check: .*/last_merge_check: 2026-01-01T00:00:00+0000/' \
    "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md"
  rm -f "$CEO_DIR/alerts/triage-autopilot-$CEO_HOSTNAME.md.bak"
  CEO_GH_BIN="$TEST_HOME/stubs/fake-gh-any" \
    CEO_TRIAGE_CLAUDE_BIN="$TEST_HOME/stubs/fake-claude-badrow" run_autopilot
  assert_eq "$(state_field last_merge_check)" "2026-01-01T00:00:00+0000" \
    "bad ticket row must hold the cursor, not silently advance"
  assert_eq "$(state_field consec_failures)" "1" "bad ticket row counts as a failure"
  assert_eq "$(state_field tickets_written)" "0" "no tickets written from a broken row"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
