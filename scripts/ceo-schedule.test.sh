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

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

assert_no_match() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    forbidden in haystack: %q\n' "$CURRENT_TEST" "$msg" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

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
  # shellcheck disable=SC1091
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
  CURRENT_TEST="no_overrides_file_returns_unchanged"
  setup
  out=$(_playbook_apply_schedule_overrides "$REGISTRY")
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "57 8 * * 1-5" "frontmatter schedule preserved when no overrides"
  teardown
}

test_override_replaces_frontmatter() {
  CURRENT_TEST="override_replaces_frontmatter"
  setup
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY")
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "50 8 * * 1-5" "override replaces frontmatter"
  assert_eq "$(echo "$out" | jq -r '.playbooks[] | select(.name=="morning-brief") | .schedule')" \
    "57 8 * * 1-5" "non-overridden playbook keeps frontmatter"
  teardown
}

test_unknown_playbook_in_overrides_warns_and_ignored() {
  CURRENT_TEST="unknown_playbook_warns"
  setup
  echo '{"nonexistent-playbook": "0 0 * * *"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1 >/dev/null)
  assert_contains "$out" "unknown playbook" "must warn on unknown playbook name (enum-config-typo-fallback)"
  assert_contains "$out" "nonexistent-playbook" "must name the offending key"
  teardown
}

test_invalid_cron_expr_warns_and_ignored() {
  CURRENT_TEST="invalid_cron_expr_warns"
  setup
  echo '{"morning-scan": "not a cron expression"}' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1)
  registry_only=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>/dev/null)
  assert_contains "$out" "invalid cron expression" "must warn on bad cron expr"
  # Schedule should fall back to frontmatter
  assert_eq "$(echo "$registry_only" | jq -r '.playbooks[] | select(.name=="morning-scan") | .schedule')" \
    "57 8 * * 1-5" "schedule falls back to frontmatter when override is invalid"
  teardown
}

test_malformed_overrides_json_warns_and_ignored() {
  CURRENT_TEST="malformed_overrides_json"
  setup
  echo '{not json' > "$CEO_DIR/schedules.json"
  out=$(_playbook_apply_schedule_overrides "$REGISTRY" 2>&1 >/dev/null)
  assert_contains "$out" "not valid JSON" "must warn on malformed override file"
  teardown
}

test_validate_cron_expr_accepts_valid_forms() {
  CURRENT_TEST="validate_cron_accepts_valid"
  setup
  for expr in "0 0 * * *" "57 8 * * 1-5" "*/5 * * * *" "0 9,13,17 * * 1-5"; do
    if ! _validate_cron_expr "$expr" >/dev/null 2>&1; then
      printf '  FAIL [%s] valid expr rejected: %q\n' "$CURRENT_TEST" "$expr"
      FAILS=$((FAILS + 1))
    fi
  done
  teardown
}

test_validate_cron_expr_rejects_bad_forms() {
  CURRENT_TEST="validate_cron_rejects_bad"
  setup
  for expr in "0 0 * *" "0 0 * * * *" "abc def ghi jkl mno" ""; do
    if _validate_cron_expr "$expr" >/dev/null 2>&1; then
      printf '  FAIL [%s] invalid expr accepted: %q\n' "$CURRENT_TEST" "$expr"
      FAILS=$((FAILS + 1))
    fi
  done
  teardown
}

test_collision_detection_blocks_crontab_write() {
  CURRENT_TEST="collision_blocks_crontab"
  setup
  # Default REGISTRY has morning-scan and morning-brief at the same schedule.
  # _playbook_update_crontab should refuse to write.
  CEO_CRON="/tmp/fake-cron.sh"
  out=$(_playbook_update_crontab "$REGISTRY" 2>&1)
  rc=$?
  assert_eq "$rc" "1" "collision must produce non-zero rc"
  assert_contains "$out" "collision" "must mention collision in error"
  assert_contains "$out" "morning-scan" "must name first colliding playbook"
  assert_contains "$out" "morning-brief" "must name second colliding playbook"
  teardown
}

test_collision_resolved_after_override() {
  CURRENT_TEST="collision_resolved_after_override"
  setup
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
  teardown
}

test_crontab_install_failure_returns_nonzero() {
  CURRENT_TEST="crontab_install_failure_returns_nonzero"
  setup
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
  teardown
}

test_validate_cron_inside_schedule_one_blocks_bad_input() {
  CURRENT_TEST="validate_cron_inside_schedule_one_blocks_bad_input"
  setup
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
  teardown
}

test_schedule_source_returns_frontmatter_when_no_overrides() {
  CURRENT_TEST="source_frontmatter_no_overrides"
  setup
  src=$(_schedule_source "morning-scan")
  assert_eq "$src" "frontmatter" "no overrides file → frontmatter"
  teardown
}

test_schedule_source_returns_override_when_present() {
  CURRENT_TEST="source_override_when_present"
  setup
  echo '{"morning-scan": "50 8 * * 1-5"}' > "$CEO_DIR/schedules.json"
  src=$(_schedule_source "morning-scan")
  assert_eq "$src" "override" "override present → override"
  src2=$(_schedule_source "morning-brief")
  assert_eq "$src2" "frontmatter" "playbook not in overrides → frontmatter"
  teardown
}

# --- Run all tests ---

_load_ceo_helpers

TESTS=(
  test_no_overrides_file_returns_unchanged_registry
  test_override_replaces_frontmatter
  test_unknown_playbook_in_overrides_warns_and_ignored
  test_invalid_cron_expr_warns_and_ignored
  test_malformed_overrides_json_warns_and_ignored
  test_validate_cron_expr_accepts_valid_forms
  test_validate_cron_expr_rejects_bad_forms
  test_collision_detection_blocks_crontab_write
  test_collision_resolved_after_override
  test_crontab_install_failure_returns_nonzero
  test_validate_cron_inside_schedule_one_blocks_bad_input
  test_schedule_source_returns_frontmatter_when_no_overrides
  test_schedule_source_returns_override_when_present
)

for t in "${TESTS[@]}"; do
  "$t"
done

if [ "$FAILS" -eq 0 ]; then
  echo "All tests passed. (${#TESTS[@]} tests)"
  exit 0
else
  echo "$FAILS test(s) failed."
  exit 1
fi
