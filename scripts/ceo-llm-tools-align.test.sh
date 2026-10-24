#!/bin/bash
# Tests for ceo-llm-tools-align.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/ceo-llm-tools-align.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  OUTCOME_FILE="$TEST_HOME/outcome.txt"
  export CEO_RUNNER_OUTCOME_FILE="$OUTCOME_FILE"
  unset LLM_TOOLS_REPO CEO_LLM_TOOLS_ALIGN_REPO || true
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset TEST_HOME HOME_BACKUP OUTCOME_FILE CEO_RUNNER_OUTCOME_FILE \
        LLM_TOOLS_REPO CEO_LLM_TOOLS_ALIGN_REPO || true
}

test_missing_repo_exits_1() {
  local out rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "1" "$rc" "missing repo must exit 1"
  assert_contains "$out" "llm-tools align script not found" "error message expected"
}

test_autodiscovery_candidates() {
  local fake_repo="$HOME/Code/llm-tools"
  mkdir -p "$fake_repo/scripts"
  cat <<'EOF' > "$fake_repo/scripts/llm-tools-align.sh"
#!/bin/sh
echo "ALIGN_EXECUTED"
exit 0
EOF
  chmod +x "$fake_repo/scripts/llm-tools-align.sh"

  local out rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "0" "$rc" "discovered repo must exit 0"
  assert_contains "$out" "ALIGN_EXECUTED" "align script should have run"
  assert_file_exists "$OUTCOME_FILE" "outcome file must exist"
  assert_eq "noop" "$(cat "$OUTCOME_FILE")" "outcome must be noop"
}

test_explicit_align_repo_override() {
  local custom_repo="$TEST_HOME/custom/llm-tools"
  mkdir -p "$custom_repo/scripts"
  cat <<'EOF' > "$custom_repo/scripts/llm-tools-align.sh"
#!/bin/sh
echo "CUSTOM_ALIGN_RUN"
exit 0
EOF
  chmod +x "$custom_repo/scripts/llm-tools-align.sh"

  export CEO_LLM_TOOLS_ALIGN_REPO="$custom_repo"
  local out rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "0" "$rc" "custom repo must exit 0"
  assert_contains "$out" "CUSTOM_ALIGN_RUN" "custom align script must run"
}

test_ignores_checker_repo_and_falls_back() {
  local checker_repo="$TEST_HOME/.local/share/fleet-readiness-checker-12345"
  mkdir -p "$checker_repo/scripts"
  cat <<'EOF' > "$checker_repo/scripts/llm-tools-align.sh"
#!/bin/sh
echo "CHECKER_SHOULD_NOT_RUN"
exit 1
EOF
  chmod +x "$checker_repo/scripts/llm-tools-align.sh"

  local real_repo="$HOME/code/llm-tools"
  mkdir -p "$real_repo/scripts"
  cat <<'EOF' > "$real_repo/scripts/llm-tools-align.sh"
#!/bin/sh
echo "REAL_REPO_RUN"
exit 0
EOF
  chmod +x "$real_repo/scripts/llm-tools-align.sh"

  export LLM_TOOLS_REPO="$checker_repo"
  local out rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "0" "$rc" "must ignore checker repo and succeed on real repo"
  assert_contains "$out" "REAL_REPO_RUN" "real repo must be chosen"
}

test_propagates_nonzero_exit() {
  local fail_repo="$HOME/Code/llm-tools"
  mkdir -p "$fail_repo/scripts"
  cat <<'EOF' > "$fail_repo/scripts/llm-tools-align.sh"
#!/bin/sh
echo "FAILING_SCRIPT"
exit 42
EOF
  chmod +x "$fail_repo/scripts/llm-tools-align.sh"

  local out rc=0
  out=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "42" "$rc" "must propagate child exit code"
  [ ! -f "$OUTCOME_FILE" ] || { echo "failed run must not write outcome noop" >&2; return 1; }
}

run_tests
