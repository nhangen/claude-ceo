#!/bin/bash
# Tests for the scheduler abstraction (#97).
#
# Covers:
#   - Backend selection priority (CEO_SCHEDULER > CEO_CRONTAB_BIN > ceo_detect_os)
#   - noop-launchd: list returns empty; install returns rc=2 with not-implemented message
#   - crontab: list reads via CEO_CRONTAB_BIN; install routes payload to CEO_CRONTAB_BIN
#   - Integration: `ceo playbook scan` on macOS (CEO_SCHEDULER=noop-launchd) exits
#     non-zero and does NOT corrupt the registry on disk.

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
  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/inbox.md"

  unset CEO_SCHEDULER CEO_CRONTAB_BIN
  # shellcheck source=ceo-config.sh
  source "$SCRIPT_DIR/ceo-config.sh"
  # shellcheck source=ceo-scheduler.sh
  source "$SCRIPT_DIR/ceo-scheduler.sh"
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_SCHEDULER CEO_CRONTAB_BIN CEO_VAULT CEO_DIR
  rm -rf "$TEST_HOME"
}

test_ceo_scheduler_env_overrides_os_detection() {
  export CEO_SCHEDULER=noop-launchd
  assert_eq "$(ceo_scheduler_backend)" "noop-launchd" "explicit CEO_SCHEDULER must win"
  export CEO_SCHEDULER=crontab
  assert_eq "$(ceo_scheduler_backend)" "crontab" "explicit CEO_SCHEDULER must win"
}

test_ceo_crontab_bin_implies_crontab_backend() {
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  assert_eq "$(ceo_scheduler_backend)" "crontab" "CEO_CRONTAB_BIN set forces crontab backend"
}

test_noop_launchd_install_returns_rc_2_with_message() {
  export CEO_SCHEDULER=noop-launchd
  local out rc=0
  out=$(ceo_scheduler_install "any-payload" 2>&1) || rc=$?
  assert_eq "$rc" "2" "noop-launchd install must return rc=2"
  assert_contains "$out" "launchd backend not yet implemented" "must surface not-implemented message"
}

test_noop_launchd_list_is_empty_and_does_not_invoke_crontab() {
  # Place a tripwire stub that records any invocation; noop backend must
  # never call it. If `ceo_scheduler_list`'s noop arm is reverted to fall
  # through to the crontab branch, the tripwire fires and the assertion
  # on the witness file's absence fails.
  cat > "$TEST_HOME/tripwire-crontab" <<STUB
#!/bin/bash
touch "$TEST_HOME/tripwire-fired"
STUB
  chmod +x "$TEST_HOME/tripwire-crontab"
  export CEO_CRONTAB_BIN="$TEST_HOME/tripwire-crontab"
  export CEO_SCHEDULER=noop-launchd
  local out rc=0
  out=$(ceo_scheduler_list 2>&1) || rc=$?
  assert_eq "$rc" "0" "noop-launchd list must succeed"
  assert_eq "$out" "" "noop-launchd list must produce empty output"
  if [ -f "$TEST_HOME/tripwire-fired" ]; then
    assert_eq "tripwire" "untouched" "noop backend must not invoke CEO_CRONTAB_BIN"
  fi
}

test_unknown_ceo_scheduler_fails_loud() {
  export CEO_SCHEDULER=noop-luanchd
  local out rc=0
  out=$(ceo_scheduler_backend 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown CEO_SCHEDULER must return rc=1"
  assert_contains "$out" "unknown CEO_SCHEDULER='noop-luanchd'" "must surface typo to user"
  # _list and _install must propagate the rc, not masquerade as empty/zero
  rc=0; out=$(ceo_scheduler_list 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_list must propagate unknown-backend rc=1"
  rc=0; out=$(ceo_scheduler_install "x" 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_install must propagate unknown-backend rc=1"
}

test_playbook_scan_propagates_rc_2_from_noop_backend() {
  # The public API at ceo-scheduler.sh advertises rc=2 for the noop backend.
  # Callers must preserve it instead of collapsing to rc=1.
  : > "$CEO_DIR/inbox.md"
  cat > "$CEO_DIR/registry.json" <<'EOF'
{"schema_version": 3, "generated": "1970-01-01T00:00:00Z", "playbooks": []}
EOF
  export CEO_SCHEDULER=noop-launchd
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "playbook scan must propagate rc=2 from noop-launchd backend"
}

test_macos_sniffer_picks_crontab_only_under_bun_bin() {
  # Stub ceo_detect_os in this shell to force the macos branch.
  ceo_detect_os() { echo "macos"; }
  # Stub under the documented test path → expect crontab backend.
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  PATH="$TEST_HOME/.bun/bin:$PATH" assert_eq \
    "$(PATH="$TEST_HOME/.bun/bin:$PATH" ceo_scheduler_backend)" "crontab" \
    "macOS + crontab under \$HOME/.bun/bin must pick crontab backend"

  # Stub OUTSIDE .bun/bin (under $HOME/bin) → must NOT trigger the sniffer.
  mkdir -p "$TEST_HOME/bin"
  cp "$TEST_HOME/.bun/bin/crontab" "$TEST_HOME/bin/crontab"
  rm -f "$TEST_HOME/.bun/bin/crontab"
  assert_eq \
    "$(PATH="$TEST_HOME/bin:$PATH" ceo_scheduler_backend)" "noop-launchd" \
    "macOS + crontab outside \$HOME/.bun/bin must pick noop-launchd (narrow sniffer)"
}

test_macos_empty_home_fails_loud() {
  ceo_detect_os() { echo "macos"; }
  local rc=0
  ( HOME="" ceo_scheduler_backend >/dev/null 2>&1 ) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "empty HOME on macOS must abort (per shell-required-env-vars)"
}

# Production-entry-point payload capture is covered by
# ceo-schedule.test.sh:test_collision_resolved_after_override (line 126) —
# it drives `_playbook_update_crontab` through CEO_CRONTAB_BIN and asserts
# the captured payload contains the ceo:<name> line. No duplicate test here.

test_crontab_backend_install_routes_payload_to_ceo_crontab_bin() {
  local capture="$TEST_HOME/crontab-capture.out"
  cat > "$TEST_HOME/fake-crontab" <<STUB
#!/bin/bash
cat > "$capture"
STUB
  chmod +x "$TEST_HOME/fake-crontab"
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  ceo_scheduler_install "marker-line-PAYLOAD" >/dev/null 2>&1
  local got
  got=$(cat "$capture" 2>/dev/null || echo "")
  assert_contains "$got" "marker-line-PAYLOAD" "payload must reach the crontab binary"
}

test_crontab_install_failure_surfaces_as_rc_1() {
  cat > "$TEST_HOME/failing-crontab" <<'STUB'
#!/bin/bash
echo "crontab: install failed (simulated)" >&2
exit 7
STUB
  chmod +x "$TEST_HOME/failing-crontab"
  export CEO_CRONTAB_BIN="$TEST_HOME/failing-crontab"
  local out rc=0
  out=$(ceo_scheduler_install "x" 2>&1) || rc=$?
  assert_eq "$rc" "1" "crontab failure must propagate as rc=1"
  assert_contains "$out" "crontab install failed" "error message must surface"
}

test_playbook_scan_on_noop_backend_does_not_corrupt_registry() {
  # Seed a minimal registry that ceo playbook scan would normally overwrite.
  cat > "$CEO_DIR/registry.json" <<'EOF'
{
  "schema_version": 3,
  "generated": "1970-01-01T00:00:00Z",
  "playbooks": [
    {"name": "test-playbook", "trigger": "cron", "schedule": "0 9 * * *", "status": "active", "runner": "script"}
  ]
}
EOF
  local registry_before
  registry_before=$(cat "$CEO_DIR/registry.json")

  mkdir -p "$CEO_DIR/playbooks/test-playbook"
  cat > "$CEO_DIR/playbooks/test-playbook/playbook.md" <<'EOF'
---
name: test-playbook
trigger: cron
schedule: "0 9 * * *"
status: active
runner: script
script: noop.sh
---
EOF

  export CEO_SCHEDULER=noop-launchd
  local out rc=0
  out=$(bash "$CEO_CLI" playbook scan 2>&1) || rc=$?

  assert_eq "$([ "$rc" != "0" ] && echo nonzero || echo zero)" "nonzero" "playbook scan must exit non-zero on noop backend"
  assert_contains "$out" "launchd backend not yet implemented" "must surface scheduler error to user"

  local registry_after
  registry_after=$(cat "$CEO_DIR/registry.json")
  assert_eq "$registry_after" "$registry_before" "registry on disk must be unchanged after aborted scan"
}

run_tests
