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
  # Explicit rather than inherited from HOME — see _ceo_state_dir in ceo-config.sh.
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  mkdir -p "$CEO_STATE_DIR"
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
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR CEO_REPO_PLAYBOOK_DIR TEST_HOME HOME_BACKUP PATH_BACKUP
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

test_invariant_non_active_repo_playbook_is_never_active_in_registry() {
  # Invariant (#292): For any playbook whose repo definition is not active (disabled,
  # draft), scanning must never record it as active in the registry.
  cat > "$CEO_REPO_PLAYBOOK_DIR/repo-disabled.md" << 'PB'
---
name: repo-disabled
description: repo disabled fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: disabled
---
# noop
PB
  cat > "$CEO_REPO_PLAYBOOK_DIR/repo-draft.md" << 'PB'
---
name: repo-draft
description: repo draft fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: draft
---
# noop
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_registry_status repo-disabled)" "disabled" \
    "disabled repo playbook must be recorded as disabled, never active"
  assert_eq "$(_registry_status repo-draft)" "draft" \
    "draft repo playbook must be recorded as draft, never active"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

test_scan_persists_playbook_drift_alert_on_shadowed_drift() {
  # When a vault copy shadows a differing repo copy, scan must persist a
  # playbook-drift.md alert file with transition-gated frontmatter (#292).
  cat > "$CEO_REPO_PLAYBOOK_DIR/p-shadow.md" << 'PB'
---
name: p-shadow
description: repo original version
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  cat > "$CEO_DIR/playbooks/p-shadow.md" << 'PB'
---
name: p-shadow
description: differing vault copy
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local alert_file="$CEO_DIR/alerts/playbook-drift.md"
  assert_file_exists "$alert_file" "shadowed drift must create playbook-drift.md alert"
  local content; content=$(cat "$alert_file" 2>/dev/null || echo "")
  assert_contains "$content" "status: firing" "alert must carry status: firing frontmatter"
  assert_contains "$content" "host:" "alert must carry host frontmatter"
  assert_contains "$content" "count: 1" "alert must carry count frontmatter"
  assert_contains "$content" "since:" "alert must carry since timestamp"

  # Morning scan must report the alert as cleanly firing, without corrupted warnings (#504)
  local scan_out scan_err
  scan_out=$(CEO_VAULT="$CEO_VAULT" bash -c "source '$SCRIPT_DIR/ceo-scan.sh'; printf '%b' \"\$ALERTS_FIRING\"" 2>"$TEST_HOME/scan.err")
  scan_err=$(cat "$TEST_HOME/scan.err" 2>/dev/null || echo "")
  assert_not_contains "$scan_err" "corrupted" "morning scan must not report corrupted alert status on stderr"
  assert_not_contains "$scan_out" "corrupted" "ALERTS_FIRING must not contain corrupted marker"
  assert_contains "$scan_out" "playbook-drift (host=" "ALERTS_FIRING must contain clean firing playbook-drift alert"
}

test_scan_drift_alert_refreshes_state() {
  # An alert is current state (#455): every scan rewrites it with the current count:
  # and a fresh last_check:, while since: keeps the moment the drift began. Both
  # timestamps are pinned to a past value because they have one-second resolution,
  # and back-to-back scans would otherwise match by accident.
  cat > "$CEO_REPO_PLAYBOOK_DIR/p-cg1.md" << 'PB'
---
name: p-cg1
description: repo original version
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  cat > "$CEO_DIR/playbooks/p-cg1.md" << 'PB'
---
name: p-cg1
description: differing vault copy 1
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local alert_file="$CEO_DIR/alerts/playbook-drift.md"
  assert_file_exists "$alert_file" "alert must exist after first scan"
  local content1; content1=$(cat "$alert_file")
  assert_contains "$content1" "status: firing" "alert must carry status: firing"
  assert_contains "$content1" "host:" "alert must carry host frontmatter"
  assert_contains "$content1" "count: 1" "alert must carry count: 1"

  sed -i.bak -e 's/^since:.*/since: 2020-01-01T00:00:00Z/' \
    -e 's/^last_check:.*/last_check: 2020-01-01T00:00:00Z/' "$alert_file"
  rm -f "$alert_file.bak"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local content2; content2=$(cat "$alert_file")
  assert_contains "$content2" "since: 2020-01-01T00:00:00Z" "a same-count scan must keep since:"
  assert_not_contains "$content2" "last_check: 2020-01-01T00:00:00Z" "every scan must refresh last_check:"

  # An alert written before #458 has no count: line; the next scan must add it.
  sed -i.bak '/^count:/d' "$alert_file"
  rm -f "$alert_file.bak"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_contains "$(cat "$alert_file")" "count: 1" "a scan must add count: to an alert that lacks it"

  # Now introduce a second differing playbook (count increases 1 -> 2).
  cat > "$CEO_REPO_PLAYBOOK_DIR/p-cg2.md" << 'PB'
---
name: p-cg2
description: repo original version 2
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  cat > "$CEO_DIR/playbooks/p-cg2.md" << 'PB'
---
name: p-cg2
description: differing vault copy 2
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local content3; content3=$(cat "$alert_file")
  assert_contains "$content3" "count: 2" "alert must update to count: 2"
  local new_since
  new_since=$(awk '/^since:/ { sub(/^since:[[:space:]]*/, ""); print; exit }' "$alert_file")
  assert_eq "$new_since" "2020-01-01T00:00:00Z" "alert must preserve original since timestamp across count updates"
}

test_scan_clears_playbook_drift_alert_when_in_sync() {
  # After syncing vault copies to match repo, scan must clear the drift alert (#292).
  cat > "$CEO_REPO_PLAYBOOK_DIR/p-insync.md" << 'PB'
---
name: p-insync
description: repo version
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  cat > "$CEO_DIR/playbooks/p-insync.md" << 'PB'
---
name: p-insync
description: differing vault version
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local alert_file="$CEO_DIR/alerts/playbook-drift.md"
  assert_file_exists "$alert_file" "precondition: drift alert exists before sync"

  bash "$CEO_CLI" playbook sync >/dev/null 2>&1
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local exists="present"
  [ ! -f "$alert_file" ] && exists="missing"
  assert_eq "$exists" "missing" "scan must remove playbook-drift.md when trees are in sync"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

run_tests
