#!/bin/bash
# ceo-cron.sh tests — #173 script playbooks (part 1/2).
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


test_script_outcome_noop_suppresses_success_notify() {
  _write_outcome_playbook outcome-noop noop
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" bash "$CRON" outcome-noop >/dev/null 2>&1 || true
  local log; log=$(cat "$TEST_HOME/notify-debug.log" 2>/dev/null || echo "")
  assert_not_contains "$log" "[success/outcome-noop]" "a noop outcome must suppress the success notify"
  rm -f "$SCRIPT_DIR/outcome-noop-test.sh"
}


test_autopilot_fired_outcome_notifies() {
  # ticket-triage-autopilot is in the blanket hardcode today; a "fired" tick
  # (real merges → tickets) must still ping once the outcome gate replaces it.
  _write_outcome_playbook ticket-triage-autopilot fired
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" bash "$CRON" ticket-triage-autopilot >/dev/null 2>&1 || true
  local log; log=$(cat "$TEST_HOME/notify-debug.log" 2>/dev/null || echo "")
  assert_contains "$log" "[success/ticket-triage-autopilot]" "a fired autopilot tick must send the success notify"
  rm -f "$SCRIPT_DIR/ticket-triage-autopilot-test.sh"
}


test_script_without_outcome_keeps_default_notify() {
  # A plain script that writes no outcome preserves the prior behavior: notify.
  _write_outcome_playbook outcome-default ""
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" bash "$CRON" outcome-default >/dev/null 2>&1 || true
  local log; log=$(cat "$TEST_HOME/notify-debug.log" 2>/dev/null || echo "")
  assert_contains "$log" "[success/outcome-default]" "a script writing no outcome must still notify (default preserved)"
  rm -f "$SCRIPT_DIR/outcome-default-test.sh"
}


# A test body that aborts skips its own trailing `rm -f`, so the cleanup that
# matters is teardown's. These arms are self-contained on purpose: an earlier
# version registered in one arm and asserted in the next, which relied on
# declare -F's alphabetical ordering — renaming the producer, or running under
# TEST_FILTER, left the check passing while testing nothing.
#
# Each arm registers, then calls teardown itself and asserts the sweep. It does
# not call setup afterwards: the body is a backgrounded subshell, so a setup
# there never reaches the parent, and run_tests calls setup per-arm in the parent
# regardless. An earlier version did call it and claimed to be restoring state —
# it was restoring nothing and leaking one mktemp dir per arm.
_assert_teardown_sweeps() {  # $1=label  $2..=extra paths to create+register
  local label="$1"; shift
  local f
  for f in "$@"; do printf '#!/bin/bash\nexit 0\n' > "$f"; done
  _fixture_script "$@"
  for f in "$@"; do
    assert_eq "$(test -f "$f" && echo present || echo gone)" "present" \
      "$label: the fixture exists before teardown"
  done
  teardown
  for f in "$@"; do
    assert_eq "$(test -f "$f" && echo present || echo gone)" "gone" \
      "$label: teardown removed a fixture nothing rm'd"
  done
}

test_teardown_sweeps_a_registered_fixture() {
  _assert_teardown_sweeps "single" "$SCRIPT_DIR/sweep-single-test.sh"
}

# The two-argument call at ceo-cron-misc.test.sh's model/pureshell site is the
# only one in the suite, so a helper that registered only $1 would leave every
# test green while leaking the second path on every run.
test_teardown_sweeps_every_path_of_a_multi_path_registration() {
  _assert_teardown_sweeps "multi" \
    "$SCRIPT_DIR/sweep-multi-a-test.sh" "$SCRIPT_DIR/sweep-multi-b-test.sh"
}

# A path containing a newline would be swept in fragments, and the tail fragment
# is relative — `rm -f` would run against the harness cwd rather than SCRIPT_DIR.
# Refused at registration instead.
test_a_fixture_path_containing_a_newline_is_refused() {
  # $'\n', not "$(printf '\n')" — command substitution strips trailing newlines,
  # so the latter builds a path with no newline in it and the arm passes
  # vacuously. The helper had the identical bug; this arm found it.
  # Under TEST_HOME, not SCRIPT_DIR: _fixture_script refuses this path by design,
  # so it can never be registered, and an unregisterable file has no business in
  # the tracked directory. Nothing about the arm needs it there.
  local bad="$TEST_HOME/sweep-a"$'\n'"sweep-b.sh"
  printf '#!/bin/bash\nexit 0\n' > "$bad"
  local err rc=0
  err=$(_fixture_script "$bad" 2>&1) || rc=$?
  rm -f "$bad"
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a newline in a fixture path is refused, not registered"
  assert_contains "$err" "newline" "the refusal says why"
}

# The register lives in TEST_HOME. If that is gone the append fails, and these
# suites run `set -uo pipefail` without -e, so a silent return 1 would leak the
# fixture — the exact failure the helper exists to prevent.
# The three abort shapes #380 exists for. Each runs a whole child suite so the
# deliberate abort is the child's failure, not this suite's: an arm that exits
# mid-body cannot then assert on what teardown did, because it is gone.
_child_abort_leaves_no_fixture() {  # $1=label  $2=abort statement
  local label="$1" abort="$2"
  local probe="$SCRIPT_DIR/abort-$label-test.sh"
  rm -f "$probe"
  # The child lives in SCRIPT_DIR, not TEST_HOME: ceo-cron-test-common.sh
  # resolves test-harness.sh from $(dirname "$0"), so a child elsewhere fails to
  # source and never runs. That failure is silent in the shape these arms take —
  # the probe is then never created, and "gone" is trivially true — which is why
  # each arm also asserts the child actually produced a run.
  local child="$SCRIPT_DIR/abort-child-probe.sh"
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "source '$SCRIPT_DIR/ceo-cron-test-common.sh'"
    echo 'test_x() {'
    echo "  printf '#!/bin/bash\\nexit 0\\n' > \"$probe\""
    echo "  _fixture_script \"$probe\""
    echo "  $abort"
    echo '}'
    echo 'run_tests'
  } > "$child"
  # Registered, not just rm'd below: an arm proving that no unregistered
  # executable survives an abort must not itself write one and clean it up on a
  # line an abort would skip.
  _fixture_script "$child"
  local out; out=$(bash "$child" 2>&1)
  rm -f "$child"
  assert_contains "$out" "FAILED:" \
    "$label: the child suite actually ran and reported its deliberate failure"
  assert_eq "$(test -f "$probe" && echo present || echo gone)" "gone" \
    "$label: teardown swept the fixture after the body aborted"
  rm -f "$probe"
}

test_a_body_that_exits_still_has_its_fixture_swept() {
  _child_abort_leaves_no_fixture exit "exit 1"
}

test_a_body_that_returns_nonzero_still_has_its_fixture_swept() {
  _child_abort_leaves_no_fixture return "return 1"
}

test_a_body_ending_on_a_failing_assertion_still_has_its_fixture_swept() {
  _child_abort_leaves_no_fixture assert "assert_eq got want 'deliberate failure'"
}

# A signal skips teardown unless run_tests traps it, which it did not before
# #380. Without the trap the executable stays in the tracked scripts/ directory.
#
# SIGTERM, not SIGINT: a shell backgrounds a child with SIGINT set to SIG_IGN and
# the child inherits it, so `kill -INT` on a `&`-launched suite does nothing and
# this arm passed with the trap removed. SIGTERM is not ignored, and it is also
# the realistic signal — a CI cancel or a supervisor stop, not someone's Ctrl-C.
test_a_signalled_run_still_has_its_fixture_swept() {
  local probe="$SCRIPT_DIR/abort-signal-test.sh"
  rm -f "$probe"
  local child="$SCRIPT_DIR/interrupt-child-probe.sh"
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "source '$SCRIPT_DIR/ceo-cron-test-common.sh'"
    echo 'test_x() {'
    echo "  printf '#!/bin/bash\\nexit 0\\n' > \"$probe\""
    echo "  _fixture_script \"$probe\""
    echo '  echo READY'
    echo '  sleep 60'
    echo '}'
    echo 'run_tests'
  } > "$child"
  # Same reason as the abort helper, and more urgent here: this child sleeps 60s
  # by construction, so it is the likeliest file in the repo to be caught by a
  # Ctrl-C — and it sits in the tracked directory.
  _fixture_script "$child"
  bash "$child" >"$TEST_HOME/interrupt-out" 2>&1 &
  local child_pid=$!
  local waited=0
  while [ "$waited" -lt 100 ] && ! grep -q READY "$TEST_HOME/interrupt-out" 2>/dev/null; do
    sleep 0.1; waited=$((waited + 1))
  done
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  rm -f "$child"

  assert_contains "$(cat "$TEST_HOME/interrupt-out" 2>/dev/null || echo "")" "READY" \
    "the child reached the body before being signalled"
  assert_eq "$(test -f "$probe" && echo present || echo gone)" "gone" \
    "a signalled run still reaches teardown"
  rm -f "$probe"
}


test_registering_without_a_test_home_fails_loudly() {
  local saved="$TEST_HOME"
  TEST_HOME="$saved/definitely-not-here"
  local err rc=0
  err=$(_fixture_script "$SCRIPT_DIR/sweep-nohome-test.sh" 2>&1) || rc=$?
  TEST_HOME="$saved"
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "a missing TEST_HOME fails the registration"
  assert_contains "$err" "TEST_HOME" "the refusal names the cause"
}


test_script_runner_failure_records_bounded_output_in_failure_reason() {
  cat > "$SCRIPT_DIR/failing-script-test.sh" << 'SCRIPT'
#!/bin/bash
echo "Line 1 output"
echo "conflict: duplicate directory found" >&2
exit 1
SCRIPT
  _fixture_script "$SCRIPT_DIR/failing-script-test.sh"
  cat > "$CEO_DIR/playbooks/script-fail.md" << 'PB'
---
name: script-fail
description: Failing script test fixture
trigger: cron
schedule: "0 9 * * *"
runner: script
script: failing-script-test.sh
tier: read
status: active
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" script-fail >/dev/null 2>&1 || true

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Script exited 1 for script-fail — output:" \
    "failure record must include the output prefix"
  assert_contains "$skips_log" "conflict: duplicate directory found" \
    "failure record must contain the script output (#302)"
  rm -f "$SCRIPT_DIR/failing-script-test.sh"
}

# The arm above pins that output is recorded; this pins that it is *bounded*,
# which is the half that matters, because the reason does not stay local --
# _record_failure writes it into the Syncthing-replicated pending.md and hands
# it to ceo-notify.sh for the Discord webhook. Without this, widening the tail
# and the cut leaves the suite green.
test_script_runner_failure_output_is_bounded_to_the_last_lines() {
  cat > "$SCRIPT_DIR/verbose-failing-script-test.sh" << 'SCRIPT'
#!/bin/bash
for i in $(seq 1 40); do
  printf 'noise-line-%03d-%s\n' "$i" "$(printf 'x%.0s' $(seq 1 300))" >&2
done
echo "FINAL-MARKER the real error" >&2
exit 1
SCRIPT
  _fixture_script "$SCRIPT_DIR/verbose-failing-script-test.sh"
  cat > "$CEO_DIR/playbooks/script-verbose.md" << 'PB'
---
name: script-verbose
description: Verbose failing script fixture
trigger: cron
schedule: "0 9 * * *"
runner: script
script: verbose-failing-script-test.sh
tier: read
status: active
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" script-verbose >/dev/null 2>&1 || true

  local line len
  line=$(grep "Script exited 1 for script-verbose" "$CEO_DIR/log/cron-skips.log" 2>/dev/null | tail -1)
  len=${#line}
  assert_eq "$([ "$len" -le 1500 ] && echo bounded || echo "unbounded:$len")" "bounded" \
    "the recorded reason must stay bounded regardless of how much the script emitted"
  assert_contains "$line" "FINAL-MARKER" \
    "the bound must keep the LAST lines — the error — not the first"
  assert_not_contains "$line" "noise-line-001" \
    "the first lines of a long failure must be dropped, not the last"
  rm -f "$SCRIPT_DIR/verbose-failing-script-test.sh"
}

# The reason reaches a Discord webhook and a synced file, and a runner: script
# playbook is by definition one that shells out to authenticated tools — so a
# token in its stderr is the ordinary case, not an exotic one.
test_script_runner_failure_redacts_credentials_from_the_recorded_reason() {
  cat > "$SCRIPT_DIR/leaky-failing-script-test.sh" << 'SCRIPT'
#!/bin/bash
echo "fatal: could not read Username for 'https://nathan:ghp_AAAABBBBCCCCDDDDEEEE@github.com'" >&2
echo "gh: HTTP 401 with token=ghp_ZZZZYYYYXXXXWWWWVVVV1234" >&2
echo "Authorization: Bearer sk-abcdefghijklmnopqrstuvwx" >&2
exit 1
SCRIPT
  _fixture_script "$SCRIPT_DIR/leaky-failing-script-test.sh"
  cat > "$CEO_DIR/playbooks/script-leak.md" << 'PB'
---
name: script-leak
description: Credential-bearing failing script fixture
trigger: cron
schedule: "0 9 * * *"
runner: script
script: leaky-failing-script-test.sh
tier: read
status: active
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" script-leak >/dev/null 2>&1 || true

  local skips_log; skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Script exited 1 for script-leak" \
    "the failure must still be recorded"
  assert_not_contains "$skips_log" "ghp_AAAABBBBCCCCDDDDEEEE" \
    "a token embedded in a remote URL must not reach the failure reason"
  assert_not_contains "$skips_log" "ghp_ZZZZYYYYXXXXWWWWVVVV1234" \
    "a bare token must not reach the failure reason"
  assert_not_contains "$skips_log" "sk-abcdefghijklmnopqrstuvwx" \
    "an api key must not reach the failure reason"
  assert_contains "$skips_log" "REDACTED" \
    "the redaction must be visible rather than silently dropping the line"
  rm -f "$SCRIPT_DIR/leaky-failing-script-test.sh"
}

# A script that reports its error on stdout and exits non-zero is ordinary.
# Testing `[ -s "$SCRIPT_ERR_TMP" ]` rather than the trimmed tail meant a
# trailing newline on stderr suppressed the stdout diagnostic entirely.
test_script_runner_failure_falls_back_to_stdout_when_stderr_is_blank() {
  cat > "$SCRIPT_DIR/stdout-failing-script-test.sh" << 'SCRIPT'
#!/bin/bash
echo "STDOUT-DIAGNOSTIC the real error" 
printf '\n' >&2
exit 1
SCRIPT
  _fixture_script "$SCRIPT_DIR/stdout-failing-script-test.sh"
  cat > "$CEO_DIR/playbooks/script-stdout.md" << 'PB'
---
name: script-stdout
description: stdout-only failing script fixture
trigger: cron
schedule: "0 9 * * *"
runner: script
script: stdout-failing-script-test.sh
tier: read
status: active
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" script-stdout >/dev/null 2>&1 || true

  local skips_log; skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "STDOUT-DIAGNOSTIC the real error" \
    "a whitespace-only stderr must not suppress the stdout diagnostic"
  rm -f "$SCRIPT_DIR/stdout-failing-script-test.sh"
}


# The three-strike alert lands in approvals/pending.md, which every swarm host
# syncs and appends to. The counter behind it is host-local — CEO/log/.fail-count*
# is excluded by syncthing/shared.stignore — so "3 consecutive failures" is a
# claim about one machine, and an unnamed one leaves the reader unable to tell
# which, or whose cron-skips.log to open. #390 made that worse by putting the
# failing host's own script output in the reason.
test_the_three_strike_alert_names_the_host_that_failed() {
  cat > "$SCRIPT_DIR/alert-host-test.sh" << 'SH'
#!/bin/bash
exit 7
SH
  _fixture_script "$SCRIPT_DIR/alert-host-test.sh"
  cat > "$CEO_DIR/playbooks/alert-host.md" << 'PB'
---
name: alert-host
description: fails so the third strike escalates
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: alert-host-test.sh
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  mkdir -p "$CEO_DIR/log" "$CEO_DIR/approvals"
  : > "$CEO_DIR/approvals/pending.md"
  echo 2 > "$CEO_DIR/log/.fail-count-alert-host"
  CEO_HOSTNAME=test-host-a bash "$CRON" alert-host >/dev/null 2>&1 || true

  local pending; pending=$(cat "$CEO_DIR/approvals/pending.md" 2>/dev/null || echo "")
  assert_contains "$pending" "consecutive failures" "the third failure must escalate"
  assert_contains "$pending" "test-host-a" \
    "and the alert must name the host whose counter reached three"
  rm -f "$SCRIPT_DIR/alert-host-test.sh"
}

test_read_tier_failure_increments_fail_count() {
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "synthetic stderr from claude stub" >&2
exit 2
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  cat > "$CEO_DIR/playbooks/read-tier-fail.md" << 'PB'
---
name: read-tier-fail
description: Read-tier playbook used to exercise claude failure path
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" read-tier-fail >/dev/null 2>&1 || true

  local fails runs_log
  fails=$(_fail_count)
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after a read-tier failure"
  if [[ "$runs_log" == *"read-tier-fail completed"* ]]; then
    printf '  FAIL [%s] read-tier failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


# Exercises the real tier-routing wiring in ceo-cron.sh (not a reimplemented
# copy — see scripts/ceo-cron-tier-routing.test.sh, which tests a local helper
# that never calls into this script). A trigger name matching the shipped
# scripts/ceo-tier-map.json "read-only-lookup" shape (^(find|locate)\b) must
# get downgraded to haiku and logged to the shared ledger as a claude-tier row.
test_read_tier_downgrade_routes_through_real_script_and_logs_ledger() {
  local body json
  body="LOG_ENTRY:
## 12:00 - find-config-lookup
**Status:** completed
**Playbook:** find-config-lookup.md
**Output:**
found it
**Errors:**
- none
END_LOG_ENTRY"
  json=$(printf '%s' "$body" | jq -Rsc '{result: ., total_cost_usd: 0.002, session_id: "test"}')
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
#!/bin/bash
cat >/dev/null
cat <<'OUT'
$json
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  cat > "$CEO_DIR/playbooks/find-config-lookup.md" << 'PB'
---
name: find-config-lookup
description: Read-tier playbook whose trigger name matches the read-only-lookup shape
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" find-config-lookup >/dev/null 2>&1 || true

  local ledger_file
  ledger_file="$HOME/.local/state/ollama-agent/runs.jsonl"
  assert_file_exists "$ledger_file" "a matching trigger must write a claude-tier ledger row"
  local model
  model=$(jq -rc --arg tn "find-config-lookup" 'select(.writer == "claude-tier" and .task_name == $tn) | .model' "$ledger_file" 2>/dev/null | tail -1)
  assert_eq "$model" "haiku" "a trigger matching the allowlist must dispatch on the downgraded tier, not the playbook's declared model"
}


# Regression test for the completed:true-on-failure bug: the read-tier ledger
# write must not claim success when the underlying claude call actually failed.
test_read_tier_downgrade_failure_does_not_log_completed_true() {
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
echo "synthetic stderr from claude stub" >&2
exit 2
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  cat > "$CEO_DIR/playbooks/find-config-lookup-fail.md" << 'PB'
---
name: find-config-lookup-fail
description: Read-tier playbook matching the read-only-lookup shape, exercising the claude failure path
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" find-config-lookup-fail >/dev/null 2>&1 || true

  local ledger_file
  ledger_file="$HOME/.local/state/ollama-agent/runs.jsonl"
  assert_file_exists "$ledger_file" "a matching trigger must still write a claude-tier ledger row even on failure"
  local completed
  completed=$(jq -rc --arg tn "find-config-lookup-fail" 'select(.writer == "claude-tier" and .task_name == $tn) | .completed' "$ledger_file" 2>/dev/null | tail -1)
  assert_eq "$completed" "false" "a failed downgraded dispatch must not be logged as completed:true"
}


test_phase3_failure_does_not_log_completed() {
  # Stateful stub: succeeds on Phase-1 (with ACTION line low-stakes-write),
  # fails on Phase-3.
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
#!/bin/bash
COUNT_FILE="$TEST_HOME/.claude-call-count"
n=\$(cat "\$COUNT_FILE" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$COUNT_FILE"
if [ "\$n" = "1" ]; then
  echo "ACTION: 1 | low-stakes-write | noop | echo ok"
  exit 0
fi
echo "synthetic phase-3 failure" >&2
exit 3
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  cat > "$CEO_DIR/playbooks/phase3-fail.md" << 'PB'
---
name: phase3-fail
description: Low-stakes-write playbook to exercise Phase-3 failure
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: low-stakes-write
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" phase3-fail >/dev/null 2>&1 || true

  local fails runs_log
  fails=$(_fail_count)
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after Phase-3 failure"
  if [[ "$runs_log" == *"phase3-fail completed"* ]]; then
    printf '  FAIL [%s] Phase-3 failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_unknown_value_skipped_at_scan() {
  cat > "$CEO_DIR/playbooks/typo-runner.md" << 'PB'
---
name: typo-runner
description: Playbook with a typo in the runner field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: scrpt
script: typo-runner.sh
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  assert_contains "$scan_out" "unknown runner: 'scrpt'" "scan must skip unknown runner with diagnostic"

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="typo-runner")' "$REGISTRY_FILE" 2>/dev/null || echo "")
  assert_eq "$entry" "" "skipped playbook must not appear in registry.json"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_unknown_value_rejected_at_dispatch() {
  cat > "$CEO_DIR/playbooks/forced-typo.md" << 'PB'
---
name: forced-typo
description: Valid playbook
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# Body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq '(.playbooks[] | select(.name=="forced-typo") | .runner) |= "scrpt"' \
    "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  CEO_VERBOSE=1 bash "$CRON" forced-typo >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "dispatcher must reject unknown runner with exit 1"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Unknown runner 'scrpt'" "skips log must record unknown-runner rejection"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_accepted_at_scan() {
  cat > "$CEO_DIR/playbooks/ollama-ok.md" << 'PB'
---
name: ollama-ok
description: Playbook with runner:ollama
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  if [[ "$scan_out" == *"unknown runner: 'ollama'"* ]]; then
    printf '  FAIL [%s] runner:ollama must be accepted at scan\n    scan_out: %q\n' \
      "$CURRENT_TEST" "$scan_out"
    FAILS=$((FAILS + 1))
  fi

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="ollama-ok") | .runner' "$REGISTRY_FILE" 2>/dev/null || echo "")
  assert_eq "$entry" "ollama" "ollama playbook must be registered with runner:ollama"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_invokes_ollama_and_skips_claude() {
  cat > "$CEO_DIR/playbooks/ollama-dispatch.md" << 'PB'
---
name: ollama-dispatch
description: Routes to ollama
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-dispatch >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 on ollama success"

  assert_file_exists "$HOME/ollama-invoked-model.txt" "ollama must have been invoked"
  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude was invoked but the ollama-runner branch must skip it\n' \
      "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local model got_source numctx
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "glm4:latest" "runner:ollama default must be glm4:latest"
  got_source=$(cat "$HOME/ollama-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "ollama runner must export CEO_MODEL_SOURCE=invoked (harness drove the model)"
  # The headline fix: the request must carry the model's real context window, not
  # ollama's ~4K CLI default. Fails if options.num_ctx is dropped or shrunk.
  numctx=$(cat "$HOME/ollama-invoked-numctx.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$numctx" "32768" "request must set options.num_ctx to the model's real window (default 32768)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_ollama_run_is_bounded_by_timeout() {
  # _ollama_run bounds wall-clock via curl --max-time (no separate timeout
  # binary). Assert the API call carries --max-time <CEO_OLLAMA_TIMEOUT> so a
  # runaway generation can't hang a cron slot.
  cat > "$CEO_DIR/playbooks/ollama-timeout.md" << 'PB'
---
name: ollama-timeout
description: Routes to ollama
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_OLLAMA_TIMEOUT=123 bash "$CRON" ollama-timeout >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 when the ollama API call succeeds"

  assert_file_exists "$HOME/curl-invoked.txt" "ollama generation must go through curl"
  local rec
  rec=$(cat "$HOME/curl-invoked.txt" 2>/dev/null || echo "")
  assert_contains "$rec" "--max-time 123" \
    "ollama API call must be bounded by CEO_OLLAMA_TIMEOUT seconds"
}


test_runner_ollama_think_uses_gpt_oss_default() {
  cat > "$CEO_DIR/playbooks/ollama-think-dispatch.md" << 'PB'
---
name: ollama-think-dispatch
description: Routes to ollama-think
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama-think
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-think-dispatch >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 on ollama-think success"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "gpt-oss:20b" "runner:ollama-think default must be gpt-oss:20b"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_explicit_model_overrides_default() {
  cat > "$CEO_DIR/playbooks/ollama-explicit.md" << 'PB'
---
name: ollama-explicit
description: Explicit model override
trigger: cron
schedule: "0 9 * * *"
model: qwen3:14b
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-explicit >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "dispatcher must exit 0 with explicit ollama model"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "qwen3:14b" "explicit model: tag must override runner default"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_failure_increments_fail_count() {
  cat > "$CEO_DIR/playbooks/ollama-fail.md" << 'PB'
---
name: ollama-fail
description: ollama exits non-zero
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  # Override the default curl stub to simulate an ollama API failure: write a
  # sentinel to stderr (which _ollama_run's caller redirects to cron-stderr.log)
  # and exit non-zero so the run is recorded as a failure, not silent-empty.
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
echo "ollama-error-sentinel" >&2
exit 9
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-fail >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after ollama failure"

  # Pin: failure must come from the ollama branch specifically. cron-runs.log must
  # NOT contain a completion line for this playbook — that's what proves the
  # ollama branch (not an earlier preflight/schema/missing-file path) failed.
  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-fail completed"* ]]; then
    printf '  FAIL [%s] ollama failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "ollama-error-sentinel" "ollama stderr must be appended to cron-stderr.log"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_ollama_timeout_kill_propagates_as_failure() {
  # The point of curl --max-time: when it fires (curl exit 28), the run must be
  # recorded as a failure, not silently skipped. Stub curl to simulate the
  # timeout exit.
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
exit 28
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  cat > "$CEO_DIR/playbooks/ollama-killed.md" << 'PB'
---
name: ollama-killed
description: ollama wrapped call is timeout-killed
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-killed >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "a timeout-killed (exit 124) ollama call must increment the fail count"

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-killed completed"* ]]; then
    printf '  FAIL [%s] a timeout-killed run must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_ollama_timeout_rejects_non_numeric_bound() {
  # A non-numeric CEO_OLLAMA_TIMEOUT must be rejected (warn + fall back to 300),
  # not passed verbatim to curl --max-time (which would exit before connecting).
  cat > "$CEO_DIR/playbooks/ollama-badto.md" << 'PB'
---
name: ollama-badto
description: bad timeout value
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_OLLAMA_TIMEOUT=abc bash "$CRON" ollama-badto >/dev/null 2>&1 || true

  local rec
  rec=$(cat "$HOME/curl-invoked.txt" 2>/dev/null || echo "missing")
  assert_contains "$rec" "--max-time 300" "non-numeric CEO_OLLAMA_TIMEOUT must fall back to 300, not reach curl verbatim"

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "CEO_OLLAMA_TIMEOUT='abc'" "a rejected timeout value must be warned about"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_think_accepted_at_scan() {
  cat > "$CEO_DIR/playbooks/ollama-think-ok.md" << 'PB'
---
name: ollama-think-ok
description: Playbook with runner:ollama-think
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama-think
---
PB

  local scan_out
  scan_out=$(bash "$CEO_CLI" playbook scan 2>&1 || true)
  if [[ "$scan_out" == *"unknown runner: 'ollama-think'"* ]]; then
    printf '  FAIL [%s] runner:ollama-think must be accepted at scan\n    scan_out: %q\n' \
      "$CURRENT_TEST" "$scan_out"
    FAILS=$((FAILS + 1))
  fi

  local entry
  entry=$(jq -r '.playbooks[] | select(.name=="ollama-think-ok") | .runner' "$REGISTRY_FILE" 2>/dev/null || echo "")
  assert_eq "$entry" "ollama-think" "ollama-think playbook must be registered with runner:ollama-think"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_model_sonnet_passes_literal() {
  cat > "$CEO_DIR/playbooks/ollama-sonnet.md" << 'PB'
---
name: ollama-sonnet
description: Misconfigured — model:sonnet on ollama runner
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-sonnet >/dev/null 2>&1 || true

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "sonnet" "explicit model:sonnet on runner:ollama must pass literally (not silently coerce to glm4 default)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_daemon_unreachable_records_failure() {
  cat > "$CEO_DIR/playbooks/ollama-noprobe.md" << 'PB'
---
name: ollama-noprobe
description: Daemon probe enabled, curl fails
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
exit 7
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  env -u CEO_OLLAMA_SKIP_PROBE CEO_VERBOSE=1 bash "$CRON" ollama-noprobe >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "unreachable ollama daemon must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked when daemon probe fails\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_empty_output_records_failure() {
  cat > "$CEO_DIR/playbooks/ollama-empty.md" << 'PB'
---
name: ollama-empty
description: ollama exits 0 but emits nothing
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  # API returns 200 with an empty .response — _ollama_run must surface that as
  # empty output so the caller records a failure (not a silent success).
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
echo '{"response":""}'
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-empty >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "empty ollama output must increment FAIL_COUNT_FILE (alert threshold relies on this)"

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-empty completed"* ]]; then
    printf '  FAIL [%s] empty ollama output must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_error_in_200_body_records_failure() {
  # non-throwing-client-success-check: a 200 response can still carry an .error
  # (model not found, OOM). _ollama_run must inspect it and route to failure,
  # not treat the (empty .response) as success — and must log the error text.
  cat > "$CEO_DIR/playbooks/ollama-apierror.md" << 'PB'
---
name: ollama-apierror
description: ollama 200 body carries an .error
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
echo '{"error":"model not found"}'
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-apierror >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "a 200 body carrying .error must increment FAIL_COUNT_FILE"

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "ollama API error" "the API .error text must be logged, not swallowed"
  assert_contains "$stderr_log" "model not found" "the daemon's error message must reach cron-stderr.log"

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  if [[ "$runs_log" == *"ollama-apierror completed"* ]]; then
    printf '  FAIL [%s] a .error response must NOT log completed\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_non_json_body_records_failure() {
  # A non-JSON body (proxy HTML error, truncated stream) must route to failure
  # via explicit validation with a logged diagnostic — not an ambient set -e
  # trip that leaves cron-stderr.log silent.
  cat > "$CEO_DIR/playbooks/ollama-nonjson.md" << 'PB'
---
name: ollama-nonjson
description: ollama returns a non-JSON body
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
echo '<html>502 Bad Gateway</html>'
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-nonjson >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "a non-JSON ollama body must increment FAIL_COUNT_FILE"

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "non-JSON or empty body" "a non-JSON body must log a diagnostic, not fail silently"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_ollama_num_ctx_rejects_non_integer() {
  # Sibling of test_ollama_timeout_rejects_non_numeric_bound: a typo'd
  # CEO_OLLAMA_NUM_CTX must warn and fall back to 32768, not reach the request
  # verbatim.
  cat > "$CEO_DIR/playbooks/ollama-badctx.md" << 'PB'
---
name: ollama-badctx
description: bad num_ctx value
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_OLLAMA_NUM_CTX=abc bash "$CRON" ollama-badctx >/dev/null 2>&1 || true

  local numctx
  numctx=$(cat "$HOME/ollama-invoked-numctx.txt" 2>/dev/null || echo "missing")
  assert_eq "$numctx" "32768" "non-integer CEO_OLLAMA_NUM_CTX must fall back to 32768, not reach the request verbatim"

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "CEO_OLLAMA_NUM_CTX='abc'" "a rejected num_ctx value must be warned about"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_default_budget_admits_real_prompt() {
  # Pins the budget raise (24576 -> 90000). The production failures were 27-51 KB
  # prompts rejected/chunked at the old 24 KB cap. This fixture's scan prompt
  # lands ~25-32 KB — above the old cap, below the new one — so at the default
  # (90000) it dispatches as a SINGLE call; revert the default to 24576 and the
  # same prompt is over budget and routes to the chunker (>= 2 calls). The
  # curl stub records the prompt size so the test self-validates its premise.
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
url="" ; data="" ; prev=""
for a in "$@"; do
  case "$prev" in -d|--data|--data-binary|--data-raw) data="$a" ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/generate)
    [ "$data" = "@-" ] && data="$(cat)"
    echo x >> "$HOME/ollama-call-count.txt"
    printf '%s' "$data" | jq -r '.prompt' | wc -c | tr -d ' ' > "$HOME/ollama-prompt-bytes.txt"
    printf '%s' 'LOG_ENTRY:
## 03:10 — morning-scan
**Status:** completed
**Playbook:** playbooks/morning-scan.md
**Output:**
- budget-ok-sentinel
**Errors:**
- none
END_LOG_ENTRY' | jq -Rs '{response:.}'
    exit 0 ;;
  *) exec /usr/bin/curl "$@" ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  cat > "$CEO_DIR/playbooks/morning-scan.md" << 'PB'
---
name: morning-scan
description: default-budget admits real prompt
trigger: cron
schedule: "50 8 * * 1-5"
runner: ollama
model: gemma4:12b-it-qat
preflight: none
tier: read
status: active
---
# morning-scan body
PB

  touch -t 202501010000 "$CEO_DIR/log/.last-scan" 2>/dev/null || touch "$CEO_DIR/log/.last-scan"
  mkdir -p "$CEO_VAULT/Projects" "$CEO_VAULT/Areas" "$CEO_VAULT/Daily"
  for i in $(seq 1 8); do echo "project note content $i" > "$CEO_VAULT/Projects/note-$i.md"; done
  echo "area work content" > "$CEO_VAULT/Areas/work.md"
  local _y _t
  _y=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
  _t=$(date +%Y-%m-%d)
  { echo "# Yesterday"; for _ in $(seq 1 280); do echo "yesterday content line for the default-budget scan test padding"; done; } > "$CEO_VAULT/Daily/$_y.md"
  { echo "# Today"; for _ in $(seq 1 140); do echo "today content line for the default-budget scan test padding"; done; } > "$CEO_VAULT/Daily/$_t.md"
  { echo "# Report"; for _ in $(seq 1 140); do echo "yesterday report line for the default-budget scan test padding"; done; } > "$CEO_DIR/reports/$_y.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" morning-scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "the scan prompt must dispatch at the default budget, not fail"

  # Premise guard: the prompt must sit strictly between the old and new caps,
  # else the mutation (default -> 24576) wouldn't change behavior.
  local pbytes
  pbytes=$(cat "$HOME/ollama-prompt-bytes.txt" 2>/dev/null || echo 0)
  if [ "$pbytes" -le 24576 ] || [ "$pbytes" -ge 90000 ]; then
    printf '  FAIL [%s] fixture prompt %s bytes must be in (24576, 90000) for this test to bite\n' \
      "$CURRENT_TEST" "$pbytes"
    FAILS=$((FAILS + 1))
  fi

  # At the default budget this prompt is under budget -> exactly one API call.
  # Reverting the default to 24576 forces the chunker (>= 2 calls).
  local calls
  calls=$(wc -l < "$HOME/ollama-call-count.txt" 2>/dev/null | tr -d ' ')
  assert_eq "${calls:-0}" "1" "a ~25-32 KB prompt must be a single call at the default budget (90000), not chunked"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  if echo "$skips_log" | grep -q "exceeds budget"; then
    printf '  FAIL [%s] the scan prompt must NOT hit the budget-exceeded path at the default (90000)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_works_under_stripped_path() {
  cat > "$CEO_DIR/playbooks/ollama-strip.md" << 'PB'
---
name: ollama-strip
description: ollama dispatch under stripped PATH (proves ceo_augment_path reaches branch)
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" ollama-strip >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ollama branch must resolve ollama via ceo_augment_path under stripped PATH"
  assert_file_exists "$HOME/ollama-invoked-model.txt" "ollama stub must fire under stripped PATH"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_skips_preamble_files() {
  cat > "$CEO_DIR/playbooks/ollama-preamble.md" << 'PB'
---
name: ollama-preamble
description: Assert AGENTS/IDENTITY omitted
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# my-playbook-body
PB

  echo "SENTINEL_AGENT_CONTENT" > "$CEO_DIR/AGENTS.md"
  echo "SENTINEL_IDENTITY_CONTENT" > "$CEO_DIR/IDENTITY.md"
  echo "SENTINEL_TRAINING_CONTENT" > "$CEO_DIR/TRAINING.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-preamble >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/ollama-invoked-prompt.txt" 2>/dev/null || echo "")

  if [[ "$prompt" == *"SENTINEL_AGENT_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain AGENTS.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"SENTINEL_IDENTITY_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain IDENTITY.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"SENTINEL_TRAINING_CONTENT"* ]]; then
    printf '  FAIL [%s] ollama prompt must NOT contain TRAINING.md content\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$prompt" "my-playbook-body" "ollama prompt must contain the playbook body"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_read_tier_includes_pre_gathered_data() {
  # Seed approvals/pending.md with three unchecked items so PENDING_COUNT=3
  # (per ceo-gather.sh's `grep -c "^- \[ \]" approvals/pending.md`). The
  # sentinel value lets us prove the gathered count reached the ollama prompt.
  cat > "$CEO_DIR/approvals/pending.md" << 'PENDING'
# Pending

- [ ] sentinel-pending-item-A
- [ ] sentinel-pending-item-B
- [ ] sentinel-pending-item-C
PENDING

  cat > "$CEO_DIR/playbooks/ollama-pregather.md" << 'PB'
---
name: ollama-pregather
description: Verify pre-gathered data injection on ollama+tier:read
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# ollama-pregather-playbook-body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-pregather >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/ollama-invoked-prompt.txt" 2>/dev/null || echo "")
  assert_contains "$prompt" "PRE-GATHERED DATA" "ollama+tier:read prompt must include PRE-GATHERED DATA section"
  assert_contains "$prompt" "ollama-pregather-playbook-body" "ollama prompt must include playbook body"
  assert_contains "$prompt" "PLAYBOOK (ollama-pregather)" "ollama prompt must label the playbook"
  # Sentinel pin: the seeded inbox count must reach the prompt body. A revert
  # of the SINGLE_PROMPT_BODY split (so ollama got only the playbook file)
  # would not surface PENDING_COUNT — the literal "3 pending" disappears.
  assert_contains "$prompt" "3 pending" "pre-gathered PENDING_COUNT (sentinel: 3) must reach ollama prompt"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}


test_runner_ollama_prompt_exceeds_budget_fails() {
  cat > "$CEO_DIR/playbooks/ollama-toolarge.md" << 'PB'
---
name: ollama-toolarge
description: Tests CEO_OLLAMA_MAX_PROMPT_BYTES budget enforcement
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# ollama-toolarge-body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_OLLAMA_MAX_PROMPT_BYTES=100 CEO_VERBOSE=1 bash "$CRON" ollama-toolarge >/dev/null 2>&1 || true

  local fails
  fails=$(_fail_count)
  assert_eq "$fails" "1" "oversized prompt must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked when prompt exceeds budget\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "exceeds budget (" "skips log must record oversized-prompt reason with byte counts"

  # Forensic capture: the offending prompt context lands in cron-raw.log so a
  # human investigating "why is morning-brief over budget on Tuesdays" has an
  # artifact to inspect (mirrors the claude failure-path capture).
  local raw_log
  raw_log=$(cat "$CEO_DIR/log/cron-raw.log" 2>/dev/null || echo "")
  assert_contains "$raw_log" "Prompt exceeds budget" "cron-raw.log must capture budget-exceeded events"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
