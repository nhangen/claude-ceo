#!/bin/bash
# Tests for the playbook selection UX (task C2): enable/disable for `each`-scope
# playbooks (host-local enabled.json), single-owner assignment for `single`-scope
# playbooks (synced swarm.json owners), and the row renderer.
#
# Invariants under test:
#   - enable/disable mutate only THIS host's enabled.json, idempotently.
#   - enable refuses `single`-scope playbooks (those are owner-assigned, not enabled).
#   - assign refuses `each`-scope playbooks and unregistered hosts.
#   - assign REPLACES the prior owner (single-owner invariant), never appends.
#   - the renderer shows enable-state for `each` and owner-state for `single`.

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
  export CEO_HOSTNAME="ml-1"
  REGISTRY_FILE="$HOME/.ceo/registry.json"
  ENABLED_FILE="$HOME/.ceo/enabled.json"
  SWARM_FILE="$CEO_DIR/swarm.json"

  mkdir -p "$HOME/.ceo" "$CEO_DIR"

  cat > "$REGISTRY_FILE" << 'JSON'
{
  "schema_version": 3,
  "playbooks": [
    { "name": "morning-brief", "description": "daily brief", "status": "active", "trigger": "cron", "scope": "each" },
    { "name": "git-monitor",   "description": "watch repos",  "status": "active", "trigger": "cron", "scope": "each" },
    { "name": "pr-triage",     "description": "triage PRs",   "status": "active", "trigger": "cron", "scope": "single" },
    { "name": "value-tracker", "description": "track value",  "status": "active", "trigger": "cron", "scope": "single" }
  ]
}
JSON

  cat > "$ENABLED_FILE" << 'JSON'
["morning-brief"]
JSON

  cat > "$SWARM_FILE" << 'JSON'
{ "schema_version": 1, "hosts": ["ml-1", "mac"], "owners": { "pr-triage": "ml-1" } }
JSON
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP REGISTRY_FILE ENABLED_FILE SWARM_FILE
}

_enabled_has() {
  jq -e --arg n "$1" 'index($n) != null' "$ENABLED_FILE" >/dev/null 2>&1 && echo yes || echo no
}

_enabled_count() {
  jq --arg n "$1" '[.[] | select(. == $n)] | length' "$ENABLED_FILE"
}

test_enable_each_adds_to_enabled() {
  bash "$CEO_CLI" playbook enable git-monitor >/dev/null 2>&1
  assert_eq "$(_enabled_has git-monitor)" "yes" "enable must add the each playbook to enabled.json"
}

test_enable_is_idempotent() {
  bash "$CEO_CLI" playbook enable git-monitor >/dev/null 2>&1
  bash "$CEO_CLI" playbook enable git-monitor >/dev/null 2>&1
  assert_eq "$(_enabled_count git-monitor)" "1" "enabling twice must leave exactly one entry"
}

test_disable_each_removes_from_enabled() {
  bash "$CEO_CLI" playbook disable morning-brief >/dev/null 2>&1
  assert_eq "$(_enabled_has morning-brief)" "no" "disable must remove the playbook from enabled.json"
}

test_disable_absent_is_noop_success() {
  local rc=0
  bash "$CEO_CLI" playbook disable git-monitor >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "disabling an absent (but registered) playbook must succeed as a no-op"
  assert_eq "$(_enabled_has git-monitor)" "no" "absent playbook stays absent"
}

test_enable_single_refuses() {
  local rc=0 out
  out=$(bash "$CEO_CLI" playbook enable pr-triage 2>&1) || rc=$?
  assert_eq "$rc" "1" "enabling a single-scope playbook must exit non-zero"
  assert_contains "$out" "assign" "refusal must direct the user to owner assignment"
  assert_eq "$(_enabled_has pr-triage)" "no" "single playbook must not land in enabled.json"
}

test_enable_unknown_name_refuses() {
  local rc=0 out
  out=$(bash "$CEO_CLI" playbook enable not-a-playbook 2>&1) || rc=$?
  assert_eq "$rc" "1" "enabling an unregistered name must exit non-zero"
  assert_contains "$out" "not-a-playbook" "error must name the missing playbook"
}

test_disable_unknown_name_refuses() {
  local rc=0 out
  out=$(bash "$CEO_CLI" playbook disable not-a-playbook 2>&1) || rc=$?
  assert_eq "$rc" "1" "disabling an unregistered name must exit non-zero"
  assert_contains "$out" "not-a-playbook" "error must name the missing playbook"
}

test_assign_single_sets_owner() {
  bash "$CEO_CLI" playbook assign value-tracker mac >/dev/null 2>&1
  assert_eq "$(jq -r '.owners["value-tracker"]' "$SWARM_FILE")" "mac" "assign must set owners[name]=host"
}

test_assign_replaces_prior_owner() {
  # pr-triage starts owned by ml-1; re-assign to mac must REPLACE, not append.
  bash "$CEO_CLI" playbook assign pr-triage mac >/dev/null 2>&1
  assert_eq "$(jq -r '.owners["pr-triage"]' "$SWARM_FILE")" "mac" "owner must be the new host"
  assert_eq "$(jq -r '.owners["pr-triage"] | type' "$SWARM_FILE")" "string" "owner stays a single string, not a list"
}

test_assign_unregistered_host_refuses() {
  local rc=0 out
  out=$(bash "$CEO_CLI" playbook assign value-tracker ghost-host 2>&1) || rc=$?
  assert_eq "$rc" "1" "assigning to an unregistered host must exit non-zero"
  assert_contains "$out" "ghost-host" "error must name the unregistered host"
  assert_eq "$(jq -r '.owners["value-tracker"] // "none"' "$SWARM_FILE")" "none" "owners unchanged after refusal"
}

test_assign_each_playbook_refuses() {
  local rc=0 out
  out=$(bash "$CEO_CLI" playbook assign morning-brief mac 2>&1) || rc=$?
  assert_eq "$rc" "1" "assigning an each-scope playbook an owner must exit non-zero"
  assert_eq "$(jq -r '.owners["morning-brief"] // "none"' "$SWARM_FILE")" "none" "each playbook must not get an owner"
}

test_renderer_each_enabled_row() {
  local out
  out=$(bash "$CEO_CLI" playbook list 2>&1)
  # morning-brief is each + enabled here
  assert_contains "$out" "morning-brief" "list must include the each playbook"
  assert_contains "$out" "enabled here" "an enabled each playbook must render its enabled state"
}

test_renderer_each_disabled_row() {
  local out
  out=$(bash "$CEO_CLI" playbook list 2>&1)
  # git-monitor is each + NOT in enabled.json
  assert_contains "$out" "git-monitor" "list must include the disabled each playbook"
  assert_contains "$out" "disabled here" "a disabled each playbook must render its disabled state"
}

test_renderer_single_owned_row() {
  local out
  out=$(bash "$CEO_CLI" playbook list 2>&1)
  # pr-triage is single + owned by ml-1
  assert_contains "$out" "owner: ml-1" "an owned single playbook must render its owner host"
}

test_renderer_single_unowned_row() {
  local out
  out=$(bash "$CEO_CLI" playbook list 2>&1)
  # value-tracker is single + no owner
  assert_contains "$out" "owner: (none)" "an unowned single playbook must render (none)"
}

test_renderer_warns_on_out_of_set_scope() {
  cat > "$REGISTRY_FILE" << 'JSON'
{
  "schema_version": 3,
  "playbooks": [
    { "name": "typo-scope", "description": "bad scope", "status": "active", "trigger": "cron", "scope": "signle" }
  ]
}
JSON
  local err
  err=$(bash "$CEO_CLI" playbook list 2>&1 >/dev/null)
  assert_contains "$err" "typo-scope" "a corrupt scope must warn and name the playbook on stderr"
  assert_contains "$err" "out-of-set scope" "the warning must explain the scope was out of set"
  local out
  out=$(bash "$CEO_CLI" playbook list 2>/dev/null)
  assert_contains "$out" "owner: (none)" "a corrupt-scope row must still render, treated as single"
}

test_enable_does_not_clobber_malformed_enabled() {
  printf '%s' '{bad json' > "$ENABLED_FILE"
  local rc=0
  bash "$CEO_CLI" playbook enable git-monitor >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "enable must exit non-zero when jq cannot parse enabled.json"
  assert_eq "$(cat "$ENABLED_FILE")" '{bad json' "malformed enabled.json must be preserved, not clobbered"
}

test_assign_does_not_clobber_malformed_swarm() {
  printf '%s' '{bad json' > "$SWARM_FILE"
  local rc=0
  bash "$CEO_CLI" playbook assign value-tracker mac >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "assign must exit non-zero when swarm.json cannot be parsed"
  assert_eq "$(cat "$SWARM_FILE")" '{bad json' "malformed swarm.json must be preserved, not clobbered"
}

run_tests
