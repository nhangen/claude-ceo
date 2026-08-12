#!/bin/bash
# Self-contained test harness for ceo-token-intake.sh — verifies the report
# write, idempotency, and write-failure invariants the script claims.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTAKE="$SCRIPT_DIR/ceo-token-intake.sh"

source "$SCRIPT_DIR/test-harness.sh"

# write_token_scope_stub <credits-json> <supports-credits: yes|no>
# Rebuilds the token-scope stub. The JSON is what `--credits --json` returns;
# "no" makes --help omit --credits, simulating a plugin cache older than the
# report (the case that must NOT redden cron).
write_token_scope_stub() {
  local json="$1" supports="$2"
  mkdir -p "$TEST_HOME/.bun/bin"
  {
    printf '#!/bin/bash\n'
    printf 'set -u\n'
    printf 'CREDITS_JSON=%q\n' "$json"
    printf 'SUPPORTS=%q\n' "$supports"
    cat << 'STUB'
case "$1" in
  --help)
    echo "token-scope — stub"
    echo "  --since <duration>"
    [ "$SUPPORTS" = "yes" ] && echo "  --credits               weekly credit consumption vs plan cap"
    exit 0 ;;
  --version) echo "token-scope 9.9.9-stub"; exit 0 ;;
  --credits)
    if [ "$SUPPORTS" != "yes" ]; then
      echo "unknown flag: --credits" >&2; exit 1
    fi
    for a in "$@"; do [ "$a" = "--json" ] && { printf '%s\n' "$CREDITS_JSON"; exit 0; }; done
    echo "token-scope-stub: credits table"; exit 0 ;;
  --since)
    echo "token-scope-stub: $*"; exit 0 ;;
esac
echo "token-scope-stub: unexpected argv: $*" >&2
exit 2
STUB
  } > "$TEST_HOME/.bun/bin/token-scope"
  chmod +x "$TEST_HOME/.bun/bin/token-scope"
}

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR/reports/token"

  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/rtk" << 'STUB'
#!/bin/bash
echo "rtk-stub: $*"
STUB
  # token-scope stub: pattern-matches argv and exits non-zero on an unexpected
  # shape (stub-cli-argv-validation). An echo-everything stub would have hidden
  # the --credits probe entirely, and the script's behaviour now depends on it.
  # Per-test overrides go through write_token_scope_stub below.
  write_token_scope_stub '{"meta":{"weekly_cap":166700000},"weeks":[{"weekStart":"2026-08-10","partial":true,"credits":50000000,"capRatio":0.3,"projectedCapRatio":0.6}]}' "yes"
  cat > "$TEST_HOME/.bun/bin/npx" << 'STUB'
#!/bin/bash
echo "npx-stub: $*"
STUB
  chmod +x "$TEST_HOME/.bun/bin/rtk" "$TEST_HOME/.bun/bin/npx"

  # Stage a getent stub so ceo_pin_home_or_warn (via ceo_resolve_real_home)
  # resolves to $TEST_HOME instead of the developer's real ~/. Without this,
  # the script's HOME re-export would point PATH augmentation at the user's
  # actual ~/.bun/bin and bypass the test stubs above.
  local user
  user=$(id -un)
  mkdir -p "$TEST_HOME/stubs"
  cat > "$TEST_HOME/stubs/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$TEST_HOME"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_HOME/stubs/getent"
  export PATH="$TEST_HOME/stubs:$TEST_HOME/.bun/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
}

test_creates_host_suffixed_report_and_appends_per_host_inbox_line() {
  bash "$INTAKE" >/dev/null 2>&1
  local today report inbox
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  assert_file_exists "$report" "report path must include hostname suffix"
  assert_file_exists "$inbox" "per-host inbox shadow file must be created"
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "per-host inbox must contain wikilink to host-suffixed report"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_does_not_write_to_shared_inbox_md() {
  bash "$INTAKE" >/dev/null 2>&1
  if [ -f "$CEO_DIR/inbox.md" ] && [ -s "$CEO_DIR/inbox.md" ]; then
    printf '  FAIL [%s] writer must not touch shared CEO/inbox.md\n    contents: %q\n' \
      "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox.md")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_idempotent_same_day() {
  bash "$INTAKE" >/dev/null 2>&1
  bash "$INTAKE" >/dev/null 2>&1
  local today inbox count
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "two runs must leave exactly one inbox line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_does_not_re_append_after_inbox_checkoff() {
  bash "$INTAKE" >/dev/null 2>&1
  local today inbox
  today=$(date +%Y-%m-%d)
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  sed -i.bak "s|^- \[ \]|- [x]|" "$inbox"
  rm -f "$inbox.bak"

  bash "$INTAKE" >/dev/null 2>&1
  local count
  count=$(grep -c -F "[[CEO/reports/token/$today-$CEO_HOSTNAME]]" "$inbox")
  assert_eq "$count" "1" "checked-off line must not trigger re-append"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_two_hosts_write_disjoint_files() {
  CEO_HOSTNAME="alpha" bash "$INTAKE" >/dev/null 2>&1
  CEO_HOSTNAME="beta"  bash "$INTAKE" >/dev/null 2>&1
  local today
  today=$(date +%Y-%m-%d)
  assert_file_exists "$CEO_DIR/reports/token/$today-alpha.md" "alpha report"
  assert_file_exists "$CEO_DIR/reports/token/$today-beta.md"  "beta report"
  assert_file_exists "$CEO_DIR/inbox/alpha.md" "alpha inbox shadow"
  assert_file_exists "$CEO_DIR/inbox/beta.md"  "beta inbox shadow"
  if [ -f "$CEO_DIR/inbox/beta.md" ] && grep -qF "alpha" "$CEO_DIR/inbox/beta.md"; then
    printf '  FAIL [%s] beta inbox shadow must not reference alpha\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_invokes_ceo_augment_path() {
  # Keep the getent stub on PATH so ceo_pin_home_or_warn resolves to
  # $TEST_HOME instead of the developer's real ~/. Without it, dscl on Mac
  # would return the real user's home and PATH augmentation would prefer the
  # real ~/.bun/bin/rtk over the test stub.
  PATH="$TEST_HOME/stubs:/usr/bin:/bin" bash "$INTAKE" >/dev/null 2>&1
  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  assert_file_exists "$report" "report file must exist"
  body=$(cat "$report")
  assert_contains "$body" "rtk-stub:" "report must contain stub rtk output (proves ceo_augment_path resolved \$HOME/.bun/bin)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pins_home_to_resolved_user_home_before_capture() {
  local pinned="$TEST_HOME/pinned-home"
  mkdir -p "$pinned/.bun/bin"
  cat > "$pinned/.bun/bin/rtk" << 'STUB'
#!/bin/bash
echo "rtk-saw-HOME=$HOME"
STUB
  chmod +x "$pinned/.bun/bin/rtk"
  cp "$TEST_HOME/.bun/bin/token-scope" "$pinned/.bun/bin/token-scope"

  local stub_dir="$TEST_HOME/stubs" user
  mkdir -p "$stub_dir"
  user=$(id -un)
  cat > "$stub_dir/getent" << EOF
#!/bin/bash
if [ "\$1" = "passwd" ] && [ "\$2" = "$user" ]; then
  printf '%s:x:0:0::%s:/bin/bash\n' "$user" "$pinned"
  exit 0
fi
exit 1
EOF
  chmod +x "$stub_dir/getent"

  local sandbox="$TEST_HOME/scrubbed"
  mkdir -p "$sandbox"
  HOME="$sandbox" PATH="$stub_dir:$TEST_HOME/.bun/bin:/usr/bin:/bin" \
    bash "$INTAKE" >/dev/null 2>&1

  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  if [ ! -f "$report" ]; then
    printf '  FAIL [%s] report missing at %q\n' "$CURRENT_TEST" "$report"
    FAILS=$((FAILS + 1)); return
  fi
  body=$(cat "$report")
  assert_contains "$body" "rtk-saw-HOME=$pinned" \
    "rtk must see HOME=$pinned (resolver target), not the sandbox HOME the caller passed"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_exits_nonzero_when_capture_command_missing() {
  rm -f "$TEST_HOME/.bun/bin/token-scope"
  local rc=0
  # Pin PATH to the test stub dirs only. Inheriting the real $PATH lets an
  # ambient ~/.bun/bin/token-scope satisfy `command -v` and defeat the
  # missing-binary scenario this test exists to exercise.
  PATH="$TEST_HOME/stubs:$TEST_HOME/.bun/bin:/usr/bin:/bin" \
    bash "$INTAKE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero when a capture binary is missing\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$CEO_DIR/inbox/$CEO_HOSTNAME.md" ] && grep -qF "[[CEO/reports/token/" "$CEO_DIR/inbox/$CEO_HOSTNAME.md"; then
    printf '  FAIL [%s] inbox must NOT have a line when capture failed\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  local today report
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  if [ -f "$report" ] && ! grep -qF "unavailable on PATH=" "$report"; then
    printf '  FAIL [%s] report must record the missing-binary sentinel for forensics\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_exits_nonzero_when_capture_command_fails() {
  cat > "$TEST_HOME/.bun/bin/rtk" << 'STUB'
#!/bin/bash
echo "boom: simulated failure" >&2
exit 7
STUB
  chmod +x "$TEST_HOME/.bun/bin/rtk"
  local rc=0
  bash "$INTAKE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero when a capture command exits non-zero\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$CEO_DIR/inbox/$CEO_HOSTNAME.md" ] && grep -qF "[[CEO/reports/token/" "$CEO_DIR/inbox/$CEO_HOSTNAME.md"; then
    printf '  FAIL [%s] inbox must NOT have a line when capture failed\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_augment_path_branches_per_os() {
  # shellcheck source=ceo-config.sh
  source "$SCRIPT_DIR/ceo-config.sh"
  local got
  unset _CEO_PATH_AUGMENTED
  PATH="/usr/bin:/bin"
  ceo_detect_os() { echo "wsl"; }
  ceo_augment_path
  got="$PATH"
  if [[ "$got" == *"/opt/homebrew/bin"* ]]; then
    printf '  FAIL [%s] wsl branch must NOT prepend /opt/homebrew/bin\n    got: %q\n' "$CURRENT_TEST" "$got"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$got" "$HOME/.bun/bin" "wsl branch must include \$HOME/.bun/bin"
  assert_contains "$got" "$HOME/.local/bin" "wsl branch must include \$HOME/.local/bin"

  unset _CEO_PATH_AUGMENTED
  PATH="/usr/bin:/bin"
  ceo_detect_os() { echo "macos"; }
  ceo_augment_path
  got="$PATH"
  assert_contains "$got" "/opt/homebrew/bin" "macos branch must include /opt/homebrew/bin"
  assert_contains "$got" "$HOME/.bun/bin" "macos branch must include \$HOME/.bun/bin"
  unset _CEO_PATH_AUGMENTED
  unset -f ceo_detect_os
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_aborts_on_unwritable_report_dir() {
  if [ "$(id -u)" = "0" ]; then
    return 0
  fi
  chmod 0500 "$CEO_DIR/reports/token"
  local rc=0
  bash "$INTAKE" >/dev/null 2>&1 || rc=$?
  chmod 0700 "$CEO_DIR/reports/token"
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] script must exit non-zero on unwritable report dir (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$CEO_DIR/inbox/$CEO_HOSTNAME.md" ] && grep -qF "[[CEO/reports/token/" "$CEO_DIR/inbox/$CEO_HOSTNAME.md"; then
    printf '  FAIL [%s] per-host inbox must NOT have an inbox line when the report write failed\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_prefers_plugin_cache_over_path_for_token_scope() {
  # Stage a plugin-cache token-scope that announces itself, plus a stub `bun`
  # runtime that just exec's the script it's handed. The PATH-level
  # token-scope from setup() should be ignored when the cache resolves.
  local cache="$TEST_HOME/.claude/plugins/cache/nhangen-tools/token-scope/1.3.1/src"
  mkdir -p "$cache"
  cat > "$cache/cli.ts" << STUB
#!/bin/bash
echo "token-scope-from-cache: \$*"
STUB
  chmod +x "$cache/cli.ts"

  # Stub bun must receive the absolute cache path as \$1 — that's how the
  # caller proves it actually used the resolver's runtime+path pair, not
  # an accidental "bash cli.ts" fallback. A regression that drops
  # \$_ts_runtime from TS_CMD would invoke the .ts directly and miss this.
  local expected_entry="$cache/cli.ts"
  cat > "$TEST_HOME/.bun/bin/bun" << STUB
#!/bin/bash
if [ "\$1" != "$expected_entry" ]; then
  echo "bun-stub-WRONG-ARG: expected '$expected_entry', got '\$1'" >&2
  exit 2
fi
exec bash "\$@"
STUB
  chmod +x "$TEST_HOME/.bun/bin/bun"

  # Make the PATH stub trip a sentinel so a regression that falls through to
  # PATH lights up as a failed assertion below.
  cat > "$TEST_HOME/.bun/bin/token-scope" << 'STUB'
#!/bin/bash
echo "token-scope-from-PATH-WRONG: $*"
STUB
  chmod +x "$TEST_HOME/.bun/bin/token-scope"

  bash "$INTAKE" >/dev/null 2>&1
  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  assert_file_exists "$report" "report must be written"
  body=$(cat "$report")
  assert_contains "$body" "token-scope-from-cache:" \
    "intake must invoke the cache-resolved token-scope, not the PATH stub"
  if [[ "$body" == *"token-scope-from-PATH-WRONG"* ]]; then
    printf '  FAIL [%s] cache resolver was bypassed; PATH stub ran instead\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$body" == *"bun-stub-WRONG-ARG"* ]]; then
    printf '  FAIL [%s] bun stub received wrong entry path (runtime+path pair mismatched)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_omits_rtk_current_project_section() {
  bash "$INTAKE" >/dev/null 2>&1
  local today report body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  body=$(cat "$report")
  assert_not_contains "$body" "RTK — current project" \
    "daemon-cwd 'current project' section must be dropped (it logged the scheduler's own dir)"
  assert_contains "$body" "RTK — global savings" "global RTK section must remain"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_auth_health_ok_when_a_successful_turn_exists() {
  # HOME is re-pinned to $TEST_HOME via the getent stub, so stage sessions there.
  local proj="$TEST_HOME/.claude/projects/-some-project"
  mkdir -p "$proj"
  # One genuine successful (token-bearing) turn → host is healthy.
  printf '%s\n' '{"type":"assistant","message":{"usage":{"output_tokens":10}}}' > "$proj/ok.jsonl"
  # A session that merely *mentions* the error string must NOT flip it to WARN —
  # the success signal makes the self-referential false positive impossible.
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"discussing \"error\":\"authentication_failed\" here"}]}}' \
    > "$proj/mention.jsonl"
  bash "$INTAKE" >/dev/null 2>&1
  local today report body inbox inbox_body
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  body=$(cat "$report")
  assert_contains "$body" "## auth health" "report must include an auth health section"
  assert_contains "$body" "OK: host produced successful Claude turns" "a host with a successful turn must read OK"
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  inbox_body=$([ -f "$inbox" ] && cat "$inbox" || echo "")
  assert_not_contains "$inbox_body" "No successful Claude runs" "a healthy host must not raise an alert"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_auth_alert_when_no_successful_turns_dedupes_and_reappears() {
  # A logged-out host writes sessions with zero successful turns; the error-only
  # session also carries the top-level authentication_failed field for enrichment.
  local proj="$TEST_HOME/.claude/projects/-some-project"
  mkdir -p "$proj"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"model":"<synthetic>","usage":{"output_tokens":0},"content":[{"type":"text","text":"Not logged in · Please run /login"}]}}' \
    > "$proj/sess.jsonl"

  bash "$INTAKE" >/dev/null 2>&1
  local today report body inbox count
  today=$(date +%Y-%m-%d)
  report="$CEO_DIR/reports/token/$today-$CEO_HOSTNAME.md"
  body=$(cat "$report")
  assert_contains "$body" "zero successful turns" "report must flag a host that produced nothing"
  assert_contains "$body" "LOGGED OUT" "auth-error field must enrich the message"
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "No successful Claude runs on $CEO_HOSTNAME" "$inbox")
  assert_eq "$count" "1" "broken host must get exactly one inbox alert"

  # Still broken next run → must NOT re-append (dedupe on the unchecked marker).
  bash "$INTAKE" >/dev/null 2>&1
  count=$(grep -c -F "No successful Claude runs on $CEO_HOSTNAME" "$inbox")
  assert_eq "$count" "1" "still-broken host must not spam a second alert"

  # After the alert is checked off, a fresh outage must re-alert (transition).
  sed -i.bak "s|- \[ \] \(.*No successful Claude runs\)|- [x] \1|" "$inbox"; rm -f "$inbox.bak"
  bash "$INTAKE" >/dev/null 2>&1
  count=$(grep -c -F "No successful Claude runs on $CEO_HOSTNAME" "$inbox")
  assert_eq "$count" "2" "outage after a prior check-off must re-alert"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# ─── credit cap escalation ────────────────────────────────────────────────────

test_report_captures_credits_when_supported() {
  bash "$INTAKE" >/dev/null 2>&1
  local report
  report="$CEO_DIR/reports/token/$(date +%Y-%m-%d)-$CEO_HOSTNAME.md"
  assert_contains "$(cat "$report")" "credits vs weekly cap" "report must capture the credits section"
  assert_contains "$(cat "$report")" "credit cap check" "report must record the cap check"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

test_under_cap_does_not_escalate() {
  # Default stub: 0.6x projected. A report that escalated while under the cap
  # would be a signal generator, which is what the disk-monitor incident was.
  bash "$INTAKE" >/dev/null 2>&1
  local inbox count
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "Credit cap" "$inbox" || true)
  assert_eq "$count" "0" "a week under the cap must not escalate"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_over_cap_escalates_once_per_week() {
  write_token_scope_stub '{"meta":{"weekly_cap":166700000},"weeks":[{"weekStart":"2026-08-10","partial":true,"credits":300000000,"capRatio":1.8,"projectedCapRatio":2.4}]}' "yes"
  bash "$INTAKE" >/dev/null 2>&1
  bash "$INTAKE" >/dev/null 2>&1
  local inbox count
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "Credit cap (2026-08-10) on $CEO_HOSTNAME" "$inbox")
  assert_eq "$count" "1" "an over-cap week must escalate exactly once, not once per run"
  assert_contains "$(cat "$inbox")" "2.4x" "the alert must carry the projected ratio"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 2))
}

test_new_over_cap_week_re_alerts() {
  # Keyed on the ISO week, so a fresh week going over IS a state transition.
  write_token_scope_stub '{"meta":{"weekly_cap":166700000},"weeks":[{"weekStart":"2026-08-10","partial":true,"credits":300000000,"capRatio":1.8,"projectedCapRatio":2.4}]}' "yes"
  bash "$INTAKE" >/dev/null 2>&1
  write_token_scope_stub '{"meta":{"weekly_cap":166700000},"weeks":[{"weekStart":"2026-08-17","partial":true,"credits":300000000,"capRatio":1.9,"projectedCapRatio":2.5}]}' "yes"
  bash "$INTAKE" >/dev/null 2>&1
  local inbox count
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  count=$(grep -c -F "Credit cap (" "$inbox")
  assert_eq "$count" "2" "a new week going over cap must re-alert"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ignores_future_dated_week_when_picking_current() {
  # A synced host with a skewed clock can stamp a turn into next week. Reading
  # the last partial row blindly would judge the cap on that phantom week.
  write_token_scope_stub '{"meta":{"weekly_cap":166700000},"weeks":[{"weekStart":"2026-08-10","partial":true,"credits":300000000,"capRatio":1.8,"projectedCapRatio":2.4}]}' "yes"
  bash "$INTAKE" >/dev/null 2>&1
  local report
  report="$CEO_DIR/reports/token/$(date +%Y-%m-%d)-$CEO_HOSTNAME.md"
  assert_contains "$(cat "$report")" "week 2026-08-10" "must name the week it judged"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_stale_plugin_escalates_but_does_not_fail_the_run() {
  # The fix is a /plugin update the user performs. Reddening cron every morning
  # for a whole quarter would train them to ignore the failure channel.
  write_token_scope_stub '{}' "no"
  bash "$INTAKE" >/dev/null 2>&1
  local rc=$?
  assert_eq "$rc" "0" "a token-scope without --credits must not fail the run"
  local inbox
  inbox="$CEO_DIR/inbox/$CEO_HOSTNAME.md"
  assert_contains "$(cat "$inbox")" "Credit cap (stale-plugin)" "stale plugin must escalate as its own item"
  assert_contains "$(cat "$inbox")" "/plugin update" "the alert must name the fix"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 3))
}

test_stale_plugin_skips_the_credits_capture() {
  # capture() records a non-zero exit as a run failure, so the credits capture
  # must not even be attempted against a build that lacks the flag.
  write_token_scope_stub '{}' "no"
  bash "$INTAKE" >/dev/null 2>&1
  local report
  report="$CEO_DIR/reports/token/$(date +%Y-%m-%d)-$CEO_HOSTNAME.md"
  if grep -qF "credits vs weekly cap" "$report"; then
    printf '  FAIL [%s] credits capture must be skipped when unsupported\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
