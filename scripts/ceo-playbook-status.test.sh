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

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$TEST_HOME/empty-repo-playbooks"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"

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

test_status_active_installs_cron_line() {
  _write_playbook "p-active" "active"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_contains "$crontab" "ceo:p-active" "active playbook must appear in installed crontab"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_draft_does_not_install_cron_line() {
  _write_playbook "p-draft" "draft"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_not_contains "$crontab" "ceo:p-draft" "draft playbook must NOT appear in crontab"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_disabled_does_not_install_cron_line() {
  _write_playbook "p-disabled" "disabled"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_not_contains "$crontab" "ceo:p-disabled" "disabled playbook must NOT appear in crontab"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_disabled_removes_previously_installed_line() {
  _write_playbook "p-toggle" "active"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local crontab_before
  crontab_before=$(cat "$HOME/.fake-crontab")
  assert_contains "$crontab_before" "ceo:p-toggle" "precondition: active install must have placed a line"

  _write_playbook "p-toggle" "disabled"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local crontab_after
  crontab_after=$(cat "$HOME/.fake-crontab")
  assert_not_contains "$crontab_after" "ceo:p-toggle" "disabled rescan must drop the previously-installed line"
  local registry_status
  registry_status=$(jq -r '.playbooks[] | select(.name=="p-toggle") | .status' "$CEO_DIR/registry.json" 2>/dev/null)
  assert_eq "$registry_status" "disabled" "registry must reflect the new disabled status"
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
  registry_has=$(jq -r '[.playbooks[] | select(.name=="p-typo")] | length' "$CEO_DIR/registry.json" 2>/dev/null)
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
  local crontab
  crontab=$(cat "$HOME/.fake-crontab")
  assert_not_contains "$crontab" "ceo:p-empty" "missing status must not install cron line"
  local registry_has
  registry_has=$(jq -r '[.playbooks[] | select(.name=="p-empty")] | length' "$CEO_DIR/registry.json" 2>/dev/null)
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
  [ -f "$CEO_DIR/registry.json" ] && rm -f "$CEO_DIR/registry.json"
  bash "$CEO_CLI" playbook scan --dry-run >/dev/null 2>&1
  local exists="missing"
  [ -f "$CEO_DIR/registry.json" ] && exists="present"
  assert_eq "$exists" "missing" "scan --dry-run must not create registry.json"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_prints_would_install_block() {
  _write_playbook "p-dry-print" "active"
  local output
  output=$(bash "$CEO_CLI" playbook scan --dry-run 2>&1)
  assert_contains "$output" "DRY-RUN" "dry-run output must declare itself"
  assert_contains "$output" "ceo:p-dry-print" "dry-run output must show the would-be cron line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_output_matches_installed_block() {
  # Locks in the invariant that the dry-run preview emits the SAME cron
  # block the real install would write — protects against drift between
  # _playbook_print_cron_block and _playbook_update_crontab.
  _write_playbook "p-parity-a" "active"
  _write_playbook "p-parity-b" "draft"
  _write_playbook "p-parity-c" "active"
  # Use unique schedules so collision detection on the real path passes.
  sed -i.bak 's|0 9 \* \* \*|0 11 * * *|' "$CEO_DIR/playbooks/p-parity-c.md"
  rm -f "$CEO_DIR/playbooks/p-parity-c.md.bak"

  local dry_out
  dry_out=$(bash "$CEO_CLI" playbook scan --dry-run 2>&1 \
    | awk '/CEO Agent START/,/CEO Agent END/')

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local installed
  installed=$(awk '/CEO Agent START/,/CEO Agent END/' "$HOME/.fake-crontab")

  assert_eq "$dry_out" "$installed" "dry-run cron block must byte-equal the installed cron block"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_dry_run_omits_draft_and_disabled() {
  _write_playbook "p-dry-a" "active"
  _write_playbook "p-dry-d" "draft"
  _write_playbook "p-dry-x" "disabled"
  local output
  output=$(bash "$CEO_CLI" playbook scan --dry-run 2>&1)
  assert_contains "$output" "ceo:p-dry-a" "dry-run must include active playbooks"
  assert_not_contains "$output" "ceo:p-dry-d" "dry-run must omit draft playbooks from the cron block"
  assert_not_contains "$output" "ceo:p-dry-x" "dry-run must omit disabled playbooks from the cron block"
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
  assert_contains "$output" "Drafts (not installed in cron" "doctor must emit the Drafts section header"
  assert_contains "$output" "p-doctor-wip" "doctor must list the draft playbook by name"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
