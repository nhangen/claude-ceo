#!/bin/bash
# Tests for the scheduler abstraction (#97) + launchd backend (#98).
#
# Covers:
#   - Backend selection priority (CEO_SCHEDULER > CEO_CRONTAB_BIN > ceo_detect_os)
#   - Unknown CEO_SCHEDULER fails loud (enum-config-typo-fallback)
#   - macOS sniffer narrowed to $HOME/.bun/bin (AC #3 of #97)
#   - macOS empty HOME aborts (shell-required-env-vars)
#   - crontab backend: list/install via CEO_CRONTAB_BIN; rc=1 on failure
#   - launchd backend: cron-field expansion, plist generation, install writes
#     plists + bootstraps, re-install removes stale plists (AC of #98),
#     list reconstructs cron-style lines, integration via `ceo playbook scan`.

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
  export CEO_LAUNCHCTL_BIN="$TEST_HOME/stub-launchctl"
  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_LAUNCHD_DIR"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/inbox.md"

  # Recording launchctl stub — logs every invocation to $TEST_HOME/launchctl.log.
  cat > "$CEO_LAUNCHCTL_BIN" <<STUB
#!/bin/bash
echo "\$@" >> "$TEST_HOME/launchctl.log"
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"

  unset CEO_SCHEDULER CEO_CRONTAB_BIN
  # shellcheck source=ceo-config.sh
  source "$SCRIPT_DIR/ceo-config.sh"
  # shellcheck source=ceo-scheduler.sh
  source "$SCRIPT_DIR/ceo-scheduler.sh"
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_SCHEDULER CEO_CRONTAB_BIN CEO_VAULT CEO_DIR CEO_LAUNCHD_DIR CEO_LAUNCHCTL_BIN
  rm -rf "$TEST_HOME"
}

# === Backend selection ===

test_ceo_scheduler_env_overrides_os_detection() {
  export CEO_SCHEDULER=launchd
  assert_eq "$(ceo_scheduler_backend)" "launchd" "explicit CEO_SCHEDULER must win"
  export CEO_SCHEDULER=crontab
  assert_eq "$(ceo_scheduler_backend)" "crontab" "explicit CEO_SCHEDULER must win"
}

test_ceo_crontab_bin_implies_crontab_backend() {
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  assert_eq "$(ceo_scheduler_backend)" "crontab" "CEO_CRONTAB_BIN set forces crontab backend"
}

test_unknown_ceo_scheduler_fails_loud() {
  export CEO_SCHEDULER=launhd
  local out rc=0
  out=$(ceo_scheduler_backend 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown CEO_SCHEDULER must return rc=1"
  assert_contains "$out" "unknown CEO_SCHEDULER='launhd'" "must surface typo to user"
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
    "$(PATH="$TEST_HOME/bin:$PATH" ceo_scheduler_backend)" "launchd" \
    "macOS + crontab outside \$HOME/.bun/bin must pick launchd (narrow sniffer)"
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

# === launchd: cron-field expansion ===

test_cron_field_expand_handles_all_shapes() {
  assert_eq "$(_ceo_cron_field_expand '*' 0 59)" "*" "* must remain literal *"
  assert_eq "$(_ceo_cron_field_expand '7' 0 59)" "7" "integer must pass through"
  assert_eq "$(_ceo_cron_field_expand '1-5' 0 23)" "1 2 3 4 5" "range expands"
  assert_eq "$(_ceo_cron_field_expand '1,3' 0 6)" "1 3" "list expands"
  assert_eq "$(_ceo_cron_field_expand '*/6' 0 23)" "0 6 12 18" "step expands within range"
  assert_eq "$(_ceo_cron_field_expand 'SUN' 0 6)" "0" "named SUN expands to 0"
  assert_eq "$(_ceo_cron_field_expand 'MON' 0 6)" "1" "named MON expands to 1"
}

test_tuples_from_payload_parses_real_registry_lines() {
  local payload
  payload=$(cat <<'BLOCK'
# CEO Agent START
0 9 * * * /path/to/ceo-cron.sh morning  # ceo:morning
47 17 * * 1-5 /path/to/ceo-cron.sh eod  # ceo:eod
0 8 * * SUN /path/to/ceo-cron.sh weekly  # ceo:weekly
# CEO Agent END
BLOCK
)
  local out
  out=$(_ceo_launchd_tuples_from_payload "$payload")
  # morning: 1 tuple (every day at 9:00, weekday=*)
  assert_contains "$out" "com.ceo.morning-0	0	9	*	"
  # eod: 5 tuples (Mon-Fri at 17:47)
  assert_contains "$out" "com.ceo.eod-0	47	17	1	"
  assert_contains "$out" "com.ceo.eod-4	47	17	5	"
  # weekly: 1 tuple (SUN at 08:00)
  assert_contains "$out" "com.ceo.weekly-0	0	8	0	"
  # Count: 1 + 5 + 1 = 7 lines
  local lines
  lines=$(printf '%s\n' "$out" | grep -c "^com.ceo." || true)
  assert_eq "$lines" "7" "must emit 7 tuples for 3 triggers (1 + 5 + 1)"
}

# === launchd: install writes plists + bootstraps + cleans stale ===

test_launchd_install_writes_one_plist_per_tuple() {
  export CEO_SCHEDULER=launchd
  local payload
  payload=$(cat <<'BLOCK'
# CEO Agent START
0 9 * * * /path/to/ceo-cron.sh morning  # ceo:morning
0 8 * * 1,3 /path/to/ceo-cron.sh twice  # ceo:twice
# CEO Agent END
BLOCK
)
  ceo_scheduler_install "$payload" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist" "morning plist must be written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.twice-0.plist" "twice (Mon) plist must be written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.twice-1.plist" "twice (Wed) plist must be written"
  # Plist contents — Minute, Hour, command
  local morning
  morning=$(cat "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist")
  assert_contains "$morning" "<integer>9</integer>" "morning plist must encode Hour=9"
  assert_contains "$morning" "/path/to/ceo-cron.sh morning" "plist must carry command"
}

test_launchd_install_bootstraps_each_plist_via_launchctl() {
  export CEO_SCHEDULER=launchd
  local payload="0 9 * * * /tmp/ceo-cron.sh foo  # ceo:foo"
  ceo_scheduler_install "$payload" >/dev/null 2>&1
  local log
  log=$(cat "$TEST_HOME/launchctl.log" 2>/dev/null || echo "")
  assert_contains "$log" "bootstrap gui/" "launchctl must be invoked with bootstrap"
  assert_contains "$log" "com.ceo.foo-0.plist" "bootstrap must reference the written plist"
}

test_launchd_install_removes_stale_plists_on_rescan() {
  export CEO_SCHEDULER=launchd
  # First install: two playbooks.
  local payload_v1
  payload_v1=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper
0 10 * * * /tmp/ceo-cron.sh stale  # ceo:stale
BLOCK
)
  ceo_scheduler_install "$payload_v1" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" "v1: keeper plist written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.stale-0.plist" "v1: stale plist written"

  # Second install: stale playbook removed from registry.
  local payload_v2="0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper"
  # Truncate the launchctl log before v2 so the bootout assertion below only
  # observes v2 activity — otherwise the per-install bootout from v1 would
  # satisfy a bare "bootout" assertion regardless of stale cleanup.
  : > "$TEST_HOME/launchctl.log"
  ceo_scheduler_install "$payload_v2" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" "v2: keeper plist preserved"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR")" "com.ceo.stale-0.plist" \
    "v2: stale plist must be cleaned up on rescan"
  # bootout must fire specifically against the stale plist's path.
  local log
  log=$(cat "$TEST_HOME/launchctl.log" 2>/dev/null || echo "")
  assert_contains "$log" "bootout gui/" "launchctl bootout must fire during v2"
  assert_contains "$log" "com.ceo.stale-0.plist" \
    "bootout must reference the stale plist by name"
}

test_launchd_install_rolls_back_on_bootstrap_failure_mid_loop() {
  export CEO_SCHEDULER=launchd
  # Seed a prior live install so we can verify rollback doesn't disturb it.
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh prior  # ceo:prior" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.prior-0.plist" "prior install must seed"

  # Stub that fails the second bootstrap call. Counter persisted via a file
  # so it survives the stub's per-invocation subshell.
  local counter="$TEST_HOME/bootstrap-counter"
  echo 0 > "$counter"
  cat > "$CEO_LAUNCHCTL_BIN" <<STUB
#!/bin/bash
echo "\$@" >> "$TEST_HOME/launchctl.log"
if [ "\$1" = "bootstrap" ]; then
  n=\$(cat "$counter")
  n=\$((n + 1))
  echo \$n > "$counter"
  if [ "\$n" -eq 2 ]; then
    echo "simulated bootstrap failure" >&2
    exit 5
  fi
fi
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"

  : > "$TEST_HOME/launchctl.log"
  # 3 tuples; bootstrap #2 of this install will fail.
  local payload
  payload=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh new-a  # ceo:new-a
0 10 * * * /tmp/ceo-cron.sh new-b  # ceo:new-b
0 11 * * * /tmp/ceo-cron.sh new-c  # ceo:new-c
BLOCK
)
  local rc=0
  ceo_scheduler_install "$payload" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "bootstrap failure mid-loop must propagate as rc=1"
  # Rolled back: none of the new plists remain on disk.
  for label in new-a new-b new-c; do
    if [ -f "$CEO_LAUNCHD_DIR/com.ceo.$label-0.plist" ]; then
      assert_eq "$label rolled back" "true" "v2: $label plist must be removed on rollback"
    fi
    if [ -f "$CEO_LAUNCHD_DIR/com.ceo.$label-0.plist.tmp" ]; then
      assert_eq "$label tmp cleaned" "true" "v2: $label .tmp must be cleaned on rollback"
    fi
  done
}

test_launchd_install_does_not_touch_unrelated_plists() {
  export CEO_SCHEDULER=launchd
  # Pre-seed an unrelated plist (not com.ceo.*) — must survive install.
  cat > "$CEO_LAUNCHD_DIR/com.example.other.plist" <<'XML'
<?xml version="1.0"?>
<plist><dict><key>Label</key><string>com.example.other</string></dict></plist>
XML
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.example.other.plist" "non-ceo plists must not be touched"
}

# === launchd: list reconstructs cron-style lines ===

test_launchd_list_reconstructs_cron_lines_for_doctor() {
  export CEO_SCHEDULER=launchd
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh morning  # ceo:morning" >/dev/null 2>&1
  local out
  out=$(ceo_scheduler_list 2>&1)
  assert_contains "$out" "ceo-cron.sh" "list output must contain ceo-cron.sh (doctor greps for this)"
  assert_contains "$out" "# ceo:morning" "list output must carry the ceo:NAME tag"
}

# === Integration: ceo playbook scan end-to-end on launchd ===

test_playbook_scan_writes_plists_via_launchd_backend() {
  export CEO_SCHEDULER=launchd
  cat > "$CEO_DIR/registry.json" <<'EOF'
{"schema_version": 3, "generated": "1970-01-01T00:00:00Z", "playbooks": []}
EOF
  # Point CEO_REPO_PLAYBOOK_DIR at an empty dir so scan reads ONLY the test
  # fixture (otherwise it discovers the real plugin's docs/playbooks/ and the
  # test becomes order-dependent on whatever's registered there).
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"
  cat > "$CEO_DIR/playbooks/scan-target.md" <<'EOF'
---
name: scan-target
description: Integration test playbook for launchd backend
trigger: cron
schedule: "0 9 * * *"
status: active
runner: script
script: noop.sh
---
EOF
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "playbook scan must succeed on launchd backend"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.scan-target-0.plist" "scan must write the plist"
}

run_tests
