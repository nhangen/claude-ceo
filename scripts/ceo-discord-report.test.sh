#!/bin/bash
# Tests for ceo-discord-report.sh. Uses a curl stub; never posts to Discord.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="$SCRIPT_DIR/ceo-discord-report.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

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
  if [ "$count" -lt 2 ]; then
    printf '  FAIL [%s] large report should split into multiple messages; got %s\n' \
      "$CURRENT_TEST" "$count"
    FAILS=$((FAILS + 1))
  fi
}

run_tests() {
  local count=0
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST="$fn"
    setup
    "$fn"
    teardown
    count=$((count + 1))
  done
  echo ""
  if [ "$FAILS" -eq 0 ]; then
    echo "All tests passed. ($count tests)"
  else
    echo "FAILED: $FAILS"
    exit 1
  fi
}

run_tests
