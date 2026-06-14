#!/bin/bash
# Self-contained test harness for the playbook status enum (active/draft/disabled).
# Covers nhangen/claude-ceo#90.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  # The generated registry is host-local now ($HOME/.ceo/registry.json), not in
  # the synced vault — `ceo playbook scan` writes it there.
  REGISTRY_FILE="$HOME/.ceo/registry.json"

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$TEST_HOME/empty-repo-playbooks" "$HOME/.ceo"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"

  # The native crontab install path is retired (D1) — scan never touches the
  # crontab now. This stub records any invocation to $HOME/.fake-crontab so the
  # tests can assert scan does NOT install, and the status enum gates *registry
  # inclusion* (ceo-schedulerd reads the registry) rather than cron lines.
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then
  cat "$HOME/.fake-crontab" 2>/dev/null || true
  exit 0
fi
cat > "$HOME/.fake-crontab"
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  : > "$HOME/.fake-crontab"

  export PATH="$TEST_HOME/.bun/bin:$PATH"
}

# A playbook's effective schedule status in the registry: "active" means the
# daemon will dispatch it; anything else (draft/disabled/absent) means it won't.
_registry_status() {
  jq -r --arg n "$1" '.playbooks[] | select(.name==$n) | .status // "none"' \
    "$REGISTRY_FILE" 2>/dev/null
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR TEST_HOME HOME_BACKUP PATH_BACKUP
}

_write_playbook() {
  local name="$1" status="$2"
  cat > "$CEO_DIR/playbooks/$name.md" << PB
---
name: $name
description: status-enum fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: $status
---
# noop
PB
}

test_status_active_recorded_active_in_registry() {
  _write_playbook "p-active" "active"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status p-active)" "active" \
    "active playbook must be recorded active in the registry (daemon schedules it)"
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_not_contains "$crontab" "ceo:p-active" "scan must NOT install a cron line for an active playbook"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_draft_recorded_draft_in_registry() {
  _write_playbook "p-draft" "draft"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status p-draft)" "draft" \
    "draft playbook must be recorded draft (daemon must not dispatch a non-active status)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_disabled_recorded_disabled_in_registry() {
  _write_playbook "p-disabled" "disabled"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status p-disabled)" "disabled" \
    "disabled playbook must be recorded disabled (daemon must not dispatch it)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_toggle_active_to_disabled_updates_registry() {
  _write_playbook "p-toggle" "active"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status p-toggle)" "active" "precondition: active scan records active"

  _write_playbook "p-toggle" "disabled"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status p-toggle)" "disabled" \
    "disabled rescan must flip the registry status so the daemon stops dispatching it"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_invalid_rejects_at_parse() {
  _write_playbook "p-typo" "scrpt"
  local output
  output=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  assert_contains "$output" "SKIP" "parse must emit the SKIP diagnostic"
  assert_contains "$output" "p-typo" "scan must mention the offending playbook"
  assert_contains "$output" "scrpt" "scan must echo the rejected value"
  local registry_has
  registry_has=$(jq -r '[.playbooks[] | select(.name=="p-typo")] | length' "$REGISTRY_FILE" 2>/dev/null)
  assert_eq "$registry_has" "0" "rejected playbook must not land in the registry"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_invalid_exits_nonzero() {
  _write_playbook "p-typo-rc" "scrpt"
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "unknown-status SKIP must propagate non-zero exit per enum-config-typo-fallback"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_scan_rejects_unknown_argument() {
  _write_playbook "p-arg" "active"
  : > "$HOME/.fake-crontab"
  local rc=0 output
  output=$(bash "$CEO_CLI" playbook scan --dryrun 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown scan argument must exit non-zero (not silently run a real scan)"
  assert_contains "$output" "ERROR" "unknown scan argument must emit an ERROR line"
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_eq "$crontab" "" "unknown scan argument must NOT touch the crontab"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_missing_defaults_to_inactive() {
  # status: "" / absent — current behavior is "not active" but still parses
  # cleanly and lands in the registry (back-compat).
  cat > "$CEO_DIR/playbooks/p-empty.md" << 'PB'
---
name: p-empty
description: no status field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local registry_has
  registry_has=$(jq -r '[.playbooks[] | select(.name=="p-empty")] | length' "$REGISTRY_FILE" 2>/dev/null)
  assert_eq "$registry_has" "1" "missing-status playbook must still land in registry (back-compat)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_does_not_modify_crontab() {
  : > "$HOME/.fake-crontab"
  _write_playbook "p-dry" "active"
  bash "$CEO_CLI" playbook scan --dry-run >/dev/null 2>&1
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_eq "$crontab" "" "scan --dry-run must not write to the crontab"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_does_not_write_registry() {
  _write_playbook "p-dry-reg" "active"
  [ -f "$REGISTRY_FILE" ] && rm -f "$REGISTRY_FILE"
  bash "$CEO_CLI" playbook scan --dry-run >/dev/null 2>&1
  local exists="missing"
  [ -f "$REGISTRY_FILE" ] && exists="present"
  assert_eq "$exists" "missing" "scan --dry-run must not create registry.json"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_reports_summary_without_writing() {
  _write_playbook "p-dry-print" "active"
  local output
  output=$(bash "$CEO_CLI" playbook scan --dry-run 2>&1)
  assert_contains "$output" "NOT written" "dry-run must declare that nothing was written"
  assert_contains "$output" "Registry:" "dry-run must report the registry summary"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_list_shows_draft_tag() {
  # Use a fixture name that does NOT contain the status word so the
  # assert_contains check can't trivially match on the playbook name.
  _write_playbook "p-wip" "draft"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local output
  output=$(bash "$CEO_CLI" playbook list 2>&1)
  assert_contains "$output" "p-wip" "list must include draft playbooks"
  assert_contains "$output" "draft" "list must surface the draft status"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_list_shows_disabled_tag() {
  _write_playbook "p-off" "disabled"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local output
  output=$(bash "$CEO_CLI" playbook list 2>&1)
  assert_contains "$output" "p-off" "list must include disabled playbooks"
  assert_contains "$output" "disabled" "list must surface the disabled status"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_surfaces_drafts() {
  _write_playbook "p-doctor-wip" "draft"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local output
  output=$(bash "$CEO_CLI" doctor 2>&1 || true)
  # Anchor on the section header literal so a regression that deletes the
  # Drafts block but leaves the standard playbook enumeration intact fails.
  assert_contains "$output" "Drafts (not scheduled by the daemon" "doctor must emit the Drafts section header"
  assert_contains "$output" "p-doctor-wip" "doctor must list the draft playbook by name"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
