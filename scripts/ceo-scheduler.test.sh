#!/bin/bash
# Tests for the scheduler abstraction (#97).
#
# As of #144 the macOS per-playbook launchd backend is retired: macOS uses the
# `daemon` backend (ceo-schedulerd owns scheduling; no per-playbook OS entries).
# Covers:
#   - Backend selection priority (CEO_SCHEDULER > CEO_CRONTAB_BIN > ceo_detect_os)
#   - Unknown CEO_SCHEDULER fails loud (enum-config-typo-fallback)
#   - macOS sniffer narrowed to $HOME/.bun/bin (else daemon)
#   - macOS empty HOME aborts (shell-required-env-vars)
#   - crontab backend: list/install via CEO_CRONTAB_BIN; rc=1 on failure
#   - daemon backend: install is a no-op-with-guidance; list is empty
#   - legacy per-playbook launchd plist detection (#98 retirement / migration)

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
  export CEO_LAUNCHD_DIR="$TEST_HOME/LaunchAgents"
  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_LAUNCHD_DIR"
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
  unset CEO_SCHEDULER CEO_CRONTAB_BIN CEO_VAULT CEO_DIR CEO_LAUNCHD_DIR
  rm -rf "$TEST_HOME"
}

# === Backend selection ===

test_ceo_scheduler_env_overrides_os_detection() {
  export CEO_SCHEDULER=daemon
  assert_eq "$(ceo_scheduler_backend)" "daemon" "explicit CEO_SCHEDULER must win"
  export CEO_SCHEDULER=crontab
  assert_eq "$(ceo_scheduler_backend)" "crontab" "explicit CEO_SCHEDULER must win"
}

test_ceo_crontab_bin_implies_crontab_backend() {
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  assert_eq "$(ceo_scheduler_backend)" "crontab" "CEO_CRONTAB_BIN set forces crontab backend"
}

test_unknown_ceo_scheduler_fails_loud() {
  export CEO_SCHEDULER=launchd  # the retired backend value is now unknown
  local out rc=0
  out=$(ceo_scheduler_backend 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown CEO_SCHEDULER must return rc=1"
  assert_contains "$out" "unknown CEO_SCHEDULER='launchd'" "must surface the retired/typo value"
  rc=0; out=$(ceo_scheduler_list 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_list must propagate unknown-backend rc=1"
  rc=0; out=$(ceo_scheduler_install "x" 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_install must propagate unknown-backend rc=1"
}

test_macos_sniffer_picks_crontab_only_under_bun_bin() {
  ceo_detect_os() { echo "macos"; }
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  assert_eq \
    "$(PATH="$TEST_HOME/.bun/bin:$PATH" ceo_scheduler_backend)" "crontab" \
    "macOS + crontab under \$HOME/.bun/bin must pick crontab backend"

  mkdir -p "$TEST_HOME/bin"
  cp "$TEST_HOME/.bun/bin/crontab" "$TEST_HOME/bin/crontab"
  rm -f "$TEST_HOME/.bun/bin/crontab"
  assert_eq \
    "$(PATH="$TEST_HOME/bin:$PATH" ceo_scheduler_backend)" "daemon" \
    "macOS + crontab outside \$HOME/.bun/bin must pick daemon (narrow sniffer)"
}

test_macos_empty_home_fails_loud() {
  ceo_detect_os() { echo "macos"; }
  local rc=0
  ( HOME="" ceo_scheduler_backend >/dev/null 2>&1 ) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "empty HOME on macOS must abort (per shell-required-env-vars)"
}

# === crontab backend ===

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

# === daemon backend (#144) ===

test_daemon_backend_install_is_noop_with_guidance() {
  export CEO_SCHEDULER=daemon
  local payload="0 9 * * * /tmp/ceo-cron.sh foo  # ceo:foo"
  local out rc=0
  out=$(ceo_scheduler_install "$payload" 2>&1) || rc=$?
  assert_eq "$rc" "0" "daemon install must succeed (no-op)"
  assert_contains "$out" "ceo-schedulerd" "must point the operator at the daemon"
  assert_contains "$out" "com.ceo.schedulerd.plist" "must name the keep-alive template"
  # No per-playbook OS entries are written.
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR" 2>/dev/null || echo)" "com.ceo.foo" \
    "daemon backend must NOT write per-playbook plists"
}

test_daemon_backend_list_is_empty() {
  export CEO_SCHEDULER=daemon
  local out rc=0
  out=$(ceo_scheduler_list 2>&1) || rc=$?
  assert_eq "$rc" "0" "daemon list must succeed"
  assert_eq "$out" "" "daemon backend holds no per-playbook OS entries — list is empty"
}

# === legacy per-playbook launchd plist detection (#98 retirement) ===

test_legacy_launchd_plists_detected_excluding_daemon_agent() {
  # A retired per-playbook agent plus the daemon's own keep-alive agent.
  : > "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist"
  : > "$CEO_LAUNCHD_DIR/com.ceo.eod-3.plist"
  : > "$CEO_LAUNCHD_DIR/com.ceo.schedulerd.plist"
  : > "$CEO_LAUNCHD_DIR/com.example.other.plist"
  local out
  out=$(ceo_scheduler_legacy_launchd_plists)
  assert_contains "$out" "com.ceo.morning-0.plist" "must report a retired per-playbook agent"
  assert_contains "$out" "com.ceo.eod-3.plist" "must report every retired per-playbook agent"
  assert_no_match "$out" "com.ceo.schedulerd.plist" "must NOT report the daemon keep-alive agent"
  assert_no_match "$out" "com.example.other.plist" "must NOT report unrelated agents"
}

test_legacy_launchd_plists_empty_when_only_daemon_agent_present() {
  : > "$CEO_LAUNCHD_DIR/com.ceo.schedulerd.plist"
  local out
  out=$(ceo_scheduler_legacy_launchd_plists)
  assert_eq "$out" "" "a host with only the daemon agent has no legacy orphans"
}

test_legacy_launchd_plists_empty_when_dir_absent() {
  rm -rf "$CEO_LAUNCHD_DIR"
  local out rc=0
  out=$(ceo_scheduler_legacy_launchd_plists) || rc=$?
  assert_eq "$rc" "0" "missing LaunchAgents dir is not an error"
  assert_eq "$out" "" "missing LaunchAgents dir yields no orphans"
}

# === Integration: ceo playbook scan end-to-end on the daemon backend ===

test_playbook_scan_installs_no_plists_via_daemon_backend() {
  export CEO_SCHEDULER=daemon
  cat > "$CEO_DIR/registry.json" <<'EOF'
{"schema_version": 3, "generated": "1970-01-01T00:00:00Z", "playbooks": []}
EOF
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"
  cat > "$CEO_DIR/playbooks/scan-target.md" <<'EOF'
---
name: scan-target
description: Integration test playbook for the daemon backend
trigger: cron
schedule: "0 9 * * *"
status: active
runner: script
script: noop.sh
---
EOF
  local out rc=0
  out=$(bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "0" "playbook scan must succeed on the daemon backend"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR" 2>/dev/null || echo)" "com.ceo.scan-target" \
    "daemon backend scan must NOT write per-playbook plists"
  assert_contains "$out" "ceo-schedulerd" "scan must surface the daemon guidance"
}

run_tests
