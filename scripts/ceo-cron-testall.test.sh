#!/bin/bash
# ceo-cron.sh tests — #140 --test-all fleet sweep.
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


# --test-all sweeps every registered playbook and writes one aggregate report
# naming each playbook it touched.
test_test_all_sweeps_all_registered_playbooks() {
  _register_pb_sched ta-one "1 9 * * *"
  _register_pb_sched ta-two "2 9 * * *"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" --test-all >/dev/null 2>&1 || true
  local report; report=$(_test_all_report)
  assert_file_exists "$report" "--test-all must write the aggregate sweep report"
  assert_contains "$(cat "$report" 2>/dev/null)" "ta-one" "sweep report must list ta-one"
  assert_contains "$(cat "$report" 2>/dev/null)" "ta-two" "sweep report must list ta-two"
}


# --test-all implies dry-run: no playbook may leave a real side effect —
# no .last-run stamp, no cron-runs.log append, and no notify/Discord dispatch
# (the dry-run chokepoints short-circuit before ceo-notify.sh).
test_test_all_implies_dry_run_no_side_effects() {
  _register_status_playbook ta-noeffect active
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" bash "$CRON" --test-all >/dev/null 2>&1 || true
  assert_fails "--test-all must not stamp .last-run for any swept playbook" test -f "$CEO_DIR/log/.last-run-ta-noeffect"
  assert_not_contains "$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null)" "ta-noeffect completed" "--test-all must not append to cron-runs.log"
  assert_fails "--test-all must not invoke notify/Discord for any swept playbook" test -s "$TEST_HOME/notify-debug.log"
}


# The aggregate report lives under CEO/log/preview/, the host-local (stignored)
# scratch tree — a fleet smoke-test stays on the host that ran it.
test_test_all_report_is_under_host_local_preview() {
  _register_status_playbook ta-local active
  bash "$CRON" --test-all >/dev/null 2>&1 || true
  local report; report=$(_test_all_report)
  assert_contains "$report" "/log/preview/test-all/" "sweep report must live under the host-local preview tree"
  assert_file_exists "$report" "sweep report must exist at the host-local path"
}


# --test-all takes no positional trigger; combining the two is a usage error.
# A valid registry is scanned first so the ONLY nonzero source is the trigger
# guard — otherwise the test would pass off the missing-registry abort and stay
# green even if the guard were removed. We also assert the specific message.
test_test_all_rejects_trigger_arg() {
  _register_pb_sched ta-rt "3 9 * * *"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local err rc=0
  err=$(bash "$CRON" --test-all some-trigger 2>&1) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "--test-all with a trigger must be rejected"
  assert_contains "$err" "takes no trigger argument" "rejection must come from the trigger guard, not a downstream registry error"
}


# Unknown --depth is rejected at parse (enum-config-typo-fallback: no silent
# default). Registry scanned first so the enum guard is the only nonzero source.
test_test_all_rejects_unknown_depth() {
  _register_pb_sched ta-rd "4 9 * * *"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local err rc=0
  err=$(bash "$CRON" --test-all --depth bogus 2>&1) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "--depth with an unknown value must be rejected"
  assert_contains "$err" "must be one of: preflight, plan, deep" "rejection must come from the depth enum guard, not a downstream error"
}


# Default sweep depth is preflight: the cheap fleet health check makes NO model
# call — it only asks "would this playbook fire right now?".
test_test_all_default_depth_preflight_makes_no_model_call() {
  _register_status_playbook ta-pre active
  bash "$CRON" --test-all >/dev/null 2>&1 || true
  assert_fails "default --test-all (preflight depth) must not invoke the model" test -f "$HOME/claude-invoked.txt"
}


# --depth deep exercises every model call: a read-tier playbook makes its
# single-call. (Mutation guard: if the preflight gate wrongly fired, this fails.)
test_test_all_depth_deep_invokes_model() {
  _register_status_playbook ta-deep active
  bash "$CRON" --test-all --depth deep >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "--depth deep must invoke the read-tier model call"
}


# --all-hosts is a Phase-1.5 stub: it warns it isn't implemented and sweeps the
# local host only, rather than silently pretending to fan out.
test_test_all_all_hosts_warns_and_still_sweeps() {
  _register_status_playbook ta-ah active
  local out; out=$(bash "$CRON" --test-all --all-hosts 2>&1)
  assert_contains "$out" "all-hosts" "--all-hosts must warn it is not yet implemented"
  assert_file_exists "$(_test_all_report)" "--all-hosts must still produce the local sweep report"
}


# The aggregate distinguishes a playbook that WOULD run (preflight passed) from
# one that would SKIP (preflight no-work) — the point of the fleet health check.
test_test_all_aggregate_distinguishes_would_run_from_skip() {
  _register_pb_sched ta-run "1 9 * * *" none
  _register_pb_sched ta-skip "2 9 * * *" has_pending_items
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" --test-all >/dev/null 2>&1 || true
  local body; body=$(cat "$(_test_all_report)" 2>/dev/null)
  assert_contains "$body" "ta-run" "report must include the would-run playbook"
  assert_contains "$body" "ta-skip" "report must include the no-work playbook"
  assert_contains "$body" "no work" "report must mark the preflight-no-work playbook as a skip"
}


# --depth is a dry-run/test-all concept; requiring it elsewhere would be a silent
# no-op. Reject --depth without --dry-run or --test-all. Assert the specific
# message so the test fails when the guard is removed (a bare nonzero check would
# pass off the unrelated "no playbook registered" abort).
test_depth_requires_dry_run_or_test_all() {
  local err rc=0
  err=$(bash "$CRON" some-name --depth preflight 2>&1) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "--depth without --dry-run/--test-all must be rejected"
  assert_contains "$err" "--depth requires --dry-run or --test-all" "rejection must come from the requires-preview guard"
}


# A dry-run preflight that hits a dependency failure (gh down → preflight calls
# _record_failure then returns 1) exits 0 with a "Would record FAILURE" marker.
# The sweep must classify that as FAILED, not a benign "skip: no work" — else a
# broken-dependency playbook reads as a false all-clear, defeating --test-all.
test_test_all_preflight_dependency_failure_is_failed_not_skip() {
  _register_pb_sched ta-dep "5 9 * * *" has_prs_to_review
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  # No gh on PATH in tests → has_prs_to_review records a failure and returns 1.
  bash "$CRON" --test-all >/dev/null 2>&1 || true
  local body; body=$(cat "$(_test_all_report)" 2>/dev/null)
  assert_contains "$body" "ta-dep | FAILED" "a preflight dependency failure must classify as FAILED"
  assert_not_contains "$body" "ta-dep | skip: no work" "a dependency failure must NOT read as a benign skip"
}


# --depth plan: a read-tier playbook has no planning phase, so it previews the
# call it WOULD make without spending tokens (no model call).
test_dry_run_depth_plan_read_tier_previews_without_call() {
  _register_pb_sched dp-read "6 9 * * *" none
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dp-read --dry-run --depth plan >/dev/null 2>&1 || true
  assert_fails "plan depth must not invoke the read-tier model" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$(_preview_file dp-read)" 2>/dev/null)" "would call model" "plan depth must preview the would-be read-tier call"
}


# --depth plan on a tier:write playbook runs the PLAN call (planning phase
# exists) but still skips EXECUTE (it's a dry-run).
test_dry_run_depth_plan_write_tier_runs_plan() {
  cat > "$CEO_DIR/playbooks/dp-write.md" << 'PB'
---
name: dp-write
description: plan-depth write fixture
trigger: cron
schedule: "7 9 * * *"
model: sonnet
preflight: none
tier: high-stakes
status: active
---
PB
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "call" >> "$HOME/claude-calls.log"
cat >/dev/null
echo "ACTION: 1 | high-stakes | deploy | gh deploy"
echo "ACTION: 2 | read | check | n/a"
STUB
  chmod +x "$HOME/.bun/bin/claude"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dp-write --dry-run --depth plan >/dev/null 2>&1 || true
  assert_eq "$(wc -l < "$HOME/claude-calls.log" 2>/dev/null | tr -d ' ')" "1" "plan depth on tier:write must run PLAN once (EXECUTE skipped)"
  assert_fails "plan-depth write dry-run must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dp-write"
}


# --model overrides the model passed to the dispatcher's claude call (deep depth
# makes the call). Unset would use the frontmatter/default model. The override is
# exported as CEO_MODEL_OVERRIDE and inherited by --test-all children too.
test_dry_run_model_override_applies_to_read_tier() {
  _register_pb_sched mo-read "8 9 * * *" none
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = "--model" ] && echo "$2" > "$HOME/claude-model.txt"; shift; done
cat >/dev/null
echo "ACTION: 1 | read | noop | n/a"
STUB
  chmod +x "$HOME/.bun/bin/claude"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" mo-read --dry-run --depth deep --model haiku-override >/dev/null 2>&1 || true
  assert_eq "$(cat "$HOME/claude-model.txt" 2>/dev/null)" "haiku-override" "--model must override the model passed to claude"
}


# --depth preflight composes with a plain --dry-run too (not only --test-all):
# it stops after preflight, before any model call.
test_dry_run_depth_preflight_skips_model_call() {
  _register_status_playbook dr-pre active
  bash "$CRON" dr-pre --dry-run --depth preflight >/dev/null 2>&1 || true
  assert_fails "--dry-run --depth preflight must not invoke the model" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$(_preview_file dr-pre)" 2>/dev/null)" "preflight" "preview must note it stopped at preflight depth"
}

run_tests
