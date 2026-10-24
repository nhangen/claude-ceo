#!/bin/bash
# Tests for ceo-fleet-readiness.sh checker-repo selection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/ceo-fleet-readiness.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_HOSTNAME="test-host"
  mkdir -p "$CEO_VAULT" "$TEST_HOME/.bun/bin"
  unset CEO_FLEET_READINESS_REPO LLM_TOOLS_REPO CEO_RUNNER_OUTCOME_FILE || true
  # ceo_augment_path puts $HOME/.bun/bin first, so the stub lives there.
  # Records the --checker argument of the report step; every other python3 call succeeds.
  cat > "$TEST_HOME/.bun/bin/python3" <<'STUB'
#!/bin/sh
case "$*" in
  *ceo-fleet-readiness-report.py*) printf '%s\n' "$*" >> "$STUB_LOG" ;;
esac
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/python3"
  export STUB_LOG="$TEST_HOME/python.log"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset TEST_HOME HOME_BACKUP STUB_LOG CEO_VAULT CEO_HOSTNAME \
        CEO_FLEET_READINESS_REPO LLM_TOOLS_REPO || true
}

_stub_checker() {
  mkdir -p "$1/scripts" "$1/home/.claude"
  : > "$1/scripts/fleet-readiness.py"
}

_run() {
  bash "$SCRIPT" 2>&1
}

test_fleet_repo_variable_is_used() {
  _stub_checker "$TEST_HOME/fleet"
  export CEO_FLEET_READINESS_REPO="$TEST_HOME/fleet"
  local out rc=0
  out=$(_run) || rc=$?
  assert_eq "0" "$rc" "fleet repo must exit 0"
  assert_contains "$(cat "$STUB_LOG")" "--checker $TEST_HOME/fleet/scripts/fleet-readiness.py" "fleet repo must be the checker"
}

test_fleet_repo_beats_llm_tools_repo() {
  _stub_checker "$TEST_HOME/fleet"
  _stub_checker "$TEST_HOME/legacy"
  export CEO_FLEET_READINESS_REPO="$TEST_HOME/fleet" LLM_TOOLS_REPO="$TEST_HOME/legacy"
  local out rc=0
  out=$(_run) || rc=$?
  assert_eq "0" "$rc" "must exit 0"
  assert_contains "$(cat "$STUB_LOG")" "$TEST_HOME/fleet/scripts" "fleet variable must win"
  assert_not_contains "$(cat "$STUB_LOG")" "$TEST_HOME/legacy" "legacy variable must lose"
}

test_llm_tools_repo_still_works_as_fallback() {
  _stub_checker "$TEST_HOME/legacy"
  export LLM_TOOLS_REPO="$TEST_HOME/legacy"
  local out rc=0
  out=$(_run) || rc=$?
  assert_eq "0" "$rc" "legacy fallback must exit 0"
  assert_contains "$(cat "$STUB_LOG")" "$TEST_HOME/legacy/scripts/fleet-readiness.py" "legacy repo must be the checker"
}

test_unavailable_checker_names_both_variables() {
  local out rc=0
  out=$(_run) || rc=$?
  assert_eq "1" "$rc" "missing checker must exit 1"
  assert_contains "$out" "CEO_FLEET_READINESS_REPO" "error must name the preferred variable"
  assert_contains "$out" "LLM_TOOLS_REPO" "error must name the fallback variable"
}

run_tests
