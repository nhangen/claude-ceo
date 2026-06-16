#!/bin/bash
# Self-contained test harness for the ceo-cron.sh script-runner branch.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
CRON="$SCRIPT_DIR/ceo-cron.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  # The generated registry is host-local now ($HOME/.ceo/registry.json), not in
  # the synced vault. Both `ceo playbook scan` (write) and `ceo cron` (read)
  # resolve this path; tests seed/inspect it here, not under $CEO_DIR.
  REGISTRY_FILE="$HOME/.ceo/registry.json"
  # Bypass the ollama daemon HTTP probe in tests (the stubbed ollama binary
  # has no daemon backing it). Production runs leave this unset.
  export CEO_OLLAMA_SKIP_PROBE=1

  # Isolate cron lock to this test invocation
  export CEO_LOCK_FILE="$TEST_HOME/ceo-cron.lock"

  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/approvals" "$CEO_DIR/reports" "$HOME/.ceo"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"
  echo "- [ ] test task" > "$CEO_DIR/approvals/pending.md"

  # Stub crontab so playbook scan's cron install can't touch the user's real crontab.
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" << 'STUB'
#!/bin/bash
# no-op stub for tests
if [ "${1:-}" = "-l" ]; then
  cat "$HOME/.fake-crontab" 2>/dev/null || true
  exit 0
fi
cat > "$HOME/.fake-crontab"
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  : > "$HOME/.fake-crontab"

  # Stub claude on PATH so dispatcher invocations are detectable. Default behavior
  # is success — individual tests override $TEST_HOME/.bun/bin/claude to simulate failure.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "claude-fired" > "$HOME/claude-invoked.txt"
printf '%s' "${CEO_MODEL_SOURCE:-UNSET}" > "$HOME/claude-model-source.txt"
echo "ACTION: 1 | read | noop | n/a"
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  # Stub ollama on PATH for runner:ollama / runner:ollama-think tests. Captures
  # the model argument so tests can assert which model was dispatched.
  # Presence stub: production checks `command -v ollama` before dispatching, but
  # generation now goes through the HTTP API (curl), not `ollama run`. This stub
  # only needs to exist; the curl stub below does the real emulation.
  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  # _ollama_run posts to the ollama HTTP API (POST /api/generate). Emulate it:
  # validate the request shape (model present, num_ctx a positive integer),
  # capture model/prompt/num_ctx so tests can assert what was dispatched, record
  # full argv (so timeout tests can check --max-time), and return a canned
  # completion. Per stub-cli-argv-validation the stub exits non-zero on a
  # malformed generate call. Any non-generate curl (Discord webhook, daemon
  # probe) execs the real binary so unrelated behavior is unchanged; tests that
  # need different curl behavior override this file.
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
args="$*"
url="" ; data="" ; prev=""
for a in "$@"; do
  case "$prev" in -d|--data|--data-binary|--data-raw) data="$a" ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/generate)
    echo "$args" >> "$HOME/curl-invoked.txt"
    [ "$data" = "@-" ] && data="$(cat)"
    model=$(printf '%s' "$data" | jq -r '.model // empty' 2>/dev/null)
    numctx=$(printf '%s' "$data" | jq -r '.options.num_ctx // empty' 2>/dev/null)
    if [ -z "$model" ]; then echo "curl stub: /api/generate body missing .model" >&2; exit 91; fi
    case "$numctx" in ''|*[!0-9]*|0) echo "curl stub: /api/generate missing positive .options.num_ctx (got '$numctx')" >&2; exit 92 ;; esac
    printf '%s\n' "$model" >> "$HOME/ollama-invoked-model.txt"
    printf '%s' "$data" | jq -r '.prompt // empty' > "$HOME/ollama-invoked-prompt.txt"
    { printf '%s' "$data" | jq -r '.prompt // empty'; printf '\n---CALL---\n'; } >> "$HOME/ollama-invoked-prompts.txt"
    printf '%s' "$numctx" > "$HOME/ollama-invoked-numctx.txt"
    printf '%s' "${CEO_MODEL_SOURCE:-UNSET}" > "$HOME/ollama-model-source.txt"
    printf 'ollama-stub-response' | jq -Rs '{response:.}'
    exit 0 ;;
  *)
    exec /usr/bin/curl "$@" ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  # macOS lacks `timeout` from GNU coreutils; the dispatcher uses
  # `timeout N claude ...`. Stub it as a transparent passthrough.
  if ! command -v timeout >/dev/null 2>&1; then
    cat > "$TEST_HOME/.bun/bin/timeout" << 'STUB'
#!/bin/bash
shift  # discard the duration arg
exec "$@"
STUB
    chmod +x "$TEST_HOME/.bun/bin/timeout"
  fi

  export PATH="$TEST_HOME/.bun/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR TEST_HOME HOME_BACKUP PATH_BACKUP CEO_REPO_PLAYBOOK_DIR CEO_OLLAMA_SKIP_PROBE CEO_LOCK_FILE
}

test_runner_script_execs_named_script_and_skips_claude() {
  cat > "$CEO_DIR/playbooks/fake-intake.md" << 'PB'
---
name: fake-intake
description: Test playbook for runner:script
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: fake-intake.sh
---
PB

  cat > "$SCRIPT_DIR/fake-intake.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/script-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/fake-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  CEO_VERBOSE=1 bash "$CRON" fake-intake >/dev/null 2>&1
  assert_file_exists "$TEST_HOME/script-fired.txt" "script must have executed"
  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude was invoked but the script-runner branch must skip it\n' \
      "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  rm -f "$SCRIPT_DIR/fake-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cron_rejects_trigger_with_quote() {
  local rc=0
  bash "$CRON" 'bad"trigger' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject trigger names containing shell metacharacters"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "invalid trigger" "stderr must explain rejection"
}

test_cron_rejects_trigger_with_path_traversal() {
  local rc=0
  bash "$CRON" '../etc' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject trigger names containing path separators"
}

test_cron_rejects_pure_dot_trigger() {
  local rc=0
  bash "$CRON" '..' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject '..' (would land in .last-run-.. path)"
}

test_cron_rejects_leading_dot_trigger() {
  local rc=0
  bash "$CRON" '.hidden' >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "ceo-cron.sh must reject names starting with '.'"
}

test_cron_accepts_valid_trigger_shapes() {
  cat > "$CEO_DIR/playbooks/valid-trigger_1.md" << 'PB'
---
name: valid-trigger_1
description: shape-validation acceptance fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: shape-noop.sh
---
PB
  cat > "$SCRIPT_DIR/shape-noop.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/shape-noop.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  bash "$CRON" valid-trigger_1 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo-cron.sh must accept trigger names matching [A-Za-z0-9._-]+"
  rm -f "$SCRIPT_DIR/shape-noop.sh"
}

test_runner_claude_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-claude.md" << 'PB'
---
name: playbook-id-claude
description: Verifies CEO_PLAYBOOK_ID is exported to the claude runner
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  cat > "$TEST_HOME/.bun/bin/claude" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-claude.txt"
cat >/dev/null
echo "ACTION: 1 | read | noop | n/a"
SH
  chmod +x "$TEST_HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-claude >/dev/null 2>&1 || true
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-claude.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-claude" "claude runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
}

test_runner_ollama_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-ollama.md" << 'PB'
---
name: playbook-id-ollama
description: Verifies CEO_PLAYBOOK_ID is exported to the ollama runner
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# Body
PB

  cat > "$TEST_HOME/.bun/bin/curl" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-ollama.txt"
cat >/dev/null
printf 'ollama-stub-response' | jq -Rs '{response:.}'
SH
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-ollama >/dev/null 2>&1 || true
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-ollama.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-ollama" "ollama runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
}

test_runner_skill_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-skill.md" << 'PB'
---
name: playbook-id-skill
description: Verifies CEO_PLAYBOOK_ID is exported to the skill runner
trigger: cron
status: active
tier: read
runner: skill
skill: playbook-id-skill
out_pattern: CEO/reports/playbook-id-skill/${TODAY}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/playbook-id-skill/scripts"
  cat > "$HOME/.claude/skills/playbook-id-skill/scripts/run-report.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-skill.txt"
printf '%s' "\${CEO_MODEL_SOURCE:-UNSET}" > "$TEST_HOME/skill-source-from-child.txt"
printf '%s' "\${CEO_RUNNER_ARTIFACT:-UNSET}" > "$TEST_HOME/skill-artifact-from-child.txt"
while [[ "\$#" -gt 0 ]]; do
  case \$1 in --out) out_dir="\$2"; shift ;; esac
  shift
done
echo "skill stub" > "\$out_dir/report.md"
SH
  chmod +x "$HOME/.claude/skills/playbook-id-skill/scripts/run-report.sh"

  PATH=/usr/bin:/bin bash "$CRON" playbook-id-skill >/dev/null 2>&1 || true
  local got got_source got_artifact
  got=$(cat "$TEST_HOME/playbook-id-from-skill.txt" 2>/dev/null || echo "MISSING")
  got_source=$(cat "$TEST_HOME/skill-source-from-child.txt" 2>/dev/null || echo "MISSING")
  got_artifact=$(cat "$TEST_HOME/skill-artifact-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-skill" "skill runner must export CEO_PLAYBOOK_ID=<trigger> to its child"
  assert_eq "$got_source" "declared" "skill runner must export CEO_MODEL_SOURCE=declared (frontmatter claim, not harness-invoked)"
  assert_eq "$got_artifact" "playbook-id-skill" "skill runner must export CEO_RUNNER_ARTIFACT=<skill name> for the Discord embed"
}

test_runner_script_exports_ceo_playbook_id_to_child() {
  cat > "$CEO_DIR/playbooks/playbook-id-script.md" << 'PB'
---
name: playbook-id-script
description: Verifies CEO_PLAYBOOK_ID is exported to script-runner children
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: playbook-id-script.sh
---
PB

  cat > "$SCRIPT_DIR/playbook-id-script.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_PLAYBOOK_ID:-UNSET}" > "$TEST_HOME/playbook-id-from-child.txt"
SH
  chmod +x "$SCRIPT_DIR/playbook-id-script.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" playbook-id-script >/dev/null 2>&1
  local got
  got=$(cat "$TEST_HOME/playbook-id-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got" "playbook-id-script" "script-runner must export CEO_PLAYBOOK_ID=<trigger> to its child"

  rm -f "$SCRIPT_DIR/playbook-id-script.sh"
}

test_runner_script_exports_frontmatter_model_not_runner_name() {
  cat > "$CEO_DIR/playbooks/model-script.md" << 'PB'
---
name: model-script
description: Verifies CEO_MODEL carries the frontmatter model for a script runner
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: model-script.sh
model: sonnet
---
PB
  cat > "$CEO_DIR/playbooks/pureshell-script.md" << 'PB'
---
name: pureshell-script
description: Verifies CEO_MODEL is empty for a script runner with no model
trigger: cron
schedule: "30 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: pureshell-script.sh
---
PB

  cat > "$SCRIPT_DIR/model-script.sh" << SH
#!/bin/bash
printf '%s' "\${CEO_MODEL:-UNSET}" > "$TEST_HOME/model-from-child.txt"
printf '%s' "\${CEO_MODEL_SOURCE:-UNSET}" > "$TEST_HOME/source-from-child.txt"
printf '%s' "\${CEO_RUNNER_ARTIFACT:-UNSET}" > "$TEST_HOME/artifact-from-child.txt"
SH
  cat > "$SCRIPT_DIR/pureshell-script.sh" << SH
#!/bin/bash
printf '[%s]' "\${CEO_MODEL-UNSET}" > "$TEST_HOME/pureshell-model-from-child.txt"
SH
  chmod +x "$SCRIPT_DIR/model-script.sh" "$SCRIPT_DIR/pureshell-script.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" model-script >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" pureshell-script >/dev/null 2>&1
  local got_model got_pure got_source got_artifact
  got_model=$(cat "$TEST_HOME/model-from-child.txt" 2>/dev/null || echo "MISSING")
  got_pure=$(cat "$TEST_HOME/pureshell-model-from-child.txt" 2>/dev/null || echo "MISSING")
  got_source=$(cat "$TEST_HOME/source-from-child.txt" 2>/dev/null || echo "MISSING")
  got_artifact=$(cat "$TEST_HOME/artifact-from-child.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_model" "sonnet" "script-runner must export CEO_MODEL=<frontmatter model>, not the runner name"
  assert_eq "$got_pure" "[]" "script-runner with no model must export CEO_MODEL empty, not 'script'"
  assert_eq "$got_source" "declared" "script-runner must export CEO_MODEL_SOURCE=declared (frontmatter claim, not harness-invoked)"
  assert_eq "$got_artifact" "model-script.sh" "script-runner must export CEO_RUNNER_ARTIFACT=<script file> for the Discord embed"

  rm -f "$SCRIPT_DIR/model-script.sh" "$SCRIPT_DIR/pureshell-script.sh"
}

test_runner_default_invokes_claude() {
  cat > "$CEO_DIR/playbooks/fake-claude.md" << 'PB'
---
name: fake-claude
description: Default-runner playbook
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
  CEO_VERBOSE=1 bash "$CRON" fake-claude >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "default runner must invoke claude"
  local got_source
  got_source=$(cat "$HOME/claude-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "claude runner must export CEO_MODEL_SOURCE=invoked (harness drove the model)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pipeline_claude_exports_invoked_source() {
  cat > "$CEO_DIR/playbooks/pipeline-claude.md" << 'PB'
---
name: pipeline-claude
description: Low-stakes-write playbook locking the three-phase pipeline CEO_MODEL_SOURCE export
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: low-stakes-write
status: active
---
# Body
PB
  rm -f "$HOME/claude-model-source.txt"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" pipeline-claude >/dev/null 2>&1 || true
  local got_source
  got_source=$(cat "$HOME/claude-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "three-phase pipeline (low-stakes-write) claude runner must export CEO_MODEL_SOURCE=invoked"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_tier_posts_full_report_to_discord_report_webhook() {
  cat > "$CEO_DIR/playbooks/morning-brief.md" << 'PB'
---
name: morning-brief
description: Morning brief
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# Body
PB

  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — morning-brief
**Status:** completed
**Playbook:** playbooks/morning-brief.md
**Output:**
Full morning body from the model.
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$HOME/.bun/bin/claude"

  mkdir -p "$TEST_HOME/curl"
  export CURL_CAPTURE_DIR="$TEST_HOME/curl"
  cat > "$HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
out="$CURL_CAPTURE_DIR/payload.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      shift
      printf '%s' "$1" > "$out"
      ;;
  esac
  shift || true
done
exit 0
STUB
  chmod +x "$HOME/.bun/bin/curl"

  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' \
    > "$HOME/.config/claude-ceo/secrets.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" morning-brief >/dev/null 2>&1

  local payload
  payload=$(cat "$CURL_CAPTURE_DIR/payload.json" 2>/dev/null || echo "")
  assert_contains "$payload" "CEO full report: morning-brief" \
    "cron must post a full-report Discord message for morning-brief"
  assert_contains "$payload" "Full morning body from the model." \
    "Discord payload must include the parsed LOG_ENTRY body"

  unset CURL_CAPTURE_DIR
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_v_safe_under_set_e() {
  cat > "$CEO_DIR/playbooks/v-test.md" << 'PB'
---
name: v-test
description: Exercises _v under set -e with CEO_VERBOSE unset
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: v-test.sh
---
PB

  cat > "$SCRIPT_DIR/v-test.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/v-test-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/v-test.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  unset CEO_VERBOSE
  bash "$CRON" v-test >/dev/null 2>&1
  assert_file_exists "$TEST_HOME/v-test-fired.txt" \
    "script must run end-to-end with CEO_VERBOSE unset (regression guard for a528fde)"

  rm -f "$SCRIPT_DIR/v-test.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_script_stderr_redirected_to_log() {
  cat > "$CEO_DIR/playbooks/stderr-intake.md" << 'PB'
---
name: stderr-intake
description: Test playbook to verify script stderr is captured
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: stderr-intake.sh
---
PB

  cat > "$SCRIPT_DIR/stderr-intake.sh" << 'SH'
#!/bin/bash
echo "synthetic-script-stderr-sentinel" >&2
exit 4
SH
  chmod +x "$SCRIPT_DIR/stderr-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" stderr-intake >/dev/null 2>&1 || true

  local stderr_log
  stderr_log=$(cat "$CEO_DIR/log/cron-stderr.log" 2>/dev/null || echo "")
  assert_contains "$stderr_log" "synthetic-script-stderr-sentinel" \
    "script stderr must be appended to cron-stderr.log"

  rm -f "$SCRIPT_DIR/stderr-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_script_failure_increments_fail_count() {
  cat > "$CEO_DIR/playbooks/fail-intake.md" << 'PB'
---
name: fail-intake
description: Test playbook for runner:script failure
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: fail-intake.sh
---
PB

  cat > "$SCRIPT_DIR/fail-intake.sh" << 'SH'
#!/bin/bash
exit 7
SH
  chmod +x "$SCRIPT_DIR/fail-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" fail-intake >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after one script failure"

  rm -f "$SCRIPT_DIR/fail-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_script_success_resets_fail_count() {
  cat > "$CEO_DIR/playbooks/ok-intake.md" << 'PB'
---
name: ok-intake
description: Test playbook for runner:script success
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: ok-intake.sh
---
PB

  cat > "$SCRIPT_DIR/ok-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/ok-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  echo 2 > "$CEO_DIR/log/.fail-count"
  CEO_VERBOSE=1 bash "$CRON" ok-intake >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "0" "FAIL_COUNT_FILE must be 0 after a successful script run"

  rm -f "$SCRIPT_DIR/ok-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_script_success_appends_runs_log() {
  cat > "$CEO_DIR/playbooks/log-intake.md" << 'PB'
---
name: log-intake
description: Test playbook to verify cron-runs.log entry
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: log-intake.sh
---
PB

  cat > "$SCRIPT_DIR/log-intake.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/log-intake.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" log-intake >/dev/null 2>&1 || true

  local runs_log
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_contains "$runs_log" "log-intake completed" "cron-runs.log must record successful script run"

  rm -f "$SCRIPT_DIR/log-intake.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_disk_monitor_success_suppresses_success_notification() {
  cat > "$CEO_DIR/playbooks/disk-monitor.md" << 'PB'
---
name: disk-monitor
description: Test disk-monitor notification suppression
trigger: cron
schedule: "0 */6 * * *"
preflight: none
tier: read
status: active
runner: script
script: disk-monitor-test.sh
---
PB

  cat > "$SCRIPT_DIR/disk-monitor-test.sh" << 'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$SCRIPT_DIR/disk-monitor-test.sh"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_NOTIFY_DEBUG_LOG="$TEST_HOME/notify-debug.log" CEO_VERBOSE=1 bash "$CRON" disk-monitor >/dev/null 2>&1 || true

  local notify_log
  notify_log=$(cat "$TEST_HOME/notify-debug.log" 2>/dev/null || echo "")
  if [[ "$notify_log" == *"[success/disk-monitor]"* ]]; then
    printf '  FAIL [%s] disk-monitor success must not invoke success notification\n    log: %q\n' "$CURRENT_TEST" "$notify_log"
    FAILS=$((FAILS + 1))
  fi

  rm -f "$SCRIPT_DIR/disk-monitor-test.sh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  runs_log=$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null || echo "")
  assert_eq "$fails" "1" "FAIL_COUNT_FILE must be 1 after a read-tier failure"
  if [[ "$runs_log" == *"read-tier-fail completed"* ]]; then
    printf '  FAIL [%s] read-tier failure must NOT log completed\n    runs_log: %q\n' \
      "$CURRENT_TEST" "$runs_log"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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

  local model got_source
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "gemma4:12b-it-qat" "runner:ollama default must be gemma4:12b-it-qat"
  got_source=$(cat "$HOME/ollama-model-source.txt" 2>/dev/null || echo "MISSING")
  assert_eq "$got_source" "invoked" "ollama runner must export CEO_MODEL_SOURCE=invoked (harness drove the model)"
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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
  assert_eq "$model" "sonnet" "explicit model:sonnet on runner:ollama must pass literally (not silently coerce to gemma4 default)"
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
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

test_runner_ollama_chunked_scan_when_prompt_exceeds_budget() {
  # Trigger chunking by creating real vault files so ceo-scan.sh produces enough
  # scan data to push the prompt over CEO_OLLAMA_MAX_PROMPT_BYTES=5000. Both the
  # per-chunk extraction calls and the synthesis call go through _ollama_run →
  # curl /api/generate; the stub appends a model line per call so the test can
  # count invocations, and returns the LOG_ENTRY as the API .response. Real jq
  # is used (the API request/response encoding needs the full jq, not a subset
  # stub).
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
    printf '%s' "$data" | jq -r '.model' >> "$HOME/ollama-invoked-model.txt"
    { printf '%s' "$data" | jq -r '.prompt'; printf '\n---CALL---\n'; } >> "$HOME/ollama-invoked-prompts.txt"
    printf '%s' 'LOG_ENTRY:
## 03:10 — morning-scan
**Status:** completed
**Playbook:** playbooks/morning-scan.md
**Output:**
- chunked-scan-sentinel
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
description: chunked scan test
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

  cat > "$REGISTRY_FILE" << JSON
{
  "schema_version": 3,
  "generated": "2026-06-02T00:00:00Z",
  "playbooks": [{
    "name": "morning-scan",
    "description": "chunked scan test",
    "trigger": "cron",
    "schedule": "50 8 * * 1-5",
    "model": "gemma4:12b-it-qat",
    "preflight": "none",
    "tier": "read",
    "status": "active",
    "runner": "ollama",
    "script": "",
    "skill": "",
    "out_pattern": "",
    "inputs": null,
    "requires": null,
    "file": "playbooks/morning-scan.md"
  }]
}
JSON

  # Set last-scan marker to the past so all vault files look new to ceo-scan.sh
  touch -t 202501010000 "$CEO_DIR/log/.last-scan" 2>/dev/null || touch "$CEO_DIR/log/.last-scan"

  # Create vault files to populate VAULT_CHANGES_BY_DOMAIN
  mkdir -p "$CEO_VAULT/Projects" "$CEO_VAULT/Areas"
  for i in $(seq 1 8); do
    echo "project note content $i" > "$CEO_VAULT/Projects/note-$i.md"
  done
  echo "area work content" > "$CEO_VAULT/Areas/work.md"

  # Create daily notes with ~2 KB each so SCAN_DATA exceeds 5000 bytes total
  local _yesterday _today
  _yesterday=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
  _today=$(date +%Y-%m-%d)
  mkdir -p "$CEO_VAULT/Daily"
  { echo "# Yesterday Daily Note"; for _ in $(seq 1 80); do echo "yesterday content line for morning scan test"; done; } \
    > "$CEO_VAULT/Daily/$_yesterday.md"
  { echo "# Today Daily Note"; for _ in $(seq 1 40); do echo "today content line for morning scan test"; done; } \
    > "$CEO_VAULT/Daily/$_today.md"

  # Create a yesterday report to add to SCAN_DATA
  { echo "# CEO Report"; for _ in $(seq 1 40); do echo "yesterday report line for morning scan test"; done; } \
    > "$CEO_DIR/reports/$_yesterday.md"

  local rc=0
  CEO_OLLAMA_MAX_PROMPT_BYTES=5000 CEO_VERBOSE=1 bash "$CRON" morning-scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "chunked scan must exit 0 when scan data exceeds budget"

  local calls
  calls=$(wc -l < "$HOME/ollama-invoked-model.txt" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "${calls:-0}" -lt 2 ]; then
    printf '  FAIL [%s] chunked scan must invoke ollama at least twice (chunks + synthesis), got %s\n' \
      "$CURRENT_TEST" "${calls:-0}"
    FAILS=$((FAILS + 1))
  fi

  local report
  report=$(cat "$CEO_DIR/reports/$_today.md" 2>/dev/null || echo "")
  assert_contains "$report" "chunked-scan-sentinel" "today's report must contain synthesized output from chunked scan"

  local skips
  skips=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  if echo "$skips" | grep -q "exceeds budget"; then
    printf '  FAIL [%s] chunked scan must not fall through to the budget-exceeded failure path\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 3))
}

test_runner_ollama_rejects_non_read_tier() {
  cat > "$CEO_DIR/playbooks/ollama-writetier.md" << 'PB'
---
name: ollama-writetier
description: ollama on non-read tier must reject before any dispatch
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: low-stakes-write
status: active
runner: ollama
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-writetier >/dev/null 2>&1 || rc=$?

  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] ollama with non-read tier must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama must NOT be invoked for non-read tier\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "ollama runner requires tier:read" "skips log must record reject reason"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_think_rejects_non_read_tier() {
  # Sibling pin for runner:ollama-think — the guard at ceo-cron.sh:459 covers
  # both ollama variants, so a regression that drops one side would leak.
  cat > "$CEO_DIR/playbooks/ollama-think-writetier.md" << 'PB'
---
name: ollama-think-writetier
description: ollama-think on non-read tier must reject
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: low-stakes-write
status: active
runner: ollama-think
---
# body
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  local rc=0
  CEO_VERBOSE=1 bash "$CRON" ollama-think-writetier >/dev/null 2>&1 || rc=$?

  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] ollama-think with non-read tier must exit non-zero (got rc=0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ -f "$HOME/ollama-invoked-model.txt" ]; then
    printf '  FAIL [%s] ollama-think must NOT be invoked for non-read tier\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_success_routes_through_ceo_report_intake() {
  # Pins Finding 1 of the panel review: morning-brief / morning-scan after the
  # ollama switch must still land in CEO/reports/<date>.md and trigger the
  # Discord side-channel — same as the claude path. Regression-test for the
  # bug where the ollama branch wrote directly to LOG_FILE and bypassed
  # ceo-report.sh entirely.

  cat > "$CEO_DIR/playbooks/ollama-intake.md" << 'PB'
---
name: ollama-intake
description: ollama success must route through ceo-report.sh intake
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: ollama
---
# body
PB

  # curl now serves two roles: the ollama /api/generate call (returns a
  # parseable LOG_ENTRY block routed through ceo-report.sh intake) and the
  # Discord side-channel POST (captured to assert it fired, same shape as
  # test_read_tier_posts_full_report).
  mkdir -p "$TEST_HOME/curl"
  export CURL_CAPTURE_DIR="$TEST_HOME/curl"
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
    printf '%s' "$data" | jq -r '.model'  > "$HOME/ollama-invoked-model.txt"
    printf '%s' "$data" | jq -r '.prompt' > "$HOME/ollama-invoked-prompt.txt"
    printf '%s' 'LOG_ENTRY:
## 09:00 — ollama-intake
**Status:** completed
**Playbook:** playbooks/ollama-intake.md
**Output:**
Hello from ollama-intake-sentinel.
**Errors:**
- none
END_LOG_ENTRY' | jq -Rs '{response:.}'
    exit 0 ;;
  *)
    [ "$data" = "@-" ] && data="$(cat)"
    printf '%s' "$data" > "$CURL_CAPTURE_DIR/payload.json"
    exit 0 ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' \
    > "$HOME/.config/claude-ceo/secrets.json"
  # ceo-discord-report.sh defaults the trigger allowlist to ["morning-brief"];
  # extend it so this test playbook is allowed to fire the side channel.
  echo '{"discord_report_triggers": ["ollama-intake"]}' \
    > "$CEO_DIR/settings.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-intake >/dev/null 2>&1 || true

  # REPORT_FILE must exist with the intake entry — this is the canonical
  # write that breaks if the ollama branch skips ceo-report.sh.
  local report_file
  report_file="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  assert_file_exists "$report_file" "ollama success must write to CEO/reports/<date>.md via ceo-report.sh intake"
  local report
  report=$(cat "$report_file" 2>/dev/null || echo "")
  assert_contains "$report" "ollama-intake-sentinel" "report file must contain the LOG_ENTRY body"
  assert_contains "$report" "ollama-intake [intake]" "report header must be intake-tagged"

  # Discord side-channel fires (proves intake routing is reached, not just
  # report-file append — they're separate concerns inside ceo-report.sh).
  local payload
  payload=$(cat "$CURL_CAPTURE_DIR/payload.json" 2>/dev/null || echo "")
  assert_contains "$payload" "ollama-intake-sentinel" "Discord side-channel must fire on ollama success"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_ollama_self_reported_failed_records_failure() {
  # Pins Finding 1 second facet: a model that emits **Status:** failed inside
  # its LOG_ENTRY block must increment FAIL_COUNT_FILE — not silently record
  # success because the exit code was 0 and stdout was non-empty.

  cat > "$CEO_DIR/playbooks/ollama-selffail.md" << 'PB'
---
name: ollama-selffail
description: ollama self-reports failed → must increment fail count
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
url="" ; data="" ; prev=""
for a in "$@"; do
  case "$prev" in -d|--data|--data-binary|--data-raw) data="$a" ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/generate)
    [ "$data" = "@-" ] && data="$(cat)"
    printf '%s' 'LOG_ENTRY:
## 09:00 — ollama-selffail
**Status:** failed
**Playbook:** playbooks/ollama-selffail.md
**Output:**
Simulated playbook failure.
**Errors:**
- something broke during synthesis
END_LOG_ENTRY' | jq -Rs '{response:.}'
    exit 0 ;;
  *) exec /usr/bin/curl "$@" ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" ollama-selffail >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "model self-reporting **Status:** failed must increment FAIL_COUNT_FILE (silent-success invariant)"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "self-reported" "cron-skips.log must record self-reported-failure reason"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_claude_self_reported_failed_records_failure() {
  # Sibling invariant: the same shape on the claude path. Before the
  # _dispatch_single_output helper consolidation, claude swallowed
  # model-self-reported failures and recorded success. The helper now gates
  # both runners through the same check.

  cat > "$CEO_DIR/playbooks/claude-selffail.md" << 'PB'
---
name: claude-selffail
description: claude self-reports failed → must increment fail count
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# body
PB

  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — claude-selffail
**Status:** failed
**Playbook:** playbooks/claude-selffail.md
**Output:**
Simulated claude failure.
**Errors:**
- broken
END_LOG_ENTRY
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" claude-selffail >/dev/null 2>&1 || true

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "claude path: model self-reporting **Status:** failed must increment FAIL_COUNT_FILE"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_production_morning_brief_registers_with_ollama_runner() {
  # Pins Finding 2 of the panel review: the actual docs/playbooks/morning-brief.md
  # in the repo must register with runner: ollama + tier: read after this PR.
  # A typo in the frontmatter (e.g. `runner: olllama`) would silently ship
  # green without this test — the unit tests above use synthetic playbooks.

  local repo_playbook="$SCRIPT_DIR/../docs/playbooks/morning-brief.md"
  if [ ! -f "$repo_playbook" ]; then
    printf '  FAIL [%s] cannot find production playbook at %q\n' \
      "$CURRENT_TEST" "$repo_playbook"
    FAILS=$((FAILS + 1))
    return
  fi
  cp "$repo_playbook" "$CEO_DIR/playbooks/morning-brief.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local runner tier model
  runner=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .runner' "$REGISTRY_FILE" 2>/dev/null || echo "")
  tier=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .tier' "$REGISTRY_FILE" 2>/dev/null || echo "")
  model=$(jq -r '.playbooks[] | select(.name=="morning-brief") | .model' "$REGISTRY_FILE" 2>/dev/null || echo "")
  assert_eq "$runner" "ollama" "production morning-brief.md must declare runner: ollama"
  assert_eq "$tier" "read" "production morning-brief.md must declare tier: read"
  assert_eq "$model" "gemma4:12b-it-qat" "production morning-brief.md must declare model: gemma4:12b-it-qat"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_production_morning_scan_registers_with_ollama_runner() {
  local repo_playbook="$SCRIPT_DIR/../docs/playbooks/morning-scan.md"
  if [ ! -f "$repo_playbook" ]; then
    printf '  FAIL [%s] cannot find production playbook at %q\n' \
      "$CURRENT_TEST" "$repo_playbook"
    FAILS=$((FAILS + 1))
    return
  fi
  cp "$repo_playbook" "$CEO_DIR/playbooks/morning-scan.md"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local runner tier model
  runner=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .runner' "$REGISTRY_FILE" 2>/dev/null || echo "")
  tier=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .tier' "$REGISTRY_FILE" 2>/dev/null || echo "")
  model=$(jq -r '.playbooks[] | select(.name=="morning-scan") | .model' "$REGISTRY_FILE" 2>/dev/null || echo "")
  assert_eq "$runner" "ollama" "production morning-scan.md must declare runner: ollama"
  assert_eq "$tier" "read" "production morning-scan.md must declare tier: read"
  assert_eq "$model" "gemma4:12b-it-qat" "production morning-scan.md must declare model: gemma4:12b-it-qat"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_prepends_user_tool_prefixes() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_detect_os() { echo "macos"; }
    ceo_augment_path
    echo "$PATH"
  ')
  assert_contains "$out" "/fake/.bun/bin"  "PATH must include ~/.bun/bin"
  assert_contains "$out" "/opt/homebrew/bin" "PATH must include Homebrew prefix"
  assert_contains "$out" "/usr/local/bin"   "PATH must include /usr/local/bin"
  assert_contains "$out" "/fake/.local/bin"  "PATH must include ~/.local/bin"
  assert_contains "$out" "/usr/bin"         "original PATH must be preserved"

  local first_segment="${out%%:*}"
  assert_eq "$first_segment" "/fake/.bun/bin" "augmented prefix must be FIRST on PATH"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_idempotent() {
  local out
  out=$(env HOME=/fake bash -c '
    set -uo pipefail
    PATH=/usr/bin:/bin
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_detect_os() { echo "macos"; }
    ceo_augment_path; first="$PATH"
    ceo_augment_path; second="$PATH"
    [ "$first" = "$second" ] && echo idempotent || echo diverged
  ')
  assert_eq "$out" "idempotent" "ceo_augment_path must not drift PATH on repeated calls"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_augment_path_empty_home_aborts() {
  local rc=0
  HOME="" bash -c '
    source '"$SCRIPT_DIR"'/ceo-config.sh
    ceo_augment_path
  ' >/dev/null 2>&1 || rc=$?
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] expected non-zero rc with HOME="", got 0\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_cron_invokes_ceo_augment_path_at_dispatch() {
  cat > "$CEO_DIR/playbooks/path-strip.md" << 'PB'
---
name: path-strip
description: stripped-PATH wiring guard
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" path-strip >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo-cron must invoke ceo_augment_path so dispatcher resolves binaries under stripped PATH"
  assert_file_exists "$HOME/claude-invoked.txt" "claude stub must fire (proves PATH augmentation reached dispatcher)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_writes_schema_version_3() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: schema-version regression seed
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local v
  v=$(jq -r '.schema_version // "missing"' "$REGISTRY_FILE")
  assert_eq "$v" "3" "playbook scan must write schema_version=3 into registry.json"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_refuses_newer_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: schema-version downgrade guard
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  printf '{"schema_version":99,"future_field":"must-stay","playbooks":[]}\n' \
    > "$REGISTRY_FILE"
  local before
  before=$(cat "$REGISTRY_FILE")

  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook scan must refuse to overwrite newer registry schema"

  local after
  after=$(cat "$REGISTRY_FILE")
  assert_eq "$after" "$before" "newer registry content must remain unchanged"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cron_skips_on_missing_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq 'del(.schema_version)' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  # RETRY_SLEEP=0: a missing schema_version is code 3 (malformed/transient), so
  # the preflight re-reads once before failing. A persistently-missing field
  # survives the retry and still trips the gate.
  local rc=0
  CEO_REGISTRY_RETRY_SLEEP=0 bash "$CRON" example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cron must exit 1 when registry has no schema_version (after retry)"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "schema_version" "cron-skips.log must record schema_version reason"
  assert_contains "$skips_log" "jq parse:" "code-3 path must capture a registry diagnostic for the next occurrence"

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "schema gate failure must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude must NOT fire when schema gate trips\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cron_skips_on_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  jq '.schema_version = 1' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  bash "$CRON" example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cron must exit 1 when registry schema_version is below current"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "schema_version" "cron-skips.log must record schema_version reason"

  local fails
  fails=$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null || echo "missing")
  assert_eq "$fails" "1" "schema gate failure must increment FAIL_COUNT_FILE"

  if [ -f "$HOME/claude-invoked.txt" ]; then
    printf '  FAIL [%s] claude must NOT fire when schema gate trips\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_list_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  bash "$CEO_CLI" playbook list >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook list must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_info_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  bash "$CEO_CLI" playbook info example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "playbook info must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cmd_chat_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  bash "$CEO_CLI" chat example >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cmd_chat must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_cmd_preflight_rejects_old_schema_version() {
  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: noop
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  jq '.schema_version = 1' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"

  local rc=0
  bash "$CEO_CLI" preflight >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "cmd_preflight must reject old registry schema"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_script_missing_script_field_fails() {
  cat > "$CEO_DIR/playbooks/bad-intake.md" << 'PB'
---
name: bad-intake
description: runner:script without script field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
---
PB

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  local rc=0
  CEO_VERBOSE=1 bash "$CRON" bad-intake >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "missing-script field must exit 1"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "runner:script but no script field" "missing-script error must be logged"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_blocks_non_primary_host() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0 out
  out=$(CEO_HOSTNAME=beta bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "non-primary host must be refused"
  assert_contains "$out" "primary host" "error must mention primary host gating"
  if [ -f "$REGISTRY_FILE" ]; then
    printf '  FAIL [%s] non-primary host wrote registry.json (must not)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_succeeds_on_primary_host() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0
  CEO_HOSTNAME=alpha bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "primary host must be allowed to scan"
  assert_file_exists "$REGISTRY_FILE" "registry must be written by primary host"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_unrestricted_when_primary_host_unset() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{}\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0
  CEO_HOSTNAME=anyhost bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "no primary_host setting → backward-compatible (any host can scan)"
  assert_file_exists "$REGISTRY_FILE" "registry must be written when no gate is configured"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_typoed_primary_host_field_emits_warning() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"promary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0 out
  out=$(CEO_HOSTNAME=beta bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "0" "typo'd key falls through to no-gate (backward-compat) but must warn"
  assert_contains "$out" "unknown key 'promary_host'" "typo'd key must surface a warning so operator notices"
  assert_file_exists "$REGISTRY_FILE" "scan continues despite typo (gate is not configured from parser's view)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_malformed_settings_json_fails_loud() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf 'not valid json\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0 out
  out=$(CEO_HOSTNAME=anyhost bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "malformed settings.json must fail loud, not silently fall through"
  assert_contains "$out" "not valid JSON" "error must name the JSON parse failure"
  if [ -f "$REGISTRY_FILE" ]; then
    printf '  FAIL [%s] registry written despite malformed settings.json\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_missing_jq_with_settings_fails_loud() {
  cat > "$CEO_DIR/playbooks/probe.md" << 'PB'
---
name: probe
description: probe
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  printf '{"primary_host":"alpha"}\n' > "$CEO_DIR/settings.json"
  rm -f "$REGISTRY_FILE"

  local rc=0 out
  out=$(CEO_JQ_BIN=jq-deliberately-missing-for-test CEO_HOSTNAME=anyhost \
        bash "$CEO_CLI" playbook scan 2>&1) || rc=$?
  assert_eq "$rc" "1" "missing jq with settings.json must fail loud"
  assert_contains "$out" "jq is not installed" "error must name the missing dependency"
  if [ -f "$REGISTRY_FILE" ]; then
    printf '  FAIL [%s] registry written despite missing-jq error\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_preserves_user_installed_bins() {
  mkdir -p "$HOME/.local/bin"
  ln -s "$SCRIPT_DIR/count-blessings.sh" "$HOME/.local/bin/count-blessings"
  ln -s "$SCRIPT_DIR/ceo" "$HOME/.local/bin/ceo"

  cat > "$CEO_DIR/playbooks/example.md" << 'PB'
---
name: example
description: regression seed — no bin declared
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] playbook scan removed user-installed count-blessings symlink\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ ! -L "$HOME/.local/bin/ceo" ]; then
    printf '  FAIL [%s] playbook scan removed user-installed ceo symlink\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_creates_and_prunes_declared_bin() {
  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: declares a bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
bin: count-blessings.sh
---
PB
  mkdir -p "$HOME/.local/bin"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] declared bin should be symlinked\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
    return
  fi

  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: dropped the bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] previously-managed bin should be pruned when playbook drops it\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_prunes_dropped_bin_but_keeps_user_bins() {
  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: declares a bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
bin: count-blessings.sh
---
PB
  mkdir -p "$HOME/.local/bin"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ ! -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] declared bin should be symlinked on first scan\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
    return
  fi

  ln -s "$SCRIPT_DIR/ceo" "$HOME/.local/bin/ceo"

  cat > "$CEO_DIR/playbooks/blessings-cli.md" << 'PB'
---
name: blessings-cli
description: dropped the bin
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  if [ -L "$HOME/.local/bin/count-blessings" ]; then
    printf '  FAIL [%s] manifest-driven prune should remove dropped bin\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [ ! -L "$HOME/.local/bin/ceo" ]; then
    printf '  FAIL [%s] user-installed ceo symlink should survive prune\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

_write_pending_drip_registry() {
  cat > "$CEO_DIR/playbooks/pending-drip.md" << 'PB'
---
name: pending-drip
description: Test pending drip
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: has_pending_items
tier: read
status: active
---
PB
  cat > "$REGISTRY_FILE" << JSON
{"schema_version":3,"playbooks":[{"name":"pending-drip","file":"$CEO_DIR/playbooks/pending-drip.md","model":"haiku","preflight":"has_pending_items","trigger":"cron","tier":"read","status":"active"}]}
JSON
  printf -- '- [ ] pending approval sentinel\n' > "$CEO_DIR/approvals/pending.md"
  printf -- '- [ ] **file:** sentinel.md **question:** sentinel ask?\n' > "$CEO_VAULT/Pending.md"
}

_stub_claude_log_entry() {
  local status="$1"
  local output="$2"
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
#!/bin/bash
cat >/dev/null
cat <<'OUT'
LOG_ENTRY:
## 12:00 - pending-drip
**Status:** $status
**Playbook:** pending-drip.md
**Output:**
$output
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}

test_pending_drip_success_appends_host_inbox_not_report() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local inbox report
  inbox="$CEO_DIR/inbox/testhost.md"
  report="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  assert_file_exists "$inbox" "pending-drip must append to per-host inbox"
  local body
  body=$(cat "$inbox" 2>/dev/null)
  assert_contains "$body" "- [ ] Review pending drip for" "pending-drip inbox item must be unchecked"
  assert_contains "$body" "<!-- pending-drip:" "pending-drip inbox item must include dedupe marker"
  assert_contains "$body" "What is the pending question?" "pending-drip inbox item must include question context"
  if [ -f "$report" ]; then
    printf '  FAIL [%s] successful pending-drip must not append to daily report\n    report: %q\n' "$CURRENT_TEST" "$report"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_rerun_is_idempotent() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true
  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local count
  count=$(grep -c -F "<!-- pending-drip:" "$CEO_DIR/inbox/testhost.md" 2>/dev/null || echo 0)
  assert_eq "$count" "1" "same-day pending-drip rerun must not append duplicate inbox item"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_append_preserves_task_start_after_missing_newline() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "**Questions to ask Nathan:**
- [from Pending.md] What is the pending question?"
  mkdir -p "$CEO_DIR/inbox"
  printf -- '- [done] prior item without newline' > "$CEO_DIR/inbox/testhost.md"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local task_count
  task_count=$(grep -c '^- \[ \] Review pending drip' "$CEO_DIR/inbox/testhost.md" 2>/dev/null || echo 0)
  assert_eq "$task_count" "1" "pending-drip append must start on a new line"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_failed_entry_uses_report_not_inbox() {
  _write_pending_drip_registry
  _stub_claude_log_entry "failed" "Something failed"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local inbox report report_body
  inbox="$CEO_DIR/inbox/testhost.md"
  report="$CEO_DIR/reports/$(date +%Y-%m-%d).md"
  if [ -s "$inbox" ]; then
    printf '  FAIL [%s] failed pending-drip must not create inbox task\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$inbox")"
    FAILS=$((FAILS + 1))
  fi
  assert_file_exists "$report" "failed pending-drip must use normal report path"
  report_body=$(cat "$report" 2>/dev/null)
  assert_contains "$report_body" "Something failed" "failed pending-drip report must include failure output"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_skips_when_pending_md_empty() {
  _write_pending_drip_registry
  # Setup line 32 + helper line 1885 leave $CEO_DIR/approvals/pending.md
  # populated (PENDING_COUNT > 0). Remove Pending.md so PENDING_ASK_QUESTIONS
  # is empty — this is the literal bug shape that motivated the fix at
  # scripts/ceo-cron.sh:369. Reverting that gate must make this test fail.
  rm -f "$CEO_VAULT/Pending.md"
  _stub_claude_log_entry "completed" "should never run"

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  local skip_log="$CEO_DIR/log/cron-skips.log"
  assert_file_exists "$skip_log" "preflight skip must write cron-skips.log"
  local skip_body
  skip_body=$(cat "$skip_log" 2>/dev/null)
  assert_contains "$skip_body" "preflight 'has_pending_items' returned no-work" \
    "empty Pending.md must trigger preflight no-work skip even when approvals/pending.md is populated"

  if [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] empty Pending.md must not produce inbox entry\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox/testhost.md")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pending_drip_no_relevant_questions_suppresses_inbox() {
  _write_pending_drip_registry
  _stub_claude_log_entry "completed" "No relevant [ask] questions today."

  CEO_HOSTNAME=testhost CEO_FORCE=1 bash "$CRON" pending-drip >/dev/null 2>&1 || true

  if [ -s "$CEO_DIR/inbox/testhost.md" ]; then
    printf '  FAIL [%s] no-relevant pending-drip must not create inbox task\n    inbox: %q\n' "$CURRENT_TEST" "$(cat "$CEO_DIR/inbox/testhost.md")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# --- inputs: per-playbook injection filter (0.11.0) ---

# Helper: stub claude to capture stdin (the SINGLE_PROMPT) for inspection.
# Removes any prior capture file so a stale read can't pass an assertion if
# the run errors out before the stub fires.
_stub_claude_capture_stdin() {
  rm -f "$HOME/claude-stdin.txt" "$HOME/claude-invoked.txt"
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat > "$HOME/claude-stdin.txt"
echo "claude-fired" > "$HOME/claude-invoked.txt"
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}

test_inputs_absent_injects_all_blocks() {
  cat > "$CEO_DIR/playbooks/inputs-default.md" << 'PB'
---
name: inputs-default
description: No inputs field — should get all blocks
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-default >/dev/null 2>&1 || true

  assert_file_exists "$HOME/claude-stdin.txt" "claude must have been invoked"
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "Pending approvals:" "default-all: pending_count line present"
  assert_contains "$prompt" "PRs requesting review:" "default-all: pr_data line present"
  assert_contains "$prompt" "PR data (recently merged):" "default-all: merged-PR line present (#163)"
  assert_contains "$prompt" "Briefing-specific training" "default-all: briefings_training block present"
  assert_contains "$prompt" "Active Domains priority order" "default-all: active_domains block present"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inputs_empty_array_excludes_all_blocks() {
  cat > "$CEO_DIR/playbooks/inputs-empty.md" << 'PB'
---
name: inputs-empty
description: inputs:[] explicitly opts out of all gather blocks
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs: []
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-empty >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  if [[ "$prompt" == *"Pending approvals:"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress pending_count line\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Briefing-specific training"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress briefings_training block\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"PRs requesting review:"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress pr_data lines\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"PR data (recently merged):"* ]]; then
    printf '  FAIL [%s] inputs:[] should suppress the merged-PR line (#163)\n' "$CURRENT_TEST"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_plan_prompt_carries_merged_pr_data() {
  cat > "$CEO_DIR/playbooks/plan-merged.md" << 'PB'
---
name: plan-merged
description: high-stakes playbook — PLAN prompt must carry the merged-PR data (#163)
trigger: cron
schedule: "0 9 * * *"
model: sonnet
preflight: none
tier: high-stakes
status: active
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" plan-merged --dry-run --depth plan >/dev/null 2>&1 || true

  assert_file_exists "$HOME/claude-stdin.txt" "PLAN phase must invoke the model"
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "PR data (recently merged):" "PLAN prompt must carry merged-PR data — reconcile classifies in PLAN (#163)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inputs_subset_includes_only_listed() {
  cat > "$CEO_DIR/playbooks/inputs-subset.md" << 'PB'
---
name: inputs-subset
description: Only pr_data and blessings — others must be absent
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs:
  - pr_data
  - blessings
---
PB

  _stub_claude_capture_stdin
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  CEO_VERBOSE=1 bash "$CRON" inputs-subset >/dev/null 2>&1 || true

  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "PRs requesting review:" "subset: pr_data line present"
  if [[ "$prompt" == *"Briefing-specific training"* ]]; then
    printf '  FAIL [%s] subset: briefings_training must be absent (not in inputs list)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Pending approvals:"* ]]; then
    printf '  FAIL [%s] subset: pending_count must be absent (not in inputs list)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if [[ "$prompt" == *"Active Domains priority order"* ]]; then
    printf '  FAIL [%s] subset: active_domains must be absent\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inputs_unknown_key_warns_at_scan() {
  cat > "$CEO_DIR/playbooks/inputs-typo.md" << 'PB'
---
name: inputs-typo
description: Has a typo'd input key
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs:
  - pr_data
  - bogus_key
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "unknown key" "scan must warn on typo'd input key"
  assert_contains "$out" "bogus_key" "warning must name the offending key"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inputs_non_array_warns_and_defaults_to_all() {
  cat > "$CEO_DIR/playbooks/inputs-scalar.md" << 'PB'
---
name: inputs-scalar
description: Inputs is a scalar — should warn and default to all
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
inputs: pr_data
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be an array" "scan must warn when inputs is not an array"

  # Default-all behavior should hold — verify by running and checking the prompt
  _stub_claude_capture_stdin
  CEO_VERBOSE=1 bash "$CRON" inputs-scalar >/dev/null 2>&1 || true
  local prompt
  prompt=$(cat "$HOME/claude-stdin.txt" 2>/dev/null)
  assert_contains "$prompt" "Briefing-specific training" "non-array inputs must default to all (briefings present)"
  assert_contains "$prompt" "PRs requesting review:" "non-array inputs must default to all (pr_data present)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_repo_playbook_auto_registers_with_absolute_file_path() {
  local repo_dir="$TEST_HOME/repo-pb"
  local repo_pb="$repo_dir/_test-repo-pb.md"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"
  cat > "$repo_pb" << 'PB'
---
name: _test-repo-pb
description: Repo-side playbook for scan test
trigger: chat
preflight: none
tier: read
status: active
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "ADD   _test-repo-pb" "repo playbook must be picked up by scan"

  local file_field
  file_field=$(jq -r '.playbooks[] | select(.name=="_test-repo-pb") | .file' "$REGISTRY_FILE")
  assert_eq "${file_field:0:1}" "/" "repo playbook .file must be absolute"
  assert_contains "$file_field" "_test-repo-pb.md" "repo playbook .file must point at repo path"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_vault_playbook_shadows_repo_playbook_with_same_name() {
  local repo_dir="$TEST_HOME/repo-pb"
  local repo_pb="$repo_dir/_test-shadow.md"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"
  cat > "$repo_pb" << 'PB'
---
name: _test-shadow
description: Repo version
trigger: chat
preflight: none
tier: read
status: active
---
PB

  cat > "$CEO_DIR/playbooks/_test-shadow.md" << 'PB'
---
name: _test-shadow
description: Vault override
trigger: chat
preflight: none
tier: read
status: disabled
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "SHADOW" "scan must report shadowing"

  local desc status
  desc=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .description' "$REGISTRY_FILE")
  status=$(jq -r '.playbooks[] | select(.name=="_test-shadow") | .status' "$REGISTRY_FILE")
  assert_eq "$desc" "Vault override" "vault entry must win on collision"
  assert_eq "$status" "disabled" "vault status must override repo status"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_repo_internal_duplicate_logs_dup_not_shadow() {
  local repo_dir="$TEST_HOME/repo-pb"
  mkdir -p "$repo_dir"
  export CEO_REPO_PLAYBOOK_DIR="$repo_dir"

  cat > "$repo_dir/_test-twin-a.md" << 'PB'
---
name: _test-twin
description: First repo file
trigger: chat
preflight: none
tier: read
status: active
---
PB
  cat > "$repo_dir/_test-twin-b.md" << 'PB'
---
name: _test-twin
description: Second repo file
trigger: chat
preflight: none
tier: read
status: active
---
PB

  local out
  out=$(bash "$CEO_CLI" playbook scan 2>&1)
  unset CEO_REPO_PLAYBOOK_DIR

  assert_contains "$out" "DUP" "two repo files with same name must log DUP"
  if [[ "$out" == *"SHADOW"* ]]; then
    printf '  FAIL [%s] repo-internal dup must NOT log SHADOW (no vault override exists)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_rate_limit_falls_back_to_ollama_on_read_tier() {
  cat > "$CEO_DIR/playbooks/ratelimit.md" << 'PB'
---
name: ratelimit
description: hit the limit
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # Stub claude to return rate limit exit code and text
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "You've hit your session limit · resets 5:10am (America/New_York)"
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  local rc=0
  bash "$CRON" ratelimit >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 after falling back to ollama"
  
  local skip_log
  skip_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skip_log" "Falling back to ollama" "cron-skips.log must mention fallback"
  
  local ollama_invoked
  ollama_invoked=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_contains "$ollama_invoked" "gemma4" "ollama must be invoked with default model during fallback"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_claude_rate_limit_fallback_ignores_claude_model_frontmatter() {
  # Regression: a runner:claude playbook with model:haiku|sonnet (Claude tier
  # name) must NOT pass that name through to `ollama run` when the rate-limit
  # fallback flips RUNNER to ollama. The invariant is "rate-limit fallback is
  # 100% ollama-mapped"; frontmatter model overrides apply only to native
  # runner:ollama playbooks, not to a runtime-flipped runner.
  cat > "$CEO_DIR/playbooks/ratelimit-haiku.md" << 'PB'
---
name: ratelimit-haiku
description: claude-tier playbook that declares model:haiku
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "You've hit your session limit · resets 5:10am (America/New_York)"
exit 1
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  local rc=0
  bash "$CRON" ratelimit-haiku >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 after falling back to ollama"

  local model
  model=$(cat "$HOME/ollama-invoked-model.txt" 2>/dev/null || echo "")
  assert_eq "$model" "gemma4:12b-it-qat" "fallback must use the runner-default ollama model, not the Claude-tier frontmatter name"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_cron_skips_read_tier_on_failed_gather() {
  cat > "$CEO_DIR/playbooks/morning-brief.md" << 'PB'
---
name: morning-brief
description: briefing
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
# noop
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  # Force gather phase to fail by emptying pending tasks
  : > "$CEO_DIR/approvals/pending.md"

  local rc=0
  bash "$CRON" morning-brief >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "cron must exit 0 on failed gather"
  
  local skip_log
  skip_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skip_log" "Gather phase empty" "cron-skips.log must mention gather phase empty"
  
  local report
  report=$(cat "$CEO_DIR/reports/$(date +%Y-%m-%d).md" 2>/dev/null || echo "")
  assert_contains "$report" "skipped: gather-empty" "report must show skipped status"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_located_and_success() {
  cat > "$CEO_DIR/playbooks/skill-success.md" << 'PB'
---
name: skill-success
description: skill executes successfully
trigger: cron
status: active
tier: read
runner: skill
skill: test-skill
out_pattern: CEO/reports/test/${TODAY}-${HOSTNAME}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/test-skill/scripts"
  cat > "$HOME/.claude/skills/test-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
echo "test-skill output" > "$out_dir/report.md"
EOF
  chmod +x "$HOME/.claude/skills/test-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-success >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "runner:skill must exit 0 on success"

  local expected_out
  expected_out="$CEO_DIR/reports/test/$(date +%Y-%m-%d)-$(hostname -s).md"
  assert_file_exists "$expected_out" "runner:skill must write to interpolated out_pattern"
  local content
  content=$(cat "$expected_out" 2>/dev/null || echo "")
  assert_contains "$content" "test-skill output" "runner:skill must capture skill stdout"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_missing_skill_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-missing.md" << 'PB'
---
name: skill-missing
description: skill script does not exist
trigger: cron
status: active
tier: read
runner: skill
skill: nonexistent-skill
out_pattern: CEO/reports/test/missing.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-missing >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill is missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill script not found" "skips log must record missing skill script"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_missing_credential_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-creds.md" << 'PB'
---
name: skill-creds
description: skill missing required credential
trigger: cron
status: active
tier: read
runner: skill
skill: test-skill
out_pattern: CEO/reports/test/creds.md
requires: ["MISSING_TEST_VAR"]
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  # Don't create the skill script because we want it to fail on the credential gate
  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-creds >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when credentials are missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "missing credential(s) MISSING_TEST_VAR" "skips log must record missing credential"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_no_output_file_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-noout.md" << 'PB'
---
name: skill-noout
description: skill produces no output file
trigger: cron
status: active
tier: read
runner: skill
skill: noout-skill
out_pattern: CEO/reports/test/noout.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/noout-skill/scripts"
  cat > "$HOME/.claude/skills/noout-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$HOME/.claude/skills/noout-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-noout >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill output is missing"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill produced no output file" "skips log must record missing output file failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_empty_output_records_failure() {
  cat > "$CEO_DIR/playbooks/skill-empty.md" << 'PB'
---
name: skill-empty
description: skill produces empty output
trigger: cron
status: active
tier: read
runner: skill
skill: empty-skill
out_pattern: CEO/reports/test/empty.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/empty-skill/scripts"
  cat > "$HOME/.claude/skills/empty-skill/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
touch "$out_dir/empty.md"
EOF
  chmod +x "$HOME/.claude/skills/empty-skill/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" skill-empty >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "runner:skill must exit 1 when skill output is empty"

  local skips_log
  skips_log=$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "")
  assert_contains "$skips_log" "Skill produced empty output" "skips log must record empty output failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_runner_skill_workload_report_stub_produces_output() {
  cat > "$CEO_DIR/playbooks/workload-report.md" << 'PB'
---
name: workload-report
description: The migrated workload-report playbook
trigger: cron
status: active
tier: read
runner: skill
skill: workload-report
out_pattern: CEO/reports/workload/${TODAY}-${HOSTNAME}.md
---
PB
  "$CEO_CLI" playbook scan >/dev/null

  mkdir -p "$HOME/.claude/skills/workload-report/scripts"
  cat > "$HOME/.claude/skills/workload-report/scripts/run-report.sh" << 'EOF'
#!/bin/bash
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --out) out_dir="$2"; shift ;;
  esac
  shift
done
echo "workload report stub" > "$out_dir/report.md"
EOF
  chmod +x "$HOME/.claude/skills/workload-report/scripts/run-report.sh"

  local rc=0
  PATH=/usr/bin:/bin bash "$CRON" workload-report >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "workload-report skill runner must exit 0"

  local expected_out
  expected_out="$CEO_DIR/reports/workload/$(date +%Y-%m-%d)-$(hostname -s).md"
  assert_file_exists "$expected_out" "workload-report must produce correct interpolated file"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_playbook_scan_succeeds_without_yq() {
  cat > "$CEO_DIR/playbooks/no-yq-test.md" << 'PB'
---
name: no-yq-test
description: Verify scan works without yq
trigger: cron
schedule: "0 9 * * *"
runner: script
script: fake-no-yq.sh
tier: read
status: active
requires: [gh]
---
PB

  # Remove yq from stubbed PATH to simulate a machine without it installed.
  rm -f "$TEST_HOME/.bun/bin/yq"
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo playbook scan must succeed even when yq is not on PATH"
  assert_file_exists "$REGISTRY_FILE" "registry.json must be written without yq"
  local reg_name
  reg_name=$(jq -r '.playbooks[] | select(.name=="no-yq-test") | .name' "$REGISTRY_FILE" 2>/dev/null)
  assert_eq "$reg_name" "no-yq-test" "playbook must be registered without yq"

  # Restore yq stub for subsequent tests.
  cat > "$TEST_HOME/.bun/bin/yq" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/yq"
  rm -f "$CEO_DIR/playbooks/no-yq-test.md"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 3))
}

# --- #137 run-modes: scheduled (cron/daemon, --scheduled) enforces active;
#     manual (default / --manual, on-demand) runs any valid status per
#     docs/playbooks/SCHEMA.md status-semantics. ---

_register_status_playbook() {
  cat > "$CEO_DIR/playbooks/$1.md" << PB
---
name: $1
description: run-mode fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: $2
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
}

test_cron_manual_mode_runs_draft_playbook() {
  _register_status_playbook rm-draft draft
  bash "$CRON" rm-draft --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "manual run of a draft playbook must dispatch"
}

# SCHEMA: bare ceo-cron.sh <name> IS the on-demand path. Default mode is manual,
# so a bare invocation runs a draft. Fails on the old gate and on a default=scheduled impl.
test_cron_default_mode_runs_draft_playbook() {
  _register_status_playbook rm-draft-d draft
  bash "$CRON" rm-draft-d >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "bare (default=manual) run of a draft must dispatch (SCHEMA on-demand)"
}

# SCHEMA: on-demand runs disabled too (explicit human force-run).
test_cron_manual_mode_runs_disabled_playbook() {
  _register_status_playbook rm-disabled disabled
  bash "$CRON" rm-disabled --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "manual run of a disabled playbook must dispatch (SCHEMA on-demand)"
}

test_cron_scheduled_mode_skips_draft_playbook() {
  _register_status_playbook rm-draft2 draft
  bash "$CRON" rm-draft2 --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a draft must NOT dispatch" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "rm-draft2" "draft skip must be logged"
}

test_cron_scheduled_mode_skips_disabled_playbook() {
  _register_status_playbook rm-disabled2 disabled
  bash "$CRON" rm-disabled2 --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a disabled playbook must NOT dispatch" test -f "$HOME/claude-invoked.txt"
}

test_cron_scheduled_mode_runs_active_playbook() {
  _register_status_playbook rm-active active
  bash "$CRON" rm-active --scheduled >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "scheduled run of an active playbook must dispatch"
}

# Missing status: SCHEMA treats it as "not active". The old `// "active"`
# coercion would wrongly run it under --scheduled; it must skip.
test_cron_scheduled_mode_skips_missing_status() {
  cat > "$CEO_DIR/playbooks/rm-nostatus.md" << 'PB'
---
name: rm-nostatus
description: run-mode fixture, no status field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_contains "$(jq -r '.playbooks[].name' "$REGISTRY_FILE" 2>/dev/null)" "rm-nostatus" "missing-status playbook must be registered (so the gate, not a missing entry, is what skips it)"
  bash "$CRON" rm-nostatus --scheduled >/dev/null 2>&1 || true
  assert_fails "scheduled run of a missing-status playbook must NOT dispatch (SCHEMA: missing = not active)" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "not runnable in scheduled mode" "skip must come from the run-mode gate, not a missing registry entry"
}

test_cron_flag_before_trigger_is_accepted() {
  _register_status_playbook rm-order draft
  bash "$CRON" --manual rm-order >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "flags before the trigger must parse (order-independent)"
}

test_cron_rejects_unknown_run_mode_flag() {
  _register_status_playbook rm-active2 active
  local rc=0
  bash "$CRON" rm-active2 --bogus >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "unknown flag must be rejected with non-zero exit"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "unknown" "stderr must explain the rejected flag"
  assert_fails "a rejected invocation must not dispatch" test -f "$HOME/claude-invoked.txt"
}

test_cron_rejects_conflicting_run_modes() {
  _register_status_playbook rm-active3 active
  local rc=0
  bash "$CRON" rm-active3 --scheduled --manual >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "--scheduled and --manual together must be rejected"
  assert_fails "a rejected invocation must not dispatch" test -f "$HOME/claude-invoked.txt"
}

test_cron_rejects_empty_trigger() {
  local rc=0
  bash "$CRON" --manual >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "a flag with no trigger must exit non-zero"
  assert_contains "$(cat "$TEST_HOME/cron-stderr")" "Usage" "stderr must print usage"
}

test_cron_rejects_double_trigger() {
  local rc=0
  bash "$CRON" alpha beta >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "two positional triggers must be rejected"
}

# --force is a manual-only smoke-test escape hatch; it must not weaken the
# runaway-protection invariant on scheduled (cron/daemon) runs.
test_cron_rejects_force_on_scheduled() {
  _register_status_playbook rm-active4 active
  local rc=0
  bash "$CRON" rm-active4 --scheduled --force >/dev/null 2>"$TEST_HOME/cron-stderr" || rc=$?
  assert_eq "$rc" "1" "--force with --scheduled must be rejected"
}

# Isolate --force: all three runs are manual+active, so only --force can explain
# the third dispatch surviving the cooldown.
test_cron_force_flag_bypasses_cooldown() {
  _register_status_playbook rm-cool active
  bash "$CRON" rm-cool --manual >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "first run must dispatch and record last-run"
  rm -f "$HOME/claude-invoked.txt"
  bash "$CRON" rm-cool --manual >/dev/null 2>&1 || true
  assert_fails "second manual run within cooldown must be skipped" test -f "$HOME/claude-invoked.txt"
  bash "$CRON" rm-cool --manual --force >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "--force must bypass the per-trigger cooldown"
}

# The catch-all arm must skip an out-of-set status (hand-edited registry) AND emit
# its distinct diagnostic — not the message any non-active status produced under
# the old gate (that would be a tautology passing on pre-change code).
test_cron_catchall_skips_unknown_status() {
  _register_status_playbook rm-weird active
  local reg="$REGISTRY_FILE"
  jq '(.playbooks[] | select(.name=="rm-weird") | .status) = "bogus"' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  bash "$CRON" rm-weird --manual >/dev/null 2>&1 || true
  assert_fails "out-of-set status must never dispatch (defense-in-depth catch-all)" test -f "$HOME/claude-invoked.txt"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "unexpected run-mode:status" "catch-all must emit its distinct diagnostic"
}

# --- #138: --dry-run preview mode ---
# Preview file lives in non-synced host-local scratch: $CEO_DIR/log/preview/<trigger>-<TODAY>.md
_preview_file() { echo "$CEO_DIR/log/preview/$1-$(date +%Y-%m-%d).md"; }

# A runner:script playbook in dry-run must NOT exec the script; it previews the
# would-run command instead. This is the core "show what would happen, do nothing".
test_dry_run_script_runner_skips_exec_and_previews() {
  cat > "$CEO_DIR/playbooks/dr-script.md" << 'PB'
---
name: dr-script
description: dry-run script fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: dr-script.sh
---
PB
  cat > "$SCRIPT_DIR/dr-script.sh" << SH
#!/bin/bash
echo "ran" > "$TEST_HOME/dr-script-fired.txt"
SH
  chmod +x "$SCRIPT_DIR/dr-script.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-script --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must NOT exec the script" test -f "$TEST_HOME/dr-script-fired.txt"
  local pf; pf=$(_preview_file dr-script)
  assert_file_exists "$pf" "dry-run must write a preview file"
  assert_contains "$(cat "$pf" 2>/dev/null)" "dr-script.sh" "preview must name the would-run script"

  rm -f "$SCRIPT_DIR/dr-script.sh"
}

# Cooldown integrity: a dry-run must not stamp .last-run, or it would silently
# suppress the next real scheduled run.
test_dry_run_does_not_write_last_run() {
  _register_status_playbook dr-nolastrun active
  bash "$CRON" dr-nolastrun --dry-run >/dev/null 2>&1 || true
  assert_fails "dry-run must not write the .last-run stamp" test -f "$CEO_DIR/log/.last-run-dr-nolastrun"
  assert_file_exists "$(_preview_file dr-nolastrun)" "dry-run must still produce a preview"
}

# A dry-run must bypass the per-trigger cooldown so it can be run iteratively
# right after a real run.
test_dry_run_bypasses_cooldown() {
  _register_status_playbook dr-cool active
  bash "$CRON" dr-cool --manual >/dev/null 2>&1 || true
  assert_file_exists "$CEO_DIR/log/.last-run-dr-cool" "real run must stamp last-run"
  bash "$CRON" dr-cool --dry-run >/dev/null 2>&1 || true
  assert_file_exists "$(_preview_file dr-cool)" "dry-run must run despite a recent real run (cooldown bypassed)"
}

# read-tier dry-run: the read-only model call may happen, but its output is
# routed to the preview file — NOT posted to Discord and NOT recorded as a run.
test_dry_run_read_tier_no_discord_and_previews_output() {
  cat > "$CEO_DIR/playbooks/dr-read.md" << 'PB'
---
name: dr-read
description: dry-run read fixture
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: none
tier: read
status: active
---
PB
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — dr-read
**Status:** completed
**Playbook:** playbooks/dr-read.md
**Output:**
Preview body from the read model.
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$HOME/.bun/bin/claude"

  mkdir -p "$TEST_HOME/curl"
  export CURL_CAPTURE_DIR="$TEST_HOME/curl"
  cat > "$HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
out="$CURL_CAPTURE_DIR/payload.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) shift; printf '%s' "$1" > "$out" ;;
  esac
  shift || true
done
exit 0
STUB
  chmod +x "$HOME/.bun/bin/curl"
  mkdir -p "$HOME/.config/claude-ceo"
  echo '{"discord_report_webhook":"http://127.0.0.1/report-channel"}' > "$HOME/.config/claude-ceo/secrets.json"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dr-read --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must not post to Discord" test -f "$CURL_CAPTURE_DIR/payload.json"
  local pf; pf=$(_preview_file dr-read)
  assert_contains "$(cat "$pf" 2>/dev/null)" "Preview body from the read model." "preview must capture the model output"
  assert_not_contains "$(cat "$CEO_DIR/log/cron-runs.log" 2>/dev/null)" "dr-read completed" "dry-run must not append to cron-runs.log"
  assert_fails "dry-run must not create the synced daily log file CEO/log/<TODAY>.md" test -f "$CEO_DIR/log/$(date +%Y-%m-%d).md"

  unset CURL_CAPTURE_DIR
}

# tier:write dry-run: PLAN runs (read-only) but EXECUTE is skipped, and the
# high-stakes proposal is previewed rather than appended to the approvals queue.
test_dry_run_write_tier_skips_execute_and_pending() {
  cat > "$CEO_DIR/playbooks/dr-write.md" << 'PB'
---
name: dr-write
description: dry-run write fixture
trigger: cron
schedule: "0 9 * * *"
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
echo "ACTION: 1 | high-stakes | deploy the thing | gh deploy"
echo "ACTION: 2 | read | check the status | n/a"
STUB
  chmod +x "$HOME/.bun/bin/claude"

  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  bash "$CRON" dr-write --dry-run >/dev/null 2>&1 || true

  assert_eq "$(wc -l < "$HOME/claude-calls.log" 2>/dev/null | tr -d ' ')" "1" "dry-run tier:write must run PLAN only — EXECUTE must be skipped"
  assert_fails "write-tier dry-run must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-write"
  assert_not_contains "$(cat "$CEO_DIR/approvals/pending.md" 2>/dev/null)" "deploy the thing" "dry-run must not append high-stakes proposals to the approvals queue"
  local pf; pf=$(_preview_file dr-write)
  assert_contains "$(cat "$pf" 2>/dev/null)" "deploy the thing" "preview must list the deferred high-stakes action"
  assert_contains "$(cat "$pf" 2>/dev/null)" "check the status" "preview must list the safe action that would execute"
}

# runner:skill in dry-run must NOT exec the skill or write its out_pattern;
# it previews the would-run skill instead.
test_dry_run_skill_runner_skips_exec_and_previews() {
  cat > "$CEO_DIR/playbooks/dr-skill.md" << 'PB'
---
name: dr-skill
description: dry-run skill fixture
trigger: cron
status: active
tier: read
runner: skill
skill: dr-skill-test
out_pattern: CEO/reports/test/dr-skill-out.md
---
PB
  mkdir -p "$HOME/.claude/skills/dr-skill-test/scripts"
  cat > "$HOME/.claude/skills/dr-skill-test/scripts/run-report.sh" << EOF
#!/bin/bash
echo "ran" > "$TEST_HOME/dr-skill-fired.txt"
EOF
  chmod +x "$HOME/.claude/skills/dr-skill-test/scripts/run-report.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-skill --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must NOT exec the skill" test -f "$TEST_HOME/dr-skill-fired.txt"
  assert_fails "dry-run must NOT write the skill out_pattern" test -f "$CEO_DIR/reports/test/dr-skill-out.md"
  assert_contains "$(cat "$(_preview_file dr-skill)" 2>/dev/null)" "dr-skill-test" "preview must name the would-run skill"
}

# When a dry-run hits a preflight that returns no-work, it must preview the skip
# WITHOUT stamping .last-run (a real run stamps it; a dry-run must not).
test_dry_run_preflight_no_work_does_not_stamp_last_run() {
  cat > "$CEO_DIR/playbooks/dr-pf.md" << 'PB'
---
name: dr-pf
description: dry-run preflight fixture
trigger: cron
schedule: "0 9 * * *"
preflight: has_pending_items
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  # has_pending_items is false (no PENDING_ASK_QUESTIONS), so preflight returns no-work.
  bash "$CRON" dr-pf --dry-run >/dev/null 2>&1 || true
  assert_fails "dry-run preflight-skip must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-pf"
  assert_contains "$(cat "$(_preview_file dr-pf)" 2>/dev/null)" "no-work" "preview must record the preflight no-work skip"
}

# The preview dir lives under CEO/log/, which is a SYNCED vault tree (only the
# dotfiles in shared.stignore are host-local). For the preview to be the
# host-local scratch the design promises, CEO/log/preview/ must be excluded from
# sync — otherwise a dry-run on one host propagates its preview to every host.
test_dry_run_preview_dir_excluded_from_sync() {
  local stignore="$SCRIPT_DIR/../syncthing/shared.stignore"
  assert_file_exists "$stignore" "shared.stignore must exist"
  assert_contains "$(cat "$stignore" 2>/dev/null)" "CEO/log/preview/" "preview dir must be stignored so dry-run output stays host-local"
}

# Dry-run is allowed under --scheduled (e.g. a daemon smoke-test) but must warn,
# so a cron stuck in dry-run is observable rather than silently doing nothing.
test_dry_run_under_scheduled_warns() {
  _register_status_playbook dr-sched active
  bash "$CRON" dr-sched --scheduled --dry-run >/dev/null 2>&1 || true
  assert_file_exists "$(_preview_file dr-sched)" "dry-run under scheduled must still preview"
  assert_contains "$(cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null)" "dry-run" "a dry-run under --scheduled must emit a WARN"
}

# Failure path: a dry-run that hits a failure must NOT increment the fail-count,
# stamp .last-run, fire the pending alert, or notify — it previews the would-fail.
# (read-tier claude exit 1 reaches _record_failure.)
test_dry_run_failure_path_has_no_side_effects() {
  _register_status_playbook dr-fail active
  echo 3 > "$CEO_DIR/log/.fail-count"
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
exit 1
STUB
  chmod +x "$HOME/.bun/bin/claude"

  bash "$CRON" dr-fail --dry-run >/dev/null 2>&1 || true

  assert_eq "$(cat "$CEO_DIR/log/.fail-count" 2>/dev/null)" "3" "dry-run failure must not increment the fail-count"
  assert_fails "dry-run failure must not stamp .last-run" test -f "$CEO_DIR/log/.last-run-dr-fail"
  assert_contains "$(cat "$(_preview_file dr-fail)" 2>/dev/null)" "Would record FAILURE" "preview must record the would-be failure"
}

# pending-drip writes to the host inbox (a CEO decision-state mutation). A dry-run
# must preview that instead of mutating the inbox.
test_dry_run_pending_drip_does_not_write_inbox() {
  cat > "$CEO_DIR/playbooks/pending-drip.md" << 'PB'
---
name: pending-drip
description: dry-run pending-drip fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  cat > "$HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
LOG_ENTRY:
## 09:00 — pending-drip
**Status:** completed
**Playbook:** playbooks/pending-drip.md
**Output:**
- A genuine pending question to surface.
**Errors:**
- none
END_LOG_ENTRY
OUT
STUB
  chmod +x "$HOME/.bun/bin/claude"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" pending-drip --dry-run >/dev/null 2>&1 || true

  assert_fails "dry-run must not create the host inbox" test -d "$CEO_DIR/inbox"
  assert_contains "$(cat "$(_preview_file pending-drip)" 2>/dev/null)" "inbox" "preview must note the would-be inbox append"
}

# _preview truncates the per-day file on the first write of each run, so a second
# dry-run of the same trigger/day REPLACES rather than appends.
test_dry_run_preview_truncates_per_run() {
  cat > "$CEO_DIR/playbooks/dr-trunc.md" << 'PB'
---
name: dr-trunc
description: dry-run truncation fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
runner: script
script: dr-trunc.sh
---
PB
  cat > "$SCRIPT_DIR/dr-trunc.sh" << 'SH'
#!/bin/bash
true
SH
  chmod +x "$SCRIPT_DIR/dr-trunc.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1

  bash "$CRON" dr-trunc --dry-run >/dev/null 2>&1 || true
  bash "$CRON" dr-trunc --dry-run >/dev/null 2>&1 || true

  assert_eq "$(grep -c '# DRY-RUN preview' "$(_preview_file dr-trunc)" 2>/dev/null | tr -d ' ')" "1" "a re-run must replace the preview, not append a second header"

  rm -f "$SCRIPT_DIR/dr-trunc.sh"
}

# --- #139: hosts: frontmatter (host-scoped scheduling, recorded not enforced) ---
_hosts_in_registry() {
  jq -r --arg n "$1" '.playbooks[] | select(.name==$n) | .hosts | tojson' "$REGISTRY_FILE" 2>/dev/null
}

# Absent hosts → recorded as ["*"] (all hosts), the backward-compatible default.
test_hosts_absent_defaults_to_wildcard() {
  cat > "$CEO_DIR/playbooks/h-absent.md" << 'PB'
---
name: h-absent
description: no hosts field
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-absent)" '["*"]' "absent hosts must default to [\"*\"]"
}

# Explicit flow-sequence host list is recorded verbatim.
test_hosts_explicit_list_recorded() {
  cat > "$CEO_DIR/playbooks/h-list.md" << 'PB'
---
name: h-list
description: explicit host list
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", "mac-mini"]
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-list)" '["ml-1","mac-mini"]' "explicit hosts list must be recorded verbatim"
}

# Block-sequence YAML form is parsed identically.
test_hosts_block_sequence_recorded() {
  cat > "$CEO_DIR/playbooks/h-block.md" << 'PB'
---
name: h-block
description: block-sequence host list
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts:
  - ml-1
  - wsl-carla
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-block)" '["ml-1","wsl-carla"]' "block-sequence hosts must parse to a JSON array"
}

# A scalar (non-array) hosts value must warn and default to ["*"], never silently
# scope to a single host (enum-config-typo-fallback: don't coerce a typo).
test_hosts_non_array_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-scalar.md" << 'PB'
---
name: h-scalar
description: scalar hosts
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ml-1
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be an array" "scan must warn when hosts is not an array"
  assert_eq "$(_hosts_in_registry h-scalar)" '["*"]' "non-array hosts must default to [\"*\"]"
}

# An empty array would mean "runs nowhere" — a likely mistake that would silently
# disable the playbook. Warn and default to all; use status:disabled to stop one.
test_hosts_empty_array_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-empty.md" << 'PB'
---
name: h-empty
description: empty hosts array
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: []
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on empty hosts array"
  assert_eq "$(_hosts_in_registry h-empty)" '["*"]' "empty hosts array must default to [\"*\"]"
}

# An empty/whitespace element is malformed → warn and default to all.
test_hosts_empty_element_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-blank.md" << 'PB'
---
name: h-blank
description: hosts with an empty element
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", ""]
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on a blank host element"
  assert_eq "$(_hosts_in_registry h-blank)" '["*"]' "a blank host element must default to [\"*\"]"
}

# A whitespace-only element pins the test("\\S") clause specifically (distinct
# from the empty-string case above) — if someone simplifies \S to !="" this
# test is the only thing that catches the regression.
test_hosts_whitespace_element_warns_and_defaults() {
  cat > "$CEO_DIR/playbooks/h-ws.md" << 'PB'
---
name: h-ws
description: hosts with a whitespace-only element
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["ml-1", "  "]
---
PB
  local out; out=$(bash "$CEO_CLI" playbook scan 2>&1)
  assert_contains "$out" "must be a non-empty array" "scan must warn on a whitespace-only host element"
  assert_eq "$(_hosts_in_registry h-ws)" '["*"]' "a whitespace-only element must default to [\"*\"]"
}

# Phase 1 records hosts but does NOT enforce them: a playbook scoped to a
# different host still dispatches here. Enforcement arrives with the daemon (1.5).
test_hosts_recorded_but_not_enforced_in_phase1() {
  cat > "$CEO_DIR/playbooks/h-other.md" << 'PB'
---
name: h-other
description: scoped to a host that is not this one
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: active
hosts: ["definitely-not-this-host"]
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
  assert_eq "$(_hosts_in_registry h-other)" '["definitely-not-this-host"]' "off-host scope must still be recorded"
  bash "$CRON" h-other --scheduled >/dev/null 2>&1 || true
  assert_file_exists "$HOME/claude-invoked.txt" "Phase 1 must NOT enforce hosts — playbook still dispatches"
}

# --- #140: --test-all (fleet dry-run sweep) ---
_test_all_report() { echo "$CEO_DIR/log/preview/test-all/$(date +%Y-%m-%d).md"; }

# Register an active read-tier playbook at a caller-chosen schedule + preflight.
# Distinct schedules avoid the scan-time collision detector (two active cron
# playbooks at the same minute is refused).
_register_pb_sched() {
  local name="$1" sched="$2" preflight="${3:-none}"
  cat > "$CEO_DIR/playbooks/$name.md" << PB
---
name: $name
description: test-all fixture
trigger: cron
schedule: "$sched"
preflight: $preflight
tier: read
status: active
---
PB
}

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
