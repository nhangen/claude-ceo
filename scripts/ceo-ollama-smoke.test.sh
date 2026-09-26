#!/bin/bash
# Tests for ceo-ollama-smoke.sh and docs/playbooks/ollama-smoke.md (#276).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
SCRIPT="$SCRIPT_DIR/ceo-ollama-smoke.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  export CEO_HOSTNAME="testhost"
  export CEO_RUNNER_OUTCOME_FILE="$TEST_HOME/outcome"
  export OLLAMA_SMOKE_BIN="$TEST_HOME/mock-smoke"
  mkdir -p "$CEO_STATE_DIR" "$CEO_DIR/playbooks" "$HOME/.ceo"
  : > "$CEO_DIR/inbox.md"
  ALERT="$CEO_DIR/alerts/ollama-smoke.md"
  INBOX="$CEO_DIR/inbox/ollama-smoke.md"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR CEO_HOSTNAME CEO_RUNNER_OUTCOME_FILE \
    OLLAMA_SMOKE_BIN OLLAMA_SMOKE_TIMEOUT CEO_REPO_PLAYBOOK_DIR TEST_HOME HOME_BACKUP
}

# _mock <exit-code> <pass> <fail> <skip> — a stand-in for integration_smoke.sh
# that prints the same ANSI-colored check lines and plain summary line.
_mock() {
  local rc="$1" p="$2" f="$3" s="$4"
  cat > "$OLLAMA_SMOKE_BIN" <<STUB
#!/bin/bash
printf '\n\033[1m%s\033[0m\n' "Prerequisites"
for _ in \$(seq 1 $p); do printf '  \033[32mPASS\033[0m %s\n' "check"; done
for _ in \$(seq 1 $f); do printf '  \033[31mFAIL\033[0m %s\n' "ccr chat"; done
for _ in \$(seq 1 $s); do printf '  \033[33mSKIP\033[0m %s (%s)\n' "ccr chat" "ccr down"; done
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' $p $f $s
exit $rc
STUB
  chmod +x "$OLLAMA_SMOKE_BIN"
}

_run() { bash "$SCRIPT" >/dev/null 2>&1; }
_field() { awk -v f="$1" 'index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }' "$ALERT"; }
_open_tasks() {
  if [ -f "$INBOX" ]; then grep -c '^- \[ \].*<!-- ollama-smoke -->' "$INBOX"; else echo 0; fi
}
_outcome() { cat "$CEO_RUNNER_OUTCOME_FILE" 2>/dev/null; }

test_missing_smoke_bin_fails_loudly() {
  rm -f "$OLLAMA_SMOKE_BIN"
  local err="" rc=0
  err=$(bash "$SCRIPT" 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing smoke bin must exit 1"
  assert_contains "$err" "integration_smoke.sh not found" "stderr must describe missing smoke bin"
}

test_full_pass_is_clear_and_silent() {
  _mock 0 6 0 0
  _run
  assert_eq "$(_field status)" "clear" "zero skips and zero fails is clear"
  assert_eq "$(_field stack)" "present" "stack present"
  assert_eq "$(_open_tasks)" "0" "no inbox task on a healthy run"
  assert_eq "$(_outcome)" "noop" "a healthy run does not notify"
  assert_eq "$(grep -c "$(printf '\033')" "$ALERT")" "0" "ANSI escapes are stripped from the alert body"
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    assert_eq "$(_field timeout)" "900s" "default timeout recorded in frontmatter"
    assert_not_contains "$(cat "$ALERT")" "run uncapped" "capped run does not display uncapped warning"
  else
    assert_eq "$(_field timeout)" "none" "uncapped timeout field recorded"
  fi
}

test_all_skip_on_owner_host_fires_as_absent() {
  _mock 0 0 0 6
  _run
  assert_eq "$(_field status)" "firing" "all-skip on the owner host is an outage, not green"
  assert_eq "$(_field stack)" "absent" "stack marked absent"
  assert_eq "$(_field skip_count)" "6" "skip count recorded"
  assert_eq "$(_open_tasks)" "1" "all-skip escalates"
  assert_eq "$(_outcome)" "fired" "escalation notifies"
}

test_partial_skip_fires_as_degraded() {
  _mock 0 3 0 5
  _run
  assert_eq "$(_field status)" "firing" "ccr down with ollama up is not a pass"
  assert_eq "$(_field stack)" "degraded" "stack marked degraded"
  assert_eq "$(_open_tasks)" "1" "degraded escalates"
}

test_failure_fires_and_escalates_once() {
  _mock 1 2 1 0
  _run
  assert_eq "$(_field status)" "firing" "FAIL>0 fires"
  assert_eq "$(_field stack)" "failing" "stack failing"
  assert_eq "$(_field fail_count)" "1" "fail count recorded"
  _run
  assert_eq "$(_open_tasks)" "1" "a second red run does not append a second task"
  assert_eq "$(_outcome)" "noop" "steady firing does not re-notify"
}

test_ticked_task_is_not_reappended_while_still_firing() {
  _mock 1 2 1 0
  _run
  sed -i.bak 's/^- \[ \]/- [x]/' "$INBOX" && rm -f "$INBOX.bak"
  _run
  assert_eq "$(_open_tasks)" "0" "escalation happens on the transition, not on every red run"
  assert_eq "$(grep -c 'ollama-smoke -->' "$INBOX")" "1" "no new task line appended"
}

test_recovery_marks_task_done() {
  _mock 1 2 1 0
  _run
  _mock 0 6 0 0
  _run
  assert_eq "$(_field status)" "clear" "status flips to clear"
  assert_eq "$(_open_tasks)" "0" "task no longer open"
  assert_contains "$(cat "$INBOX")" "- [done] Ollama live stack smoke cleared" "task rewritten to done"
  assert_eq "$(_outcome)" "fired" "recovery notifies"
}

test_firing_then_all_skip_keeps_task_open() {
  _mock 1 2 1 0
  _run
  _mock 0 0 0 6
  _run
  assert_eq "$(_field status)" "firing" "a dead stack does not clear a firing alert"
  assert_eq "$(_open_tasks)" "1" "the open task survives"
  assert_not_contains "$(cat "$INBOX")" "[done]" "nothing marked done"
}

test_harness_exit_2_is_a_harness_error_not_a_fake_failure() {
  cat > "$OLLAMA_SMOKE_BIN" <<'STUB'
#!/bin/bash
echo "missing required tool: curl" >&2
exit 2
STUB
  chmod +x "$OLLAMA_SMOKE_BIN"
  _run
  assert_eq "$(_field status)" "firing" "harness error fires"
  assert_eq "$(_field stack)" "harness-error" "stack marked harness-error"
  assert_eq "$(_field fail_count)" "?" "no invented fail count"
  assert_contains "$(cat "$ALERT")" "harness exited 2" "reason recorded in body"
}

test_missing_summary_line_is_a_harness_error() {
  printf '#!/bin/bash\necho "crashed before summary"\nexit 0\n' > "$OLLAMA_SMOKE_BIN"
  chmod +x "$OLLAMA_SMOKE_BIN"
  _run
  assert_eq "$(_field stack)" "harness-error" "no summary is a harness error"
  assert_contains "$(cat "$ALERT")" "no PASS/FAIL/SKIP summary line" "reason recorded"
}

test_timeout_is_a_harness_error() {
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "  (skipped: no timeout binary on this host)"
    assert_eq "skipped" "skipped" "no timeout binary on this host (timeout or gtimeout)"
    return 0
  fi
  printf '#!/bin/bash\nsleep 10\n' > "$OLLAMA_SMOKE_BIN"
  chmod +x "$OLLAMA_SMOKE_BIN"
  export OLLAMA_SMOKE_TIMEOUT=1
  _run
  assert_eq "$(_field stack)" "harness-error" "a hung smoke is a harness error"
  assert_contains "$(cat "$ALERT")" "timed out after 1s" "timeout named in body"
  assert_eq "$(_field timeout)" "1s" "configured timeout recorded in frontmatter"
}

test_no_timeout_binary_runs_uncapped_and_warns() {
  # timeout lives beside everything else in /usr/bin on Linux, so it cannot be
  # dropped by trimming PATH. Mirror PATH into one directory of symlinks that
  # leaves out timeout and gtimeout instead.
  local nobin="$TEST_HOME/no-timeout-bin" dir f name err
  mkdir -p "$nobin"
  local IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      name=${f##*/}
      case "$name" in timeout|gtimeout) continue ;; esac
      [ -x "$f" ] && [ ! -e "$nobin/$name" ] && ln -s "$f" "$nobin/$name"
    done
  done
  unset IFS
  printf '#!/bin/bash\necho "PASS=3 FAIL=0 SKIP=0"\n' > "$OLLAMA_SMOKE_BIN"
  chmod +x "$OLLAMA_SMOKE_BIN"
  # _CEO_PATH_AUGMENTED=1 stops ceo_augment_path from prepending Homebrew, which
  # would put gtimeout straight back on PATH on a Mac.
  err=$(PATH="$nobin" _CEO_PATH_AUGMENTED=1 bash "$SCRIPT" 2>&1 >/dev/null)
  assert_contains "$err" "no timeout or gtimeout on PATH" "running uncapped is announced"
  assert_eq "$(_field status)" "clear" "the smoke still runs and its summary is read"
  assert_eq "$(_field timeout)" "none" "uncapped run records timeout: none in frontmatter"
  assert_contains "$(cat "$ALERT")" "run uncapped" "uncapped run surfaced in alert body"
}

test_since_is_kept_while_steady_and_reset_on_transition() {
  mkdir -p "$CEO_DIR/alerts"
  printf -- '---\nstatus: firing\nsince: 2026-01-01T00:00:00Z\nlast_check: x\nhost: testhost\n---\n' > "$ALERT"
  _mock 1 2 1 0
  _run
  assert_eq "$(_field since)" "2026-01-01T00:00:00Z" "steady firing keeps since"
  _mock 0 6 0 0
  _run
  assert_not_contains "$(_field since)" "2026-01-01" "a transition resets since"
}

test_corrupt_prior_state_does_not_touch_inbox() {
  mkdir -p "$CEO_DIR/alerts" "$CEO_DIR/inbox"
  printf -- '---\nsince: x\n---\n' > "$ALERT"
  printf -- '- [ ] Investigate local ollama stack (failing) <!-- ollama-smoke -->\n' > "$INBOX"
  _mock 0 6 0 0
  _run
  assert_eq "$(_open_tasks)" "1" "corrupt prior state never resolves the task"
  assert_eq "$(_field status)" "clear" "current state is still written"
}

test_corrupt_prior_state_does_not_escalate() {
  mkdir -p "$CEO_DIR/alerts"
  printf -- '---\nsince: x\n---\n' > "$ALERT"
  _mock 1 2 1 0
  _run
  assert_eq "$(_open_tasks)" "0" "corrupt prior state never escalates"
  assert_eq "$(_field status)" "firing" "current state is still written"
}

test_smoke_model_is_passed_to_the_harness() {
  printf '#!/bin/bash\necho "model=${OLL_MODEL:-default}"\necho "PASS=1  FAIL=0  SKIP=0"\n' > "$OLLAMA_SMOKE_BIN"
  chmod +x "$OLLAMA_SMOKE_BIN"
  OLLAMA_SMOKE_MODEL="qwen3.8:27b" bash "$SCRIPT" >/dev/null 2>&1
  assert_contains "$(cat "$ALERT")" "model=qwen3.8:27b" "OLLAMA_SMOKE_MODEL reaches the smoke as OLL_MODEL"
}

test_playbook_scan_registers_ollama_smoke() {
  cp "$SCRIPT_DIR/../docs/playbooks/ollama-smoke.md" "$CEO_DIR/playbooks/ollama-smoke.md"
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local reg="$HOME/.ceo/registry.json"
  assert_file_exists "$reg" "registry must exist after scan"
  _pb() { jq -r --arg k "$1" '.playbooks[] | select(.name=="ollama-smoke") | .[$k]' "$reg"; }
  assert_eq "$(_pb status)" "active" "status is active"
  assert_eq "$(_pb runner)" "script" "runner is script"
  assert_eq "$(_pb script)" "ceo-ollama-smoke.sh" "script is ceo-ollama-smoke.sh"
  assert_eq "$(_pb scope)" "single" "scope is single"
  assert_eq "$(_pb schedule)" "0 8 * * 1" "weekly Monday 08:00"
  assert_eq "$(_pb artifact)" "CEO/alerts/ollama-smoke.md" "artifact is CEO/alerts/ollama-smoke.md"
}

run_tests
