#!/bin/bash
# Tests for the schedule override + collision detection layer added in 0.9.0.
# Exercises:
#   - _playbook_apply_schedule_overrides (frontmatter default vs schedules.json override)
#   - collision detection in _playbook_update_crontab
#   - _validate_cron_expr
#   - _schedule_source resolution
# Does NOT exercise the interactive prompt branch of _schedule_one (read -r).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

# Source the helpers from `ceo` via the CEO_LIB_ONLY guard, which skips the
# dispatch table at the bottom of the file. Required because `ceo`'s dispatch
# would otherwise fire on source.
#
# `ceo` sources `ceo-config.sh` which enables `set -euo pipefail`. After
# sourcing, we explicitly drop `-e` so test helpers that intentionally return
# non-zero (collision detection, invalid input) don't abort the test runner.
_load_ceo_helpers() {
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}

setup() {
  TMP=$(mktemp -d)
  export CEO_DIR="$TMP/CEO"
  mkdir -p "$CEO_DIR"
  REGISTRY='{
    "schema_version": 1,
    "playbooks": [
      {"name": "morning-scan",  "trigger": "cron", "schedule": "57 8 * * 1-5", "status": "active"},
      {"name": "morning-brief", "trigger": "cron", "schedule": "57 8 * * 1-5", "status": "active"},
      {"name": "pr-triage",     "trigger": "cron", "schedule": "3 10 * * 1-5", "status": "active"},
      {"name": "inbox",         "trigger": "chat", "schedule": "",             "status": "active"}
    ]
  }'
}

teardown() {
  rm -rf "$TMP"
  unset CEO_DIR
}

# --- Tests ---

test_no_overrides_file_returns_unchanged_registry() {
  out=$(_playbook_apply_schedule_overrides "$REGISTRY")
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "57 8 * * 1-5" "frontmatter schedule preserved when no overrides"
}

test_override_replaces_frontmatter() {
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY")
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "50 8 * * 1-5" "override replaces frontmatter"
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-brief") | .schedule')" \
    "57 8 * * 1-5" "non-overridden playbook keeps frontmatter"
}

test_unknown_playbook_in_overrides_warns_and_ignored() {
  echo '{"nonexistent-playbook": "0 0 * * *"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1 >/dev/null)
  assert_contains "$out" "unknown playbook" "must warn on unknown playbook name (enum-config-typo-fallback)"
  assert_contains "$out" "nonexistent-playbook" "must name the offending key"
}

test_invalid_cron_expr_warns_and_ignored() {
  echo '{"morning-scan": "not a cron expression"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1)
  registry_only=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>/dev/null)
  assert_contains "$out" "invalid cron expression" "must warn on bad cron expr"
  # Schedule should fall back to frontmatter
  assert_eq "$(echo "$registry_only" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "57 8 * * 1-5" "schedule falls back to frontmatter when override is invalid"
}

test_malformed_overrides_json_warns_and_ignored() {
  echo '{not json' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1 >/dev/null)
  assert_contains "$out" "not valid JSON" "must warn on malformed override file"
}

test_validate_cron_expr_accepts_valid_forms() {
  for expr in "0 0 * * *" "57 8 * * 1-5" "*/5 * * * *" "0 9,13,17 * * 1-5"; do
    if ! _validate_cron_expr "$expr" >/dev/null 2>&1; then
      printf '  FAIL [%s] valid expr rejected: %q\n' "$CURRENT_TEST" "$expr"
      FAILS=$((FAILS + 1))
    fi
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  done
}

test_validate_cron_expr_rejects_bad_forms() {
  for expr in "0 0 * *" "0 0 * * * *" "abc def ghi jkl mno" ""; do
    if _validate_cron_expr "$expr" >/dev/null 2>&1; then
      printf '  FAIL [%s] invalid expr accepted: %q\n' "$CURRENT_TEST" "$expr"
      FAILS=$((FAILS + 1))
    fi
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  done
}

test_collision_detection_blocks_crontab_write() {
  # Default REGISTRY has morning-scan and morning-brief at the same schedule.
  # _playbook_update_crontab should refuse to write.
  # shellcheck disable=SC2034
  CEO_CRON="/tmp/fake-cron.sh"
  out=$(_playbook_update_crontab "$REGISTRY" 2>&1)
  rc=$?
  assert_eq "$rc" "1" "collision must produce non-zero rc"
  assert_contains "$out" "collision" "must mention collision in error"
  assert_contains "$out" "morning-scan" "must name first colliding playbook"
  assert_contains "$out" "morning-brief" "must name second colliding playbook"
}

test_collision_resolved_after_override() {
  # shellcheck disable=SC2034
  CEO_CRON="/tmp/fake-cron.sh"
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  merged=$(_playbook_apply_schedule_overrides "$REGISTRY")
  # Use a fake crontab binary via CEO_CRONTAB_BIN so we exercise the real
  # write path. Function-overrides in subshells aren't reliable (functions
  # don't auto-export across $() boundaries).
  local capture="$TMP/crontab-capture.out"
  cat > "$TMP/fake-crontab" <<EOF
#!/bin/bash
cat > "$capture"
EOF
  chmod +x "$TMP/fake-crontab"
  out=$(CEO_CRONTAB_BIN="$TMP/fake-crontab" _playbook_update_crontab "$merged" 2>&1)
  rc=$?
  assert_eq "$rc" "0" "no collision → rc 0"
  assert_no_match "$out" "collision" "no collision message after override"
  assert_contains "$out" "Crontab:" "must reach 'installed' message"
  assert_contains "$(cat "$capture" 2>/dev/null)" "ceo:morning-scan" "fake crontab received the install"
}

test_crontab_install_failure_returns_nonzero() {
  # Fake crontab that simulates a real failure (locked spool, quota, etc).
  cat > "$TMP/failing-crontab" <<'EOF'
#!/bin/bash
echo "crontab: install failed (simulated)" >&2
exit 1
EOF
  chmod +x "$TMP/failing-crontab"
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  merged=$(_playbook_apply_schedule_overrides "$REGISTRY")
  out=$(CEO_CRONTAB_BIN="$TMP/failing-crontab" _playbook_update_crontab "$merged" 2>&1)
  rc=$?
  assert_eq "$rc" "1" "crontab failure must propagate as rc=1"
  assert_contains "$out" "crontab install failed" "must surface failure to caller"
  assert_no_match "$out" "Crontab:.*installed" "must NOT print success message on failure"
}

test_validate_cron_inside_schedule_one_blocks_bad_input() {
  # Build a real registry so _schedule_one sees a known playbook.
  echo "$REGISTRY" | jq '.' > "$CEO_DIR/registry.json"
  # Drive _schedule_one with a deliberately invalid expression on stdin.
  out=$(_schedule_one "morning-scan" "$CEO_DIR/registry.json" "$CEO_DIR/schedules.json" <<< "bogus expr" 2>&1)
  rc=$?
  assert_eq "$rc" "1" "invalid cron must reject"
  assert_contains "$out" "invalid" "must surface validation error"
  # schedules.json must NOT have been written
  if [ -f "$CEO_DIR/schedules.json" ]; then
    written=$(jq -r '."morning-scan" // ""' "$CEO_DIR/schedules.json")
    assert_eq "$written" "" "schedules.json must not contain rejected value"
  fi
}

test_schedule_source_returns_frontmatter_when_no_overrides() {
  src=$(_schedule_source "morning-scan")
  assert_eq "$src" "frontmatter" "no overrides file → frontmatter"
}

test_schedule_source_returns_override_when_present() {
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  src=$(_schedule_source "morning-scan")
  assert_eq "$src" "override" "override present → override"
  src2=$(_schedule_source "morning-brief")
  assert_eq "$src2" "frontmatter" "playbook not in overrides → frontmatter"
}

# --- Run all tests ---

_load_ceo_helpers

run_tests
