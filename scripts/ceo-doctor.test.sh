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
  # The generated registry is host-local now ($HOME/.ceo/registry.json), not in
  # the synced vault — doctor reads it from there.
  REGISTRY_FILE="$HOME/.ceo/registry.json"
  mkdir -p "$CEO_DIR/log" "$CEO_DIR/reports/value-tracker" "$CEO_DIR/reports/token" "$HOME/.ceo"
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

  # plutil stub for launchd tests. Real plutil is macOS-only; CI runs on
  # Linux. Uses python3+plistlib to honor the same -extract contract.
  export CEO_PLUTIL_BIN="$TEST_HOME/stubs/plutil"
  cat > "$CEO_PLUTIL_BIN" <<'STUB'
#!/bin/bash
key="$2"
file="${!#}"
[ -f "$file" ] || { echo "stub-plutil: file not found: $file" >&2; exit 1; }
python3 - "$key" "$file" <<'PY'
import plistlib, sys
key, path = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    d = plistlib.load(f)
v = d
for p in key.split("."):
    if p.isdigit():
        try:
            v = v[int(p)]
        except (IndexError, TypeError):
            sys.exit(1)
    else:
        if not isinstance(v, dict) or p not in v:
            sys.exit(1)
        v = v[p]
print(v)
PY
STUB
  chmod +x "$CEO_PLUTIL_BIN"

  # Minimal registry with one runner:script playbook + artifact template.
  cat > "$REGISTRY_FILE" << EOF
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
  unset TEST_HOME PATH_BACKUP HOME_BACKUP CEO_VAULT CEO_DIR CEO_HOSTNAME CEO_PLUTIL_BIN
  unset CEO_SCHEDULER CEO_LAUNCHD_DIR CEO_CRONTAB_BIN CEO_SYSTEMCTL_BIN
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
  cat > "$REGISTRY_FILE" << EOF
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
  cat > "$REGISTRY_FILE" << EOF
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

test_doctor_reports_platform() {
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "Platform:" "doctor must report the detected platform"
  if ! echo "$output" | grep -qE "Platform: (wsl|linux|macos|unknown)"; then
    printf '  FAIL [%s] doctor platform line must name wsl/linux/macos/unknown\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# #144: on the daemon backend (macOS) doctor reports scheduling-via-daemon and
# does NOT print the crontab "Cron entries installed" line (there are none).
test_doctor_reports_daemon_scheduling_on_daemon_backend() {
  export CEO_SCHEDULER=daemon
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "Scheduling via ceo-schedulerd daemon" \
    "doctor must report daemon-managed scheduling on the daemon backend"
  assert_not_contains "$output" "Cron entries installed" \
    "the crontab cron-entries line must be skipped on the daemon backend"
}

# #144 migration: doctor must flag retired per-playbook launchd agents (which
# would double-fire with the daemon) and not flag the daemon's own agent.
test_doctor_flags_legacy_per_playbook_launchd_agents() {
  export CEO_SCHEDULER=daemon
  export CEO_LAUNCHD_DIR="$TEST_HOME/LaunchAgents"
  mkdir -p "$CEO_LAUNCHD_DIR"
  : > "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist"
  : > "$CEO_LAUNCHD_DIR/com.ceo.schedulerd.plist"
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "legacy per-playbook launchd agent" \
    "doctor must warn about retired per-playbook agents"
  assert_contains "$output" "double-fire" "warning must explain the risk"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero when legacy agents are present\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_no_legacy_warning_when_only_daemon_agent() {
  export CEO_SCHEDULER=daemon
  export CEO_LAUNCHD_DIR="$TEST_HOME/LaunchAgents"
  mkdir -p "$CEO_LAUNCHD_DIR"
  : > "$CEO_LAUNCHD_DIR/com.ceo.schedulerd.plist"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_not_contains "$output" "legacy per-playbook launchd agent" \
    "the daemon's own keep-alive agent must not be flagged as legacy"
}

# --- #159 / D1: Linux crontab block is a migration leftover ---
#
# The Linux sibling of the macOS orphan check above. The native crontab install
# path is retired (D1) — ceo-schedulerd is the sole scheduler. A host still
# carrying the Phase-1 per-playbook CEO crontab block alongside the running
# daemon is a MIGRATION LEFTOVER (the block double-fires what the daemon already
# dispatches). doctor must flag the leftover and recommend removing it.

# Writes a CEO_CRONTAB_BIN stub whose `-l` prints $1 (a crontab body) and
# exits non-zero on any other argv (per stub-cli-argv-validation).
_write_crontab_list_stub() {
  local body="$1"
  export CEO_CRONTAB_BIN="$TEST_HOME/stubs/crontab-159"
  cat > "$CEO_CRONTAB_BIN" <<STUB
#!/bin/bash
case "\$1" in
  -l) cat <<'CRON'
$body
CRON
  ;;
  *) echo "stub-crontab: unexpected argv: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$CEO_CRONTAB_BIN"
}

# Writes a CEO_SYSTEMCTL_BIN stub answering `--user is-active ceo-schedulerd`
# with $1 ("active"/"inactive") and the matching exit code; any other argv
# exits 99 (per stub-cli-argv-validation).
_write_systemctl_stub() {
  local state="$1" rc
  [ "$state" = "active" ] && rc=0 || rc=3
  export CEO_SYSTEMCTL_BIN="$TEST_HOME/stubs/systemctl-159"
  cat > "$CEO_SYSTEMCTL_BIN" <<STUB
#!/bin/bash
case "\$*" in
  "--user is-active ceo-schedulerd") echo "$state"; exit $rc ;;
  *) echo "stub-systemctl: unexpected argv: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$CEO_SYSTEMCTL_BIN"
}

test_doctor_flags_crontab_block_as_migration_leftover() {
  export CEO_SCHEDULER=crontab
  _write_crontab_list_stub "# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
0 9 * * * /p/ceo-cron.sh standup  # ceo:standup
# CEO Agent END"
  _write_systemctl_stub active
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "Migration leftover" \
    "doctor must flag a lingering CEO crontab block as a migration leftover"
  assert_contains "$output" "crontab block" \
    "the warning must name the crontab block as the thing to remove"
  assert_contains "$output" "Remove" \
    "the warning must recommend removing the leftover crontab block"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on a lingering crontab block (got rc=0)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_flags_crontab_leftover_even_when_daemon_inactive() {
  export CEO_SCHEDULER=crontab
  _write_crontab_list_stub "# CEO Agent START
*/5 * * * * /p/ceo-cron.sh morning  # ceo:morning
# CEO Agent END"
  _write_systemctl_stub inactive
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "Migration leftover" \
    "a lingering CEO crontab block is a migration leftover regardless of daemon state (blind-spot fix)"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on a lingering crontab block even with the daemon inactive (got rc=0)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_no_leftover_warning_when_no_crontab_block() {
  export CEO_SCHEDULER=crontab
  _write_crontab_list_stub "# unrelated user cron
0 0 * * * /usr/bin/true"
  _write_systemctl_stub active
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_not_contains "$output" "Migration leftover" \
    "an active daemon with no CEO crontab entries has no leftover to flag"
}

# --- ceo-schedulerd liveness (#142) ---

test_doctor_reports_schedulerd_alive_on_fresh_heartbeat() {
  mkdir -p "$HOME/.ceo/schedulerd"
  local now_ms=$(( $(date +%s) * 1000 ))
  printf '{"ts": %s, "host":"testhost","dispatched_minute":{}}\n' "$now_ms" \
    > "$HOME/.ceo/schedulerd/heartbeat.json"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "ceo-schedulerd alive" "doctor must report a fresh heartbeat as alive"
}

test_doctor_flags_stale_schedulerd_heartbeat() {
  mkdir -p "$HOME/.ceo/schedulerd"
  local old_ms=$(( ($(date +%s) - 700) * 1000 ))
  printf '{"ts": %s, "host":"testhost","dispatched_minute":{}}\n' "$old_ms" \
    > "$HOME/.ceo/schedulerd/heartbeat.json"
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "heartbeat stale" "doctor must flag a stale heartbeat"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on stale heartbeat (got rc=0)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_notes_schedulerd_absent_without_failing() {
  rm -rf "$HOME/.ceo/schedulerd"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "ceo-schedulerd not running" "doctor must note an absent daemon"
  assert_not_contains "$output" "heartbeat stale" "absent daemon must not be reported stale"
}

test_doctor_flags_malformed_schedulerd_heartbeat() {
  mkdir -p "$HOME/.ceo/schedulerd"
  printf '{"host":"testhost","dispatched_minute":{}}\n' > "$HOME/.ceo/schedulerd/heartbeat.json"
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "heartbeat malformed" "doctor must flag a heartbeat with no ts"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on malformed heartbeat (got rc=0)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_flags_nonnumeric_schedulerd_ts() {
  mkdir -p "$HOME/.ceo/schedulerd"
  printf '{"ts":"abc","host":"testhost","dispatched_minute":{}}\n' > "$HOME/.ceo/schedulerd/heartbeat.json"
  local output rc=0
  output=$("$CEO_BIN" doctor 2>&1) || rc=$?
  assert_contains "$output" "heartbeat malformed" "doctor must flag a non-numeric ts as malformed, not error on arithmetic"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] doctor must return non-zero on non-numeric ts (got rc=0)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_doctor_clamps_future_schedulerd_heartbeat_to_alive() {
  mkdir -p "$HOME/.ceo/schedulerd"
  # ts in the future (clock skew between hosts) must not read as a negative age
  # nor as stale — clamp to 0 and report alive.
  local future_ms=$(( ($(date +%s) + 700) * 1000 ))
  printf '{"ts": %s, "host":"testhost","dispatched_minute":{}}\n' "$future_ms" \
    > "$HOME/.ceo/schedulerd/heartbeat.json"
  local output
  output=$("$CEO_BIN" doctor 2>&1 || true)
  assert_contains "$output" "ceo-schedulerd alive" "future-dated heartbeat must clamp to alive, not stale"
  assert_not_contains "$output" "(heartbeat -" "future-dated heartbeat age must not be negative"
}

run_tests
