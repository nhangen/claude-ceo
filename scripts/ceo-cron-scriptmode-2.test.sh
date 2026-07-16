#!/bin/bash
# ceo-cron.sh tests — #173 script playbooks (part 2/2).
# Shared preamble, setup/teardown, and helpers live in ceo-cron-test-common.sh.
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"


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

  # The read-tier single-call path always requests --output-format json and
  # extracts the body via `jq -r '.result'`, so the stub emits a JSON envelope.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat >/dev/null
cat << 'OUT'
{"result":"LOG_ENTRY:\n## 09:00 — claude-selffail\n**Status:** failed\n**Playbook:** playbooks/claude-selffail.md\n**Output:**\nSimulated claude failure.\n**Errors:**\n- broken\nEND_LOG_ENTRY","total_cost_usd":0.001,"session_id":"test"}
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
  assert_eq "$model" "glm4:latest" "production morning-brief.md must declare model: glm4:latest"
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
  assert_eq "$model" "glm4:latest" "production morning-scan.md must declare model: glm4:latest"
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

run_tests
