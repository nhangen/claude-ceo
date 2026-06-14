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
  if [ "$count" -lt 2 ]; then
    printf '  FAIL [%s] large report should split into multiple messages; got %s\n' \
      "$CURRENT_TEST" "$count"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  # Front matter must be stripped, not posted as Discord noise.
  if printf '%s' "$all" | grep -q "type: ceo-daily-report"; then
    printf '  FAIL [%s] prior-day front matter must be stripped before posting\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  if printf '%s' "$all" | grep -q "Prior-day full report"; then
    printf '  FAIL [%s] prior-day append must not fire for non-morning-brief triggers\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  if printf '%s' "$all" | grep -q "Prior-day full report"; then
    printf '  FAIL [%s] must not post a prior-day section when no prior report exists\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
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
  if printf '%s' "$all" | grep -q "OLDEST_MARKER"; then
    printf '  FAIL [%s] must not post an older report when a more recent prior exists\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  if printf '%s' "$all" | grep -q "TODAY_MARKER"; then
    printf "  FAIL [%s] must not post today's own report as the prior day\n" "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  unset TODAY
}

run_tests
