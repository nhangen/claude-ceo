#!/bin/bash
# Self-contained test harness for `ceo doctor`'s completed-but-no-output
# cross-check (#88, #89). Stubs out the deps cmd_doctor probes (gh/claude/yq
# presence, vault marker, ssh key, crontab, plugin) so the artifact check is
# what determines pass/fail rather than the surrounding environment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_BIN="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  PATH_BACKUP="$PATH"
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR/log" "$CEO_DIR/reports/value-tracker" "$CEO_DIR/reports/token"
  : > "$CEO_DIR/AGENTS.md"

  # Stub the binaries cmd_doctor probes so the surrounding checks don't
  # dominate the result. They only need to satisfy `command -v` and any
  # subcommand the doctor invokes; failures here are not what's under test.
  mkdir -p "$TEST_HOME/stubs"
  for tool in gh claude yq syncthing crontab jq; do
    cat > "$TEST_HOME/stubs/$tool" << STUB
#!/bin/bash
case "\$1" in
  auth) [ "\$2" = "status" ] && exit 0 ;;
  --version) echo "stub $tool 0.0" ;;
  -l) ;;
  plugin) [ "\$2" = "list" ] && echo "ceo (stub)" && exit 0 ;;
esac
exit 0
STUB
    chmod +x "$TEST_HOME/stubs/$tool"
  done

  # jq is needed for real registry parsing — pass through to the system jq.
  rm -f "$TEST_HOME/stubs/jq"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"

  # Minimal registry with one runner:script playbook + artifact template.
  cat > "$CEO_DIR/registry.json" << EOF
{
  "schema_version": 3,
  "generated": "2026-05-28T00:00:00Z",
  "playbooks": [
    {
      "name": "value-tracker",
      "runner": "script",
      "status": "active",
      "artifact": "CEO/reports/value-tracker/{TODAY}.md"
    }
  ]
}
EOF
}

teardown() {
  rm -rf "$TEST_HOME"
  export PATH="$PATH_BACKUP"
  export HOME="$HOME_BACKUP"
  unset TEST_HOME PATH_BACKUP HOME_BACKUP CEO_VAULT CEO_DIR CEO_HOSTNAME
}

_log_completed_today() {
  local name="$1"
  printf '%s: %s completed\n' "$(date)" "$name" >> "$CEO_DIR/log/cron-runs.log"
}

test_doctor_flags_completed_but_missing_artifact() {
  _log_completed_today value-tracker
  # No artifact written.
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "value-tracker" "doctor output must name the offending playbook"
  assert_contains "$output" "artifact missing or empty" "doctor must surface the missing-artifact reason"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero when an artifact is missing (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_passes_when_artifact_present() {
  _log_completed_today value-tracker
  local today
  today=$(date +%Y-%m-%d)
  printf '# stub note\n' > "$CEO_DIR/reports/value-tracker/$today.md"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "Playbook artifacts present" "doctor must report the artifact check passing"
  if echo "$output" | grep -qF "artifact missing"; then
    printf '  FAIL [%s] doctor must NOT flag when artifact is present\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_skips_when_playbook_not_completed_today() {
  # No cron-runs.log entry for value-tracker today. The check should be a
  # no-op — not a failure (the playbook hasn't run yet, that's not a bug).
  : > "$CEO_DIR/log/cron-runs.log"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  if echo "$output" | grep -qF "artifact missing"; then
    printf '  FAIL [%s] doctor must NOT flag a playbook that did not run today\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_flags_malformed_artifact_template() {
  # Per panel H5: the `ceo_artifact_expand` failure branch in cmd_doctor (the
  # "malformed artifact template ... unknown token" path) had no end-to-end
  # coverage before this test. Seed a registry with a {BOGUS} token + a
  # completed log line and assert doctor surfaces the error and returns
  # non-zero.
  cat > "$CEO_DIR/registry.json" << EOF
{
  "schema_version": 3,
  "generated": "2026-05-28T00:00:00Z",
  "playbooks": [
    {
      "name": "bogus-token",
      "runner": "script",
      "status": "active",
      "artifact": "CEO/reports/bogus-token/{BOGUS}-{TODAY}.md"
    }
  ]
}
EOF
  _log_completed_today bogus-token
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "malformed artifact template" "doctor must name the malformed-template failure"
  assert_contains "$output" "bogus-token" "doctor must name the offending playbook"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on malformed artifact template\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_warns_when_cron_log_missing() {
  # Per panel H3: the cross-check used to silently skip when its preconditions
  # weren't met. The registry exists from setup() and jq is on PATH, but we
  # leave cron-runs.log absent — the cross-check must emit a WARN naming the
  # missing log file, not silently skip.
  rm -f "$CEO_DIR/log/cron-runs.log"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "doctor artifact cross-check skipped" "doctor must surface skip-reason when log absent"
  assert_contains "$output" "cron-runs.log not found" "skip message must name the missing log"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_skips_empty_artifact_field() {
  # Playbook with no artifact declared must not be checked.
  cat > "$CEO_DIR/registry.json" << EOF
{
  "schema_version": 3,
  "generated": "2026-05-28T00:00:00Z",
  "playbooks": [
    {
      "name": "no-artifact",
      "runner": "script",
      "status": "active",
      "artifact": ""
    }
  ]
}
EOF
  _log_completed_today no-artifact
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  if echo "$output" | grep -qF "artifact missing"; then
    printf '  FAIL [%s] doctor must not check playbooks without an artifact template\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
