#!/bin/bash
# Tests for ceo-discord-report.sh. Uses a curl stub; never posts to Discord.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$SCRIPT_DIR/ceo-discord-report.sh"

source "$SCRIPT_DIR/test-harness.sh"
# For _ceo_state_dir and _doctor_check_freshness: the arms below drive both sides
# of the delivery-stamp contract through the production definitions rather than
# spelling the path a third time.
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"
# _doctor_check_freshness lives in the CLI, which runs its dispatcher when
# sourced, so it is pulled in per-call inside a subshell below rather than here.

setup() {
  TMP=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TMP/home"
  export CEO_DIR="$TMP/vault/CEO"
  export CEO_VAULT="$TMP/vault"
  # Explicit: this script sources ceo-config.sh, and a $HOME-derived state path
  # would escape the fixture in any caller that pins HOME from passwd.
  export CEO_STATE_DIR="$TMP/home/.ceo/state"
  mkdir -p "$CEO_STATE_DIR"
  export CEO_SECRETS_FILE="$TMP/secrets.json"
  export CEO_DISCORD_REPORT_DEBUG_LOG="$TMP/debug.log"
  mkdir -p "$HOME/.bun/bin" "$CEO_DIR" "$TMP/curl"

  cat > "$HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
out="$CURL_CAPTURE_DIR/payload-$(ls "$CURL_CAPTURE_DIR" | wc -l | tr -d ' ').json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      shift
      printf '%s' "$1" > "$out"
      ;;
    # Beside the capture dir, not in it: payload numbering counts its entries.
    http*) printf '%s\n' "$1" >> "$CURL_CAPTURE_DIR.urls" ;;
  esac
  shift || true
done
# Emit an HTTP status like real `curl -w '%{http_code}'`; tests force non-2xx
# via CURL_STUB_STATUS. Default 200 keeps existing success-path tests green.
# CURL_STUB_FAIL models a network failure: curl still prints the -w code (000)
# but exits non-zero.
printf '%s' "${CURL_STUB_STATUS:-200}"
[ -n "${CURL_STUB_FAIL:-}" ] && exit 7
exit 0
STUB
  chmod +x "$HOME/.bun/bin/curl"
  export CURL_CAPTURE_DIR="$TMP/curl"
  export PATH="$HOME/.bun/bin:$PATH"
  unset CEO_DISCORD_REPORT_WEBHOOK
}

teardown() {
  rm -rf "$TMP"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_DIR CEO_VAULT CEO_STATE_DIR CEO_SECRETS_FILE CEO_DISCORD_REPORT_DEBUG_LOG CURL_CAPTURE_DIR CEO_DISCORD_REPORT_WEBHOOK
}

test_silent_without_report_webhook() {
  printf 'hello' | "$REPORT" morning-brief >/dev/null 2>&1
  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "no webhook means no curl call"
}

test_missing_settings_defaults_to_morning_brief_only() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "missing settings must still default to morning-brief only"
}

test_uses_dedicated_report_webhook_from_file() {
  echo '{"discord_webhook":"http://127.0.0.1/alerts","discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'full report body' | "$REPORT" morning-brief >/dev/null 2>&1

  local payload
  payload=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$payload" "CEO full report: morning-brief" "first payload must identify report"
  assert_contains "$payload" "full report body" "payload must contain body"
}

test_trigger_allowlist_filters_other_reports() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "non-allowlisted trigger must not post"
}

test_splits_large_report() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  {
    printf 'start\n'
    awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }'
    printf '\nend\n'
  } | "$REPORT" morning-brief >/dev/null 2>&1

  local count
  count=$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')
  assert_eq "$([ "$count" -ge 2 ] && echo 1 || echo 0)" "1" "large report should split into multiple messages (got $count)"
}

_write_prior_report() {
  # _write_prior_report <date> <body-line>
  mkdir -p "$CEO_DIR/reports"
  cat > "$CEO_DIR/reports/$1.md" << EOF
---
date: $1
type: ceo-daily-report
---

# CEO Daily Report — $1

$2
EOF
}

test_appends_prior_day_report_for_morning_brief() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-14" "PRIOR_DAY_BODY_MARKER"

  printf 'todays brief' | "$REPORT" morning-brief >/dev/null 2>&1

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$all" "Prior-day full report — 2026-06-14" "prior-day section header must be posted"
  assert_contains "$all" "PRIOR_DAY_BODY_MARKER" "prior-day report body must be posted in full"
  assert_not_contains "$all" "type: ceo-daily-report" "prior-day front matter must be stripped before posting"
  unset TODAY
}

test_prior_day_append_gated_to_morning_brief() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  # Post morning-scan's own report, but prior-day append stays morning-brief-only.
  echo '{"discord_report_triggers":["morning-brief","morning-scan"]}' > "$CEO_DIR/settings.json"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-14" "PRIOR_DAY_BODY_MARKER"

  printf 'scan body' | "$REPORT" morning-scan >/dev/null 2>&1

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null || echo "")
  assert_contains "$all" "scan body" "morning-scan's own report must still post"
  assert_not_contains "$all" "Prior-day full report" "prior-day append must not fire for non-morning-brief triggers"
  unset TODAY
}

test_skips_prior_day_when_none_exists() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export TODAY="2026-06-15"
  mkdir -p "$CEO_DIR/reports"

  printf 'todays brief' | "$REPORT" morning-brief >/dev/null 2>&1

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$all" "todays brief" "brief must still post when no prior report exists"
  assert_not_contains "$all" "Prior-day full report" "must not post a prior-day section when no prior report exists"
  unset TODAY
}

test_picks_most_recent_prior_report_excluding_today() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-11" "OLDEST_MARKER"
  _write_prior_report "2026-06-12" "MOST_RECENT_PRIOR_MARKER"
  _write_prior_report "2026-06-15" "TODAY_MARKER"

  printf 'todays brief' | "$REPORT" morning-brief >/dev/null 2>&1

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$all" "MOST_RECENT_PRIOR_MARKER" "must pick the most recent report before today"
  assert_not_contains "$all" "OLDEST_MARKER" "must not post an older report when a more recent prior exists"
  assert_not_contains "$all" "TODAY_MARKER" "must not post today's own report as the prior day"
  unset TODAY
}

test_empty_prior_day_allowlist_disables_append() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  # An explicit empty list disables the append — the jq `// ["morning-brief"]`
  # default only applies when the key is ABSENT, not when it is [].
  echo '{"discord_prior_day_report_triggers":[]}' > "$CEO_DIR/settings.json"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-14" "PRIOR_DAY_BODY_MARKER"

  printf 'todays brief' | "$REPORT" morning-brief >/dev/null 2>&1

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$all" "todays brief" "the brief itself must still post when prior-day append is disabled"
  assert_not_contains "$all" "Prior-day full report" "empty allowlist must disable the prior-day append"
  assert_not_contains "$all" "PRIOR_DAY_BODY_MARKER" "prior-day body must not post when allowlist is empty"
  unset TODAY
}

# --- Registry-frontmatter gate (prevents trigger-rename allow-list drift) ---
# The authoritative signal for "post this playbook's report to Discord" is the
# discord_report flag carried in the host-local registry from playbook
# frontmatter. settings.json's discord_report_triggers remains a backward-compat
# fallback used only when the trigger's registry entry lacks the flag field.

test_registry_flag_enables_report_without_settings_entry() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  # A renamed playbook: settings.json still lists the OLD name, not "morning".
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning","discord_report":true}]}' > "$HOME/.ceo/registry.json"

  printf 'orchestrated brief' | "$REPORT" morning >/dev/null 2>&1

  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "orchestrated brief" \
    "registry discord_report:true must post even when the trigger is absent from settings allow-list"
  assert_not_contains "$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)" "registry flag absent for discord_report" \
    "an explicit true is not reported as an absent flag"
}

test_registry_flag_false_blocks_report_despite_settings() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-scan"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-scan","discord_report":false}]}' > "$HOME/.ceo/registry.json"

  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "registry discord_report:false must block delivery even when the trigger is in the settings allow-list"
  assert_not_contains "$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)" "registry flag absent for discord_report" \
    "an explicit false is not reported as an absent flag"
}

test_no_registry_flag_field_falls_back_to_settings() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["legacy-brief"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  # Old registry: entry exists but carries no discord_report field.
  echo '{"playbooks":[{"name":"legacy-brief"}]}' > "$HOME/.ceo/registry.json"

  printf 'legacy body' | "$REPORT" legacy-brief >/dev/null 2>&1

  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "legacy body" \
    "an entry without a discord_report field must fall back to the settings allow-list (backward compat)"

  # #424 asked for error lines on the two failure causes, not on the third. A
  # legitimately absent flag is the steady state, so an error line here would
  # fire on every cron run. #485 records an informational line on the absent arm
  # naming the field and path so fallback decisions are auditable without
  # triggering error needles.
  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "registry flag absent for discord_report, falling back to settings ($HOME/.ceo/registry.json)" \
    "absent discord_report flag must log informational line naming field and registry"
  assert_contains "$log" "registry flag absent for discord_prior_day_report, falling back to settings ($HOME/.ceo/registry.json)" \
    "absent discord_prior_day_report flag must log informational line naming field and registry"
  assert_not_contains "$log" "registry file not found" \
    "a present registry with a legitimately absent flag must not log a not-found error"
  assert_not_contains "$log" "registry jq query failed" \
    "a well-formed registry must not log a jq failure"
}

test_empty_registry_falls_back_to_settings_and_logs_no_output() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  local empty_reg="$TMP/empty-registry.json"
  : > "$empty_reg"

  printf 'empty reg body' | CEO_REGISTRY_FILE="$empty_reg" "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "registry query produced no output for discord_report, falling back to settings ($empty_reg)" \
    "a 0-byte registry must log its own line for discord_report"
  assert_contains "$log" "registry query produced no output for discord_prior_day_report, falling back to settings ($empty_reg)" \
    "a 0-byte registry must log its own line for discord_prior_day_report"
  assert_not_contains "$log" "registry flag absent for" \
    "a 0-byte registry must not read as the routine absent-flag case"
  assert_not_contains "$log" "registry file not found" \
    "a 0-byte registry file exists so it must not log file not found"
  assert_not_contains "$log" "registry jq query failed" \
    "jq exits 0 on an empty file so it must not log jq query failed"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "empty reg body" \
    "a 0-byte registry must still deliver via the settings allow-list"
}

test_non_boolean_registry_flag_is_named_not_called_absent() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief","discord_report":"yes"}]}' > "$HOME/.ceo/registry.json"

  printf 'yes body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "registry flag for discord_report is not a boolean (yes), falling back to settings" \
    "a present non-boolean flag must be named with its value"
  assert_not_contains "$log" "registry flag absent for discord_report" \
    "a present non-boolean flag is not absent"
  assert_not_contains "$log" "registry file not found" "the registry exists"
  assert_not_contains "$log" "registry jq query failed" "the registry parses"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "yes body" \
    "a non-boolean flag falls back to the settings allow-list and still delivers"
}

test_multi_document_registry_value_logs_on_one_line() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  # Two concatenated JSON documents make jq print one line per document.
  printf '{}{}' > "$HOME/.ceo/registry.json"

  printf 'multi body' | "$REPORT" morning-brief >/dev/null 2>&1

  assert_contains "$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)" \
    "registry flag for discord_report is not a boolean (absent absent), falling back to settings" \
    "a multi-line registry value is logged on one line"
}

test_registry_path_is_not_hardcoded_in_discord_report() {
  # Not a regression test for the helper fold: the pre-fold line had its own
  # inline ${CEO_REGISTRY_FILE:-...} and this passed against it too. What it
  # pins is that the path keeps coming from _ceo_registry_path — it fails if
  # the helper is reverted, and it would fail on a future re-hardcode here.
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  local custom_reg="$TMP/custom-registry.json"
  echo '{"playbooks":[{"name":"morning-override","discord_report":true}]}' > "$custom_reg"

  printf 'custom brief' | CEO_REGISTRY_FILE="$custom_reg" "$REPORT" morning-override >/dev/null 2>&1

  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "custom brief" \
    "ceo-discord-report.sh must resolve registry via CEO_REGISTRY_FILE override"
}

# --- #424: registry resolution failures must be visible in the debug log, not
# silent. Both arms also assert delivery, because the log line and the `echo
# absent` that keeps the caller alive are the same edit: without the delivery
# assertion, dropping `echo absent` leaves the suite green while a live run
# dies on `enabled: unbound variable` and posts nothing. ---

test_missing_registry_logs_debug_line_naming_path() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  local missing_reg="$TMP/nonexistent-registry.json"

  printf 'brief body' | CEO_REGISTRY_FILE="$missing_reg" "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "registry file not found for discord_report ($missing_reg)" \
    "missing registry file must be logged in debug log with resolved path"
  assert_contains "$log" "registry file not found for discord_prior_day_report ($missing_reg)" \
    "the prior-day call site must be distinguishable from the discord_report one"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "brief body" \
    "a missing registry must still deliver via the settings allow-list"
}

test_malformed_registry_logs_jq_failure_debug_line() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  local bad_reg="$TMP/bad-registry.json"
  echo "not-valid-json{{{" > "$bad_reg"

  printf 'brief body' | CEO_REGISTRY_FILE="$bad_reg" "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "registry jq query failed for discord_report ($bad_reg)" \
    "malformed registry JSON must log jq query failure in debug log"
  assert_contains "$log" "registry jq query failed for discord_prior_day_report ($bad_reg)" \
    "the prior-day call site must log its own failure, not share the first one's line"
  # Couples to jq's wording on purpose: carrying the cause is the whole point of
  # the line, and "parse error" is what separates a corrupt file from an EACCES
  # ("Could not open file ... Permission denied"), which need different repairs.
  assert_contains "$log" "parse error" \
    "the failure line must carry jq's own message, not just the fact of failure"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "brief body" \
    "a malformed registry must still deliver via the settings allow-list"
}

# --- #483: a corrupt or empty settings.json must not silently kill delivery for
# default-enabled triggers, and must record the jq error in the debug log. ---

test_corrupt_settings_logs_jq_failure_and_falls_back_to_default() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"
  echo "not-valid-json{{{" > "$CEO_DIR/settings.json"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-14" "PRIOR_DAY_BODY_MARKER"

  printf 'corrupt settings body' | "$REPORT" morning-brief >/dev/null 2>&1
  unset TODAY

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "settings jq query failed for discord_report_triggers ($CEO_DIR/settings.json)" \
    "corrupt settings.json must log jq query failure for discord_report_triggers"
  assert_contains "$log" "settings jq query failed for discord_prior_day_report_triggers ($CEO_DIR/settings.json)" \
    "corrupt settings.json must log jq query failure for discord_prior_day_report_triggers"
  assert_contains "$log" "settings jq query failed for discord_report_triggers ($CEO_DIR/settings.json): jq: parse error" \
    "the settings failure line must carry jq's own parse error message"
  assert_contains "$log" "falling back to default allow-list" \
    "the settings failure line must name the fallback it takes"
  assert_not_contains "$log" "trigger not enabled for full report delivery" \
    "morning-brief must not claim to be disabled when settings is corrupt"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "corrupt settings body" \
    "morning-brief must still deliver via default fallback when settings is corrupt"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "PRIOR_DAY_BODY_MARKER" \
    "the prior-day append must also take the default fallback for morning-brief"
}

test_corrupt_settings_does_not_enable_prior_day_for_non_default_trigger() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  # Registry opts custom-brief into the main report but says nothing about the
  # prior-day append, so that decision falls to the (corrupt) settings.json.
  echo '{"playbooks":[{"name":"custom-brief","discord_report":true}]}' > "$HOME/.ceo/registry.json"
  echo "not-valid-json{{{" > "$CEO_DIR/settings.json"
  export TODAY="2026-06-15"
  _write_prior_report "2026-06-14" "PRIOR_DAY_BODY_MARKER"

  printf 'custom body' | "$REPORT" custom-brief >/dev/null 2>&1
  unset TODAY

  local all
  all=$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)
  assert_contains "$all" "custom body" "the registry-enabled main report still posts"
  assert_not_contains "$all" "PRIOR_DAY_BODY_MARKER" \
    "a corrupt settings.json must not enable the prior-day append for a non-default trigger"
}

test_multi_document_settings_logs_unexpected_output_on_one_line() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"
  # Two concatenated documents make jq print one boolean per document.
  printf '{"discord_report_triggers":[]}{"discord_report_triggers":[]}' > "$CEO_DIR/settings.json"

  printf 'multi settings body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "settings jq query produced unexpected output for discord_report_triggers ($CEO_DIR/settings.json): false false, falling back to default allow-list" \
    "multi-document settings output is logged on one line with the fallback named"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "multi settings body" \
    "an undecidable settings.json takes the default fallback for morning-brief"
}

test_corrupt_settings_does_not_enable_non_default_trigger() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"custom-brief"}]}' > "$HOME/.ceo/registry.json"
  echo "not-valid-json{{{" > "$CEO_DIR/settings.json"

  printf 'custom body' | "$REPORT" custom-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "settings jq query failed for discord_report_triggers ($CEO_DIR/settings.json)" \
    "corrupt settings.json must log query failure even for non-default trigger"
  assert_contains "$log" "trigger not enabled for full report delivery" \
    "corrupt settings must not fail open to arbitrary non-default triggers"
  assert_eq "$([ -f "$CURL_CAPTURE_DIR"/payload-0.json ] && echo yes || echo no)" "no" \
    "non-default trigger must not post when settings is corrupt"
}

test_empty_settings_logs_no_output_and_falls_back_to_default() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"
  : > "$CEO_DIR/settings.json"

  printf 'empty settings body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "settings jq query produced no output for discord_report_triggers ($CEO_DIR/settings.json), falling back to default allow-list" \
    "empty settings.json must log no-output message for discord_report_triggers"
  assert_contains "$log" "settings jq query produced no output for discord_prior_day_report_triggers ($CEO_DIR/settings.json)" \
    "empty settings.json must log no-output message for discord_prior_day_report_triggers"
  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "empty settings body" \
    "morning-brief must still deliver via default fallback when settings is empty"
}

test_corrupt_secrets_logs_jq_failure_not_unresolved() {
  printf '{"discord_report_webhook":' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"

  local rc=0
  printf 'corrupt secrets body' | "$REPORT" morning-brief >/dev/null 2>&1 || rc=$?

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_eq "$rc" "0" "a corrupt secrets.json still exits 0"
  assert_contains "$log" "secrets jq query failed ($CEO_SECRETS_FILE): jq: parse error" \
    "a corrupt secrets.json logs the jq parse error"
  assert_not_contains "$log" "report webhook unresolved" \
    "a parse failure is not reported as a missing webhook"
  assert_eq "$(ls "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "nothing is posted without a webhook"
}

test_secrets_jq_error_masks_the_value_it_prints() {
  echo '{"discord_report_webhook":{"url":"https://FAKE-EXAMPLE.invalid/not-a-webhook"}}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"

  printf 'object secrets body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "secrets jq query failed ($CEO_SECRETS_FILE)" \
    "a non-string webhook value fails the query instead of becoming the URL"
  assert_contains "$log" 'and object (' \
    "the log carries jq's type error"
  assert_not_contains "$log" 'FAKE-EXAMPLE' \
    "the value jq printed does not reach the log"
  assert_not_contains "$log" '"htt' \
    "a value jq truncated mid-string is masked too"
  assert_eq "$(ls "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "nothing is posted to a non-string webhook"
}

test_empty_secrets_logs_no_output_not_unresolved() {
  printf '  \n' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"

  printf 'empty secrets body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "secrets jq query produced no output ($CEO_SECRETS_FILE), bailing 0" \
    "an empty secrets.json is reported as empty"
  assert_not_contains "$log" "report webhook unresolved" \
    "an empty file is not reported as a missing key"
}

test_secrets_without_the_key_logs_unresolved() {
  echo '{}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"

  printf 'no key body' | "$REPORT" morning-brief >/dev/null 2>&1

  local log
  log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null || echo "")
  assert_contains "$log" "report webhook unresolved, bailing 0" \
    "a valid secrets.json without the key is a missing webhook"
  assert_not_contains "$log" "secrets jq query" \
    "a missing key is not reported as a jq failure"
}

test_secrets_with_a_string_webhook_still_posts() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-brief"}]}' > "$HOME/.ceo/registry.json"

  printf 'string webhook body' | "$REPORT" morning-brief >/dev/null 2>&1

  assert_contains "$(cat "$CURL_CAPTURE_DIR"/payload-*.json 2>/dev/null)" "string webhook body" \
    "a string webhook still delivers"
  assert_eq "$(sort -u "$CURL_CAPTURE_DIR.urls" 2>/dev/null)" "http://127.0.0.1/reports" \
    "the v: prefix is stripped before the URL is used"
}

test_records_last_deliver_timestamp_on_successful_post() {
  # The signal `ceo doctor` watches: a successful delivery writes a per-trigger
  # timestamp. Its ABSENCE/staleness is how the watchdog detects a report that
  # runs but silently stops posting.
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'full report body' | "$REPORT" morning-brief >/dev/null 2>&1
  # Resolved through the production helper, not spelled a second time here. The
  # whole defect this arm guards against in #400 was the writer and `ceo doctor`'s
  # reader disagreeing about the directory, and a test that hardcodes its own
  # third spelling cannot see that.
  local f
  f="$(_ceo_state_dir)/.last-deliver-morning-brief"
  assert_eq "$([ -f "$f" ] && echo yes || echo no)" "yes" \
    "a successful post must record .last-deliver-<trigger>"
  assert_eq "$(cat "$f" 2>/dev/null | grep -cE '^[0-9]+$')" "1" \
    ".last-deliver must hold a numeric epoch"

  # It must NOT be in the synced vault: whether this machine delivered says
  # nothing about whether another did, and the stamp had no stignore entry at
  # all, so it replicated — one host's delivery marking another's as fresh.
  assert_eq "$([ -e "$CEO_DIR/log/.last-deliver-morning-brief" ] && echo 1 || echo 0)" "0" \
    "the delivery stamp was written into the synced vault"
}

test_the_delivery_stamp_lands_where_doctor_reads_it() {
  # The #400 blocker: the reader moved to the host-local state dir and this writer
  # did not, so doctor looked for the stamp where nothing wrote it. Its absent-file
  # branch is deliberately non-flagging, so the check reported a permanent
  # all-clear — the exact silent-delivery failure it was built to catch.
  #
  # Driving both sides here is the point: a test that names the path itself would
  # have stayed green through that break.
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'full report body' | "$REPORT" morning-brief >/dev/null 2>&1

  local reg="$TMP/reg.json" out
  cat > "$reg" << 'REG'
{"playbooks":[{"name":"morning-brief","status":"active","schedule":"0 6 * * *","discord_report":true}]}
REG
  # Asserted on the complaint, not on its absence. The reader's absent-file branch
  # is deliberately non-flagging, so "no output" is what a *broken* reader
  # produces — the same all-clear the real break produced. Reading the clock 40
  # days ahead makes the just-written stamp stale, so a reader that actually finds
  # it must say so, and only a reader that finds it can.
  local future; future=$(( $(date +%s) + 3456000 ))
  out=$( source "$SCRIPT_DIR/ceo" >/dev/null 2>&1; _doctor_check_freshness "$reg" "$(_ceo_state_dir)" "$future" 2>&1 || true )
  assert_contains "$out" "hasn't DELIVERED" \
    "doctor must read the delivery stamp the reporter just wrote"

  # And the converse: pointed at the directory the stamp used to live in, the
  # reader finds nothing and is silent. That silence is what shipped.
  local blind
  blind=$( source "$SCRIPT_DIR/ceo" >/dev/null 2>&1; _doctor_check_freshness "$reg" "$CEO_DIR/log" "$future" 2>&1 || true )
  assert_not_contains "$blind" "hasn't DELIVERED" \
    "the arm cannot distinguish a working reader from a blind one"
}

test_no_last_deliver_when_gated_out() {
  # The morning-report bug: trigger not in the allow-list → gated out → no post.
  # No .last-deliver written → doctor sees it go stale (exactly the intent).
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'scan body' | "$REPORT" morning-scan >/dev/null 2>&1
  assert_eq "$([ -f "$CEO_DIR/log/.last-deliver-morning-scan" ] && echo yes || echo no)" "no" \
    "a gated-out trigger must NOT record a delivery (so its staleness surfaces)"
}

# --- #242: non-2xx Discord responses must be observable, not logged as posted ---
test_non_2xx_not_counted_as_delivered() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export CURL_STUB_STATUS=500
  printf 'single chunk body' | "$REPORT" morning-brief >/dev/null 2>&1
  unset CURL_STUB_STATUS
  local log; log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)
  assert_contains "$log" "posted chunks=0" \
    "a 500 response must not be counted as a delivered chunk"
  assert_no_match "$log" "posted chunks=1" \
    "a dropped chunk must never be logged as posted"
}

test_non_2xx_logs_a_failure_with_status() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export CURL_STUB_STATUS=500
  printf 'single chunk body' | "$REPORT" morning-brief >/dev/null 2>&1
  unset CURL_STUB_STATUS
  local log; log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)
  assert_contains "$log" "500" \
    "a failed post must log the HTTP status for observability"
}

test_2xx_still_counts_as_delivered() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'single chunk body' | "$REPORT" morning-brief >/dev/null 2>&1
  local log; log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)
  assert_contains "$log" "posted chunks=1" \
    "a 2xx response must still count as one delivered chunk"
}

test_last_deliver_not_stamped_on_total_failure() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export CURL_STUB_STATUS=500
  printf 'single chunk body' | "$REPORT" morning-brief >/dev/null 2>&1
  unset CURL_STUB_STATUS
  assert_eq "$([ -f "$CEO_DIR/log/.last-deliver-morning-brief" ] && echo yes || echo no)" "no" \
    "a 100%-failed delivery must NOT bump the .last-deliver freshness stamp (ceo doctor watches it)"
}

test_network_failure_logs_single_clean_status() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  export CURL_STUB_STATUS=000 CURL_STUB_FAIL=1
  printf 'single chunk body' | "$REPORT" morning-brief >/dev/null 2>&1
  unset CURL_STUB_STATUS CURL_STUB_FAIL
  local log; log=$(cat "$CEO_DISCORD_REPORT_DEBUG_LOG" 2>/dev/null)
  assert_contains "$log" "status=000" \
    "a curl network failure logs the 000 sentinel status"
  assert_no_match "$log" "status=0000" \
    "the status must be a single clean 000, not a doubled 000000 from curl's -w plus the || fallback"
}

run_tests
