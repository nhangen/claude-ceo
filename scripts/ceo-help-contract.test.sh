#!/bin/bash
# The help contract (#367): asking a `ceo` subcommand for help performs no work.
#
# `ceo playbook sync --help` performed a live vault sync because the subcommand
# recognized only the flags it knew and silently dropped the rest. The fix
# guards two layers -- a pre-dispatch intercept in the top-level `case`, and a
# guard inside each subcommand function. The intercept shadows the function
# guards for every CLI invocation, so the CLI-driven suites cannot tell whether
# the inner guards still exist. This file drives the functions DIRECTLY, with
# CEO_LIB_ONLY=1, so a removed inner guard fails here instead of waiting for a
# future in-repo caller to rediscover it.
#
# Every arm asserts the absence of a write, not just an exit code. `--help`
# exiting 0 was never the bug.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}

_load_ceo_helpers

setup() {
  TMP=$(mktemp -d)
  export HOME="$TMP/home"; mkdir -p "$HOME/.ceo"
  export CEO_VAULT="$TMP/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  VAULT_PB="$CEO_DIR/playbooks"
  REPO_PB="$TMP/repo/docs/playbooks"
  mkdir -p "$VAULT_PB" "$REPO_PB" "$CEO_DIR"
  export CEO_REPO_PLAYBOOK_DIR="$REPO_PB"

  # A repo playbook absent from the vault: sync has real work queued, so a
  # guard that fails open shows up as a file appearing in the vault.
  printf -- '---\nname: pb\nstatus: active\nscope: each\n---\n# pb\n' > "$REPO_PB/pb.md"

  # An owner with no heartbeat is stale, so owners-health has an inbox line and
  # a state-file write queued for the same reason.
  printf '%s\n' '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb": "ml-1" } }' \
    > "$CEO_DIR/swarm.json"

  cat > "$HOME/.ceo/registry.json" << 'JSON'
{
  "schema_version": 3,
  "playbooks": [
    { "name": "pb", "description": "d", "status": "active", "trigger": "cron", "scope": "each" }
  ]
}
JSON
}

teardown() {
  rm -rf "$TMP"
  unset HOME CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR CEO_HOSTNAME VAULT_PB REPO_PB TMP
}

# Files any of these subcommands would create if a help request reached the
# work. None of them exists at setup time.
_wrote_anything() {
  local hits=""
  [ -n "$(ls -A "$VAULT_PB" 2>/dev/null)" ] && hits="$hits vault-playbooks"
  [ -e "$CEO_DIR/inbox" ]                   && hits="$hits inbox"
  [ -e "$HOME/.ceo/owner-staleness-state.json" ] && hits="$hits staleness-state"
  [ -e "$HOME/.ceo/enabled.json" ]          && hits="$hits enabled.json"
  echo "${hits# }"
}

_call() { CALL_OUT=$("$@" 2>&1); CALL_RC=$?; }

_assert_help_only() {
  local label="$1" expected_usage="$2"
  assert_eq "$CALL_RC" "0" "$label must exit 0"
  assert_contains "$CALL_OUT" "$expected_usage" "$label must print its usage"
  assert_eq "$(_wrote_anything)" "" "$label must write nothing"
}

test_sync_function_answers_help() {
  _call cmd_playbook_sync --help
  _assert_help_only "cmd_playbook_sync --help" "Usage: ceo playbook sync"
}

test_diff_function_answers_help() {
  _call cmd_playbook_diff --help
  _assert_help_only "cmd_playbook_diff --help" "Usage: ceo playbook diff"
}

test_scan_function_answers_help() {
  _call cmd_playbook_scan --help
  _assert_help_only "cmd_playbook_scan --help" "Usage: ceo playbook scan"
  assert_eq "$([ -f "$HOME/.ceo/registry.json" ] && jq -r '.playbooks[0].name' "$HOME/.ceo/registry.json")" "pb" \
    "scan --help must leave the existing registry untouched"
}

test_list_function_answers_help() {
  _call cmd_playbook_list --help
  _assert_help_only "cmd_playbook_list --help" "Usage: ceo playbook list"
}

test_enable_function_answers_help_after_a_name() {
  _call cmd_playbook_enable pb --help
  _assert_help_only "cmd_playbook_enable pb --help" "Usage: ceo playbook enable"
}

test_disable_function_answers_help_after_a_name() {
  _call cmd_playbook_disable pb --help
  _assert_help_only "cmd_playbook_disable pb --help" "Usage: ceo playbook disable"
}

test_info_function_answers_help_after_a_name() {
  _call cmd_playbook_info pb --help
  _assert_help_only "cmd_playbook_info pb --help" "Usage: ceo playbook info"
}

test_assign_function_answers_help_after_a_name() {
  _call cmd_playbook_assign pb ml-1 --help
  _assert_help_only "cmd_playbook_assign pb ml-1 --help" "Usage: ceo playbook assign"
}

test_owners_health_function_answers_help() {
  _call cmd_swarm_owners_health --help
  _assert_help_only "cmd_swarm_owners_health --help" "Usage: ceo swarm owners-health"
}

test_swarm_doctor_function_answers_help() {
  _call cmd_swarm_doctor --help
  _assert_help_only "cmd_swarm_doctor --help" "Usage: ceo swarm doctor"
}

test_help_answers_before_the_vault_requirement() {
  # sync and diff open with `: "${CEO_VAULT:?...}"`. The guard sits above it, so
  # a sourced caller on a host that has never run `ceo setup` still gets usage
  # rather than a FATAL. The CLI path is covered by the top-level intercept and
  # cannot see this ordering.
  local saved="$CEO_VAULT"
  unset CEO_VAULT
  _call cmd_playbook_sync --help
  export CEO_VAULT="$saved"
  assert_eq "$CALL_RC" "0" "cmd_playbook_sync --help must exit 0 with CEO_VAULT unset"
  assert_contains "$CALL_OUT" "Usage: ceo playbook sync" "usage must print with CEO_VAULT unset"
  assert_not_contains "$CALL_OUT" "CEO_VAULT must be set" "help must answer above the vault gate"
}

test_fixture_would_detect_a_write() {
  # The arms above are only worth their exit codes if the fixture actually has
  # work queued. Prove it: the same sync without --help writes the playbook.
  cmd_playbook_sync >/dev/null 2>&1
  assert_contains "$(_wrote_anything)" "vault-playbooks" \
    "control: sync with no flags must write, or every arm above is vacuous"
}

run_tests
