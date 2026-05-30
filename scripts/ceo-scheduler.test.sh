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

test_noop_launchd_list_is_empty() {
  export CEO_SCHEDULER=noop-launchd
  local out
  out=$(ceo_scheduler_list 2>&1)
  assert_eq "$out" "" "noop-launchd list must produce empty output"
}

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
