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

# --- _doctor_check_stignore -------------------------------------------------
# Deployment of syncthing/shared.stignore is a manual copy with nothing verifying
# it. It drifted four months on one host and was never done on the other, so
# host-local state (per-trigger fail counters, dry-run previews, the host-local
# registry) synced between machines with no error anywhere.

_sti_files() {
  REPO_STI="$TMP/shared.stignore"
  LIVE_STI="$TMP/vault/.stignore"
  mkdir -p "$TMP/vault"
  cat > "$REPO_STI" <<'STI'
// a comment, which must not be treated as a pattern
CEO/log/.fail-count*
CEO/log/preview/
CEO/registry.json
STI
}

test_stignore_flags_a_pattern_missing_from_the_live_file() {
  _sti_files
  printf '%s\n' 'CEO/log/.fail-count*' 'CEO/registry.json' > "$LIVE_STI"
  local out; out=$(_doctor_check_stignore "$REPO_STI" "$LIVE_STI")
  assert_contains "$out" "MISSING=1" "one absent pattern must be counted"
  assert_contains "$out" "CEO/log/preview/" "the missing pattern must be named"
  assert_contains "$out" "fix: cp" "the fix line must give the copy command"
}

test_stignore_clean_when_live_matches_repo() {
  _sti_files
  grep -v '^//' "$REPO_STI" > "$LIVE_STI"
  local out; out=$(_doctor_check_stignore "$REPO_STI" "$LIVE_STI")
  assert_contains "$out" "MISSING=0" "a live file carrying every pattern is clean"
}

test_stignore_absent_live_file_is_the_loudest_case() {
  # ML-1 had no .stignore at all, which is worse than drift: every host-local
  # file syncs. It must not be reported as merely "0 missing".
  _sti_files
  rm -f "$LIVE_STI"
  local out; out=$(_doctor_check_stignore "$REPO_STI" "$LIVE_STI")
  assert_contains "$out" "MISSING=1" "an absent .stignore must be flagged, not treated as clean"
  assert_contains "$out" "no .stignore at the vault root" "the message must say the file is absent"
}

test_stignore_comments_are_not_treated_as_patterns() {
  # A '//' line is a Syncthing comment. Counting it as a missing pattern would
  # make the check permanently dirty and train the reader to ignore it.
  _sti_files
  grep -v '^//' "$REPO_STI" > "$LIVE_STI"
  local out; out=$(_doctor_check_stignore "$REPO_STI" "$LIVE_STI")
  assert_contains "$out" "MISSING=0" "comment lines must not count as patterns"
}

test_stignore_absent_repo_file_is_not_reported_as_drift() {
  _sti_files
  local out; out=$(_doctor_check_stignore "$TMP/does-not-exist" "$LIVE_STI")
  assert_contains "$out" "MISSING=0" "an unreadable repo file is not evidence of drift"
}

test_stignore_matches_whole_lines_not_substrings() {
  # 'CEO/registry.json' must not be satisfied by a live line that merely contains
  # it as a substring, or a narrower live pattern would mask a missing broader one.
  _sti_files
  printf '%s\n' 'CEO/log/.fail-count*' 'CEO/log/preview/' 'x-CEO/registry.json-y' > "$LIVE_STI"
  local out; out=$(_doctor_check_stignore "$REPO_STI" "$LIVE_STI")
  assert_contains "$out" "MISSING=1" "a substring match must not satisfy a pattern"
  assert_contains "$out" "CEO/registry.json" "the unsatisfied pattern must be named"
}

run_tests
