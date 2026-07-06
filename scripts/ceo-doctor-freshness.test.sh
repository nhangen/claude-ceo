#!/bin/bash
# Unit tests for the `ceo doctor` playbook-freshness watchdog helpers:
# _doctor_stale_grace (coarse cron→grace mapping) and _doctor_check_freshness
# (per-playbook run + delivery staleness). Catches a scheduled playbook that
# silently stopped running OR runs but stopped delivering to Discord (the
# morning-report bug). Sources the lib directly; injects a fixed `now`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"
source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}
_load_ceo_helpers

setup() {
  TMP=$(mktemp -d)
  REG="$TMP/registry.json"
  LOGDIR="$TMP/log"
  mkdir -p "$LOGDIR"
  NOW=1783000000   # fixed "now" for deterministic ages
}
teardown() { rm -rf "$TMP"; unset TMP REG LOGDIR NOW; }

_reg() {
  local name="$1" sched="$2" deliver="${3:-null}"
  cat > "$REG" <<JSON
{"schema_version":1,"playbooks":[{"name":"$name","status":"active","schedule":"$sched","discord_report":$deliver}]}
JSON
}
_ago() { echo $(( NOW - $1 * 86400 )); }   # epoch N days before NOW

# --- _doctor_stale_grace ---
test_grace_daily_weekday_range() {
  assert_eq "$(_doctor_stale_grace '20 3 * * 1-5')" "$((4*86400))" "weekday-range (1-5) -> daily-ish 4d grace"
}
test_grace_weekly_single_dow() {
  assert_eq "$(_doctor_stale_grace '0 8 * * SUN')" "$((10*86400))" "single weekday -> weekly 10d grace"
}
test_grace_subdaily() {
  assert_eq "$(_doctor_stale_grace '0 */6 * * *')" "$((4*86400))" "every-6h -> daily-ish 4d grace"
}
test_grace_monthly() {
  assert_eq "$(_doctor_stale_grace '0 8 1 * *')" "$((35*86400))" "day-of-month set, dow * -> monthly 35d grace"
}

# --- run staleness ---
test_stale_run_flagged() {
  _reg morning "20 3 * * 1-5"
  echo "$(_ago 6)" > "$LOGDIR/.last-run-morning"
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "hasn't run" "a daily playbook 6 days since last run must be flagged"
  assert_contains "$out" "STALE=1" "one stale playbook"
}
test_fresh_run_not_flagged() {
  _reg morning "20 3 * * 1-5"
  echo "$(_ago 1)" > "$LOGDIR/.last-run-morning"
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "STALE=0" "a run 1 day ago is fresh"
  assert_contains "$out" "FRESH=1" "counted as fresh"
}
test_weekly_within_grace_not_flagged() {
  _reg weekly-synthesis "0 8 * * SUN"
  echo "$(_ago 8)" > "$LOGDIR/.last-run-weekly-synthesis"
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "STALE=0" "a weekly playbook 8 days out is within its 10d grace"
}

# --- delivery staleness (the morning-report bug) ---
test_stale_delivery_flagged_even_when_run_is_fresh() {
  _reg morning "20 3 * * 1-5" true
  echo "$(_ago 1)" > "$LOGDIR/.last-run-morning"
  echo "$(_ago 7)" > "$LOGDIR/.last-deliver-morning"
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "hasn't DELIVERED" "runs-but-doesn't-deliver must be flagged (the morning bug)"
  assert_contains "$out" "STALE=1" "delivery staleness counts as stale"
}
test_delivery_not_checked_for_non_discord_playbook() {
  _reg disk-monitor "0 */6 * * *" false
  echo "$(_ago 1)" > "$LOGDIR/.last-run-disk-monitor"
  echo "$(_ago 30)" > "$LOGDIR/.last-deliver-disk-monitor"
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "STALE=0" "a non-discord playbook's delivery file must not be checked"
}

# --- bootstrapping: never-ran must not false-alarm ---
test_absent_signal_file_not_flagged() {
  _reg brand-new "20 3 * * 1-5" true
  local out; out=$(_doctor_check_freshness "$REG" "$LOGDIR" "$NOW")
  assert_contains "$out" "STALE=0" "a never-run playbook (no signal file) is pending, not stale"
}

run_tests
