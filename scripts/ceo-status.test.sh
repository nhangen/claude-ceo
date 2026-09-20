#!/bin/bash
# Contract harness for `ceo status` and `ceo playbook next-runs` (#237).
#
# The shell layer is tested against a stubbed `bun`, not a real one: the
# repo-wide `scripts/*.test.sh` runners install neither bun nor the scheduler's
# cronbird dependency, so a suite that shells out to the real thing passes only
# where it was written and reports the error path everywhere else. What lives
# here is what the shell owns — the guards, the registry gate, the argv it
# hands over, and exit-code passthrough. The projection itself is covered by
# lib/scheduler/tests/status.test.ts under the scheduler job.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$HOME/.ceo"

  # A fake install root so INSTALL_DIR resolves here rather than to the real
  # checkout, whose lib/scheduler/node_modules may or may not exist.
  ROOT="$TEST_HOME/root"
  mkdir -p "$ROOT/.claude-plugin" "$ROOT/lib/scheduler/node_modules"
  # Copied, not symlinked: `ceo` resolves SCRIPT_DIR through `readlink -f`, so a
  # symlinked scripts dir would put INSTALL_DIR back on the real checkout.
  cp -R "$SCRIPT_DIR" "$ROOT/scripts"
  CEO_CLI="$ROOT/scripts/ceo"

  STUB_BIN="$TEST_HOME/stub-bin"
  ARGV_LOG="$TEST_HOME/bun-argv.log"
  mkdir -p "$STUB_BIN"
  _write_bun_stub 0

  cat > "$HOME/.ceo/registry.json" << 'JSON'
{
  "schema_version": 3,
  "generated": "2026-06-07T00:00:00Z",
  "playbooks": [
    {
      "name": "pr-review",
      "description": "review PRs",
      "schedule": "*/30 * * * *",
      "status": "active",
      "trigger": "cron",
      "scope": "each"
    }
  ]
}
JSON
  echo '["pr-review"]' > "$HOME/.ceo/enabled.json"
  echo '{"hosts":["testhost"],"owners":{}}' > "$CEO_DIR/swarm.json"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
  unset ROOT CEO_CLI STUB_BIN ARGV_LOG
}

# Records argv and cwd, then exits with the code the caller asked for.
_write_bun_stub() {
  local rc="$1"
  cat > "$STUB_BIN/bun" <<STUB
#!/bin/bash
{ echo "argv: \$*"; echo "cwd: \$(pwd)"; } >> "$ARGV_LOG"
exit $rc
STUB
  chmod +x "$STUB_BIN/bun"
}

_run() {
  PATH="$STUB_BIN:$PATH" bash "$CEO_CLI" "$@" 2>&1
}

# "bun is missing" is a claim about PATH, so assert the precondition rather than
# assuming it: a host with bun in /usr/bin would otherwise read as a pass.
_run_without_bun() {
  local p="/usr/bin:/bin"
  if PATH="$p" command -v bun >/dev/null 2>&1; then
    echo "PRECONDITION FAILED: bun is on $p; this arm cannot prove the guard"
    return 125
  fi
  PATH="$p" bash "$CEO_CLI" "$@" 2>&1
}

test_status_hands_the_subcommand_and_flags_to_the_scheduler_cli() {
  local out rc=0
  out=$(_run status --json) || rc=$?
  assert_eq "$rc" "0" "ceo status must exit 0 when the scheduler CLI succeeds"
  assert_contains "$(cat "$ARGV_LOG")" "argv: run src/status.ts status --json" \
    "status must invoke src/status.ts with the status subcommand and pass flags through"
  assert_contains "$(cat "$ARGV_LOG")" "cwd: $(cd "$ROOT/lib/scheduler" && pwd -P)" \
    "the scheduler CLI must run from lib/scheduler"
  assert_not_contains "$out" "ERROR" "no guard should fire on a complete install"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_next_runs_hands_the_subcommand_and_window_to_the_scheduler_cli() {
  local rc=0
  _run playbook next-runs --within 31m >/dev/null || rc=$?
  assert_eq "$rc" "0" "ceo playbook next-runs must exit 0 when the scheduler CLI succeeds"
  assert_contains "$(cat "$ARGV_LOG")" "argv: run src/status.ts next-runs --within 31m" \
    "next-runs must pass its subcommand and --within through unchanged"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_stale_daemon_exit_code_reaches_the_caller() {
  _write_bun_stub 69
  local rc=0
  _run status >/dev/null || rc=$?
  assert_eq "$rc" "69" "STALE_EXIT_CODE must propagate through the subshell"
  rc=0
  _run playbook next-runs >/dev/null || rc=$?
  assert_eq "$rc" "69" "next-runs must propagate STALE_EXIT_CODE too"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_usage_error_exit_code_reaches_the_caller() {
  _write_bun_stub 2
  local rc=0
  _run status --nope >/dev/null || rc=$?
  assert_eq "$rc" "2" "rc=2 from the scheduler CLI must not be flattened to 1"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_bun_is_named_for_both_commands() {
  local out rc=0
  out=$(_run_without_bun status) || rc=$?
  assert_eq "$rc" "1" "status must exit 1 when bun is missing"
  assert_contains "$out" "bun is required for status" "must name the missing dependency"
  rc=0
  out=$(_run_without_bun playbook next-runs) || rc=$?
  assert_eq "$rc" "1" "next-runs must exit 1 when bun is missing"
  assert_contains "$out" "bun is required for playbook next-runs" "must name the command in the error"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_scheduler_lib_is_named() {
  rm -rf "$ROOT/lib/scheduler"
  local out rc=0
  out=$(_run status) || rc=$?
  assert_eq "$rc" "1" "status must exit 1 when lib/scheduler is absent"
  assert_contains "$out" "scheduler lib directory not found" "must name the absent directory"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_dependencies_name_the_install_command() {
  rm -rf "$ROOT/lib/scheduler/node_modules"
  local out rc=0
  out=$(_run playbook next-runs) || rc=$?
  assert_eq "$rc" "1" "an uninstalled lib/scheduler must not reach bun"
  assert_contains "$out" "scheduler dependencies not installed" \
    "a missing node_modules must be named, not left to Bun's module resolver"
  assert_contains "$out" "bun install" "the error must carry the command that fixes it"
  assert_eq "$(cat "$ARGV_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" "bun must not be invoked"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_stale_registry_schema_is_refused_before_bun_runs() {
  echo '{"schema_version": 1, "playbooks": []}' > "$HOME/.ceo/registry.json"
  local out rc=0
  out=$(_run status) || rc=$?
  assert_eq "$rc" "1" "a registry below the current schema must be refused"
  assert_contains "$out" "ceo playbook scan" "the refusal must name the remedy, matching ceo playbook list"
  assert_eq "$(cat "$ARGV_LOG" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "the schema gate must run before the scheduler CLI, not after"
  # The refusal must not land in the JSON stream a caller is piping to jq.
  local json_stdout
  json_stdout=$(PATH="$STUB_BIN:$PATH" bash "$CEO_CLI" status --json 2>/dev/null)
  assert_eq "$json_stdout" "" "a registry refusal must go to stderr, leaving --json stdout clean"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_help_is_answered_without_bun() {
  local direct sub
  direct=$(_run_without_bun status --help)
  assert_contains "$direct" "Usage: ceo status" "status --help must be answered by the shell"
  sub=$(_run_without_bun playbook next-runs --help)
  assert_contains "$sub" "Usage: ceo playbook next-runs" "next-runs --help must be answered by the shell"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
