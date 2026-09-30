#!/bin/bash
# Tests for ceo-log.sh.
# Verifies that log summary and metrics parsing does not crash under set -euo pipefail
# when sections (such as errors or audibles) have zero matches (#600).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_LOG="$SCRIPT_DIR/ceo-log.sh"

source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

setup() {
  TMP=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TMP/home"
  export CEO_VAULT="$TMP/vault"
  export CEO_DIR="$TMP/vault/CEO"
  LOG_DIR="$CEO_DIR/log"
  mkdir -p "$LOG_DIR"
  TODAY=$(date +%Y-%m-%d)
  YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
}

teardown() {
  export HOME="$HOME_BACKUP"
  rm -rf "$TMP"
}

test_log_no_errors_or_audibles_runs_cleanly() {
  cat > "$LOG_DIR/$TODAY.md" << 'EOF'
---
date: 2026-09-30
---
# 2026-09-30

## 09:00:00 morning-scan
**Trigger:** cron
**Status:** completed
**Errors:**
- none

EOF

  local out rc=0
  out=$(bash "$CEO_LOG" today 2>&1) || rc=$?

  assert_eq "$rc" "0" "ceo-log.sh must exit 0 on a log with no errors or audibles"
  assert_contains "$out" "**Summary:** 1 actions (1 completed, 0 failed, 0 partial)" "summary must count completed action cleanly"
  assert_not_contains "$out" "0 0" "counts must not contain double zeros"
  assert_not_contains "$out" "integer expression expected" "no integer comparison syntax error"
  assert_not_contains "$out" "entries with errors" "must not report errors when only - none exists"
  assert_not_contains "$out" "Audibles:" "must not report audibles when none exist"
  assert_not_contains "$out" "Delegations:" "must not report delegations when none exist"
}

test_log_empty_file_does_not_crash() {
  cat > "$LOG_DIR/$TODAY.md" << 'EOF'
# Empty log header
EOF

  local out rc=0
  out=$(bash "$CEO_LOG" today 2>&1) || rc=$?

  assert_eq "$rc" "0" "ceo-log.sh must exit 0 on an empty log"
  assert_contains "$out" "**Summary:** 0 actions (0 completed, 0 failed, 0 partial)" "summary must show zero counts cleanly"
  assert_not_contains "$out" "syntax error" "no arithmetic syntax error"
  assert_not_contains "$out" "integer expression expected" "no integer comparison error"
}

test_log_calculates_all_stats_correctly() {
  cat > "$LOG_DIR/$TODAY.md" << 'EOF'
## Entry 1
**Status:** completed
**Audibles:**
- skipped something

**Errors:**
- none

**Delegations:**
- delegation 1

## Entry 2
**Status:** completed
**Audibles:**
- audible 2

## Entry 3
**Status:** failed
**Errors:**
- disk failed

## Entry 4
**Status:** partial
**Errors:**
- timeout occurred

**Delegations:**
- delegation 2

EOF

  local out rc=0
  out=$(bash "$CEO_LOG" today 2>&1) || rc=$?

  assert_eq "$rc" "0" "ceo-log.sh must exit 0 on mixed-status log"
  assert_contains "$out" "**Summary:** 4 actions (2 completed, 1 failed, 1 partial)" "summary counts all statuses"
  assert_contains "$out" "**Audibles:** 2 logged" "audibles counted correctly"
  assert_contains "$out" "**Errors:** 2 entries with errors" "real errors counted correctly (3 total minus 1 none)"
  assert_contains "$out" "**Delegations:** 2 logged" "delegations counted correctly"
}

test_log_missing_file_reports_cleanly() {
  local out rc=0
  out=$(bash "$CEO_LOG" 2020-01-01 2>&1) || rc=$?

  assert_eq "$rc" "0" "ceo-log.sh must exit 0 on missing log"
  assert_contains "$out" "No CEO activity logged for 2020-01-01." "reports no activity on missing log"
}

test_log_yesterday_argument_resolves() {
  cat > "$LOG_DIR/$YESTERDAY.md" << 'EOF'
## 10:00:00 yesterday-job
**Status:** completed
EOF

  local out rc=0
  out=$(bash "$CEO_LOG" yesterday 2>&1) || rc=$?

  assert_eq "$rc" "0" "ceo-log.sh must exit 0 for yesterday"
  assert_contains "$out" "## CEO Log — $YESTERDAY" "resolves yesterday's date header"
  assert_contains "$out" "**Summary:** 1 actions (1 completed, 0 failed, 0 partial)" "parses yesterday's log"
}

run_tests
