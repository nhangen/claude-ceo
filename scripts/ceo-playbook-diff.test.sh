#!/bin/bash
# Self-contained test harness for `ceo playbook diff`.
# Mirrors ceo-cron.test.sh / ceo-config.test.sh shape.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/repo-pb"
  mkdir -p "$CEO_DIR/playbooks" "$CEO_REPO_PLAYBOOK_DIR"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR TEST_HOME HOME_BACKUP
}

write_pair() {
  local name="$1" body="$2"
  printf '%s' "$body" > "$CEO_DIR/playbooks/$name"
  printf '%s' "$body" > "$CEO_REPO_PLAYBOOK_DIR/$name"
}

test_clean_returns_0_and_says_no_drift() {
  write_pair "foo.md" "hello"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff); rc=$?
  assert_eq "$rc" "0" "clean → exit 0"
  assert_contains "$out" "No drift detected" "clean → no-drift message"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_clean_quiet_silent() {
  write_pair "foo.md" "hello"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff --quiet 2>&1); rc=$?
  assert_eq "$rc" "0" "clean --quiet → exit 0"
  assert_eq "$out" "" "clean --quiet → empty stdout+stderr"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_vault_only_drift() {
  echo "alpha" > "$CEO_DIR/playbooks/only-in-vault.md"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff); rc=$?
  assert_eq "$rc" "1" "vault-only → exit 1"
  assert_contains "$out" "Vault only: only-in-vault.md" "drift message"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_repo_only_drift() {
  echo "alpha" > "$CEO_REPO_PLAYBOOK_DIR/only-in-repo.md"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff); rc=$?
  assert_eq "$rc" "1" "repo-only → exit 1"
  assert_contains "$out" "Repo only: only-in-repo.md" "drift message"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_differs_shows_unified_diff() {
  echo "alpha" > "$CEO_DIR/playbooks/foo.md"
  echo "beta"  > "$CEO_REPO_PLAYBOOK_DIR/foo.md"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff); rc=$?
  assert_eq "$rc" "1" "differs → exit 1"
  assert_contains "$out" "Differs: foo.md" "differs label"
  assert_contains "$out" "+++" "unified diff header present"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_quiet_on_drift_silent_but_nonzero() {
  echo "x" > "$CEO_DIR/playbooks/only-vault.md"
  local out rc
  out=$(bash "$CEO_CLI" playbook diff --quiet 2>&1); rc=$?
  assert_eq "$rc" "1" "quiet drift → exit 1"
  assert_eq "$out" "" "quiet drift → no output"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_quiet_arg_forwarded_from_dispatcher() {
  echo "x" > "$CEO_DIR/playbooks/only-vault.md"
  # Subcommand-positional form: `ceo playbook diff --quiet`. Before the fix,
  # the dispatcher dropped "$@" so this leaked verbose output.
  local out
  out=$(bash "$CEO_CLI" playbook diff --quiet 2>&1 || true)
  assert_not_contains "$out" "Vault only" "dispatcher must forward --quiet flag"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_vault_dir_returns_2_not_1() {
  rm -rf "$CEO_DIR/playbooks"
  local rc=0
  bash "$CEO_CLI" playbook diff --quiet >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "missing vault dir → exit 2 (distinct from drift's 1)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_repo_dir_returns_2() {
  rm -rf "$CEO_REPO_PLAYBOOK_DIR"
  local rc=0
  bash "$CEO_CLI" playbook diff --quiet >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "missing repo dir → exit 2"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_unset_vault_fails_loudly() {
  unset CEO_VAULT
  unset CEO_DIR
  local out rc=0
  out=$(bash "$CEO_CLI" playbook diff --quiet 2>&1) || rc=$?
  # `${VAR:?msg}` causes the shell to print the message and exit non-zero.
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL [%s] unset CEO_VAULT should fail loudly, got rc=0\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$out" "CEO_VAULT" "error must name the missing variable"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_both_dirs_empty_no_drift() {
  local out rc
  out=$(bash "$CEO_CLI" playbook diff); rc=$?
  assert_eq "$rc" "0" "both empty → exit 0"
  assert_contains "$out" "No drift detected" "both empty → no drift"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
