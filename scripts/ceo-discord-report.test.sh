#!/bin/bash
# Tests for ceo-discord-report.sh. Uses a curl stub; never posts to Discord.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$SCRIPT_DIR/ceo-discord-report.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TMP/home"
  export CEO_DIR="$TMP/vault/CEO"
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
  esac
  shift || true
done
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
  unset CEO_DIR CEO_SECRETS_FILE CEO_DISCORD_REPORT_DEBUG_LOG CURL_CAPTURE_DIR CEO_DISCORD_REPORT_WEBHOOK
}

test_silent_without_report_webhook() {
  printf 'hello' | "$REPORT" morning-brief >/dev/null 2>&1
  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "no webhook means no curl call"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_missing_settings_defaults_to_morning_brief_only() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "missing settings must still default to morning-brief only"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_uses_dedicated_report_webhook_from_file() {
  echo '{"discord_webhook":"http://127.0.0.1/alerts","discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'full report body' | "$REPORT" morning-brief >/dev/null 2>&1

  local payload
  payload=$(cat "$CURL_CAPTURE_DIR"/payload-*.json)
  assert_contains "$payload" "CEO full report: morning-brief" "first payload must identify report"
  assert_contains "$payload" "full report body" "payload must contain body"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_trigger_allowlist_filters_other_reports() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-brief"]}' > "$CEO_DIR/settings.json"
  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "non-allowlisted trigger must not post"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$count" -lt 2 ]; then
    printf '  FAIL [%s] large report should split into multiple messages; got %s\n' \
      "$CURRENT_TEST" "$count"
    _record_assertion_fail
  fi
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_registry_flag_false_blocks_report_despite_settings() {
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  echo '{"discord_report_triggers":["morning-scan"]}' > "$CEO_DIR/settings.json"
  mkdir -p "$HOME/.ceo"
  echo '{"playbooks":[{"name":"morning-scan","discord_report":false}]}' > "$HOME/.ceo/registry.json"

  printf 'scan report' | "$REPORT" morning-scan >/dev/null 2>&1

  assert_eq "$(find "$CURL_CAPTURE_DIR" -type f | wc -l | tr -d ' ')" "0" \
    "registry discord_report:false must block delivery even when the trigger is in the settings allow-list"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_records_last_deliver_timestamp_on_successful_post() {
  # The signal `ceo doctor` watches: a successful delivery writes a per-trigger
  # timestamp. Its ABSENCE/staleness is how the watchdog detects a report that
  # runs but silently stops posting.
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'full report body' | "$REPORT" morning-brief >/dev/null 2>&1
  local f="$CEO_DIR/log/.last-deliver-morning-brief"
  assert_eq "$([ -f "$f" ] && echo yes || echo no)" "yes" \
    "a successful post must record .last-deliver-<trigger>"
  assert_eq "$(cat "$f" 2>/dev/null | grep -cE '^[0-9]+$')" "1" \
    ".last-deliver must hold a numeric epoch"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_no_last_deliver_when_gated_out() {
  # The morning-report bug: trigger not in the allow-list → gated out → no post.
  # No .last-deliver written → doctor sees it go stale (exactly the intent).
  echo '{"discord_report_webhook":"http://127.0.0.1/reports"}' > "$CEO_SECRETS_FILE"
  printf 'scan body' | "$REPORT" morning-scan >/dev/null 2>&1
  assert_eq "$([ -f "$CEO_DIR/log/.last-deliver-morning-scan" ] && echo yes || echo no)" "no" \
    "a gated-out trigger must NOT record a delivery (so its staleness surfaces)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
