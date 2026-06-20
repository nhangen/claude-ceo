#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  export CEO_VAULT="$TMP/vault"; mkdir -p "$CEO_VAULT/CEO/model"
  # Real ledger-entry format as written by ceo-observe.sh (Task 5).
  cat > "$CEO_VAULT/CEO/model/2026-06.md" <<'LED'
## 2026-06-19 — model update
- yesterday hit-rate: n/a
- predicted today:
  - o/r#7: Ship the thing
  - o/r#8: Review PR
LED
  STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
  # Compute yesterday's date for the stub — same logic as ceo-gather.sh.
  D=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  # Emit two PRs: #7 merged yesterday (should be included), #99 merged in 2020 (should be excluded).
  # The stub requires --author "@me" and --merged to prevent privacy leaks.
  cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"search prs"*"--author"*"@me"*"--merged"*)
    echo '[{"number":7,"title":"Did it","repository":{"nameWithOwner":"o/r"},"mergedAt":"${D}T12:00:00Z"},{"number":99,"title":"Old PR","repository":{"nameWithOwner":"o/r"},"mergedAt":"2020-01-01T00:00:00Z"}]'
    ;;
  *) echo "stub gh: unexpected: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"; export PATH="$STUB_BIN:$PATH"
  export CEO_SPRINT_HELPER="/bin/true"
}
teardown() { rm -rf "$TMP"; unset CEO_VAULT CEO_SPRINT_HELPER; }

test_exports_yesterday_merged_ledger_tail_and_prev_predicted() {
  setup
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1 || true
  assert_contains "$YESTERDAY_MERGED" '"number":7' "merged PR captured"
  assert_no_match "$YESTERDAY_MERGED" '"number":99' "old PR excluded by date filter"
  assert_contains "$LEDGER_RECENT" 'predicted today' "ledger tail loaded"
  assert_contains "$LEDGER_PREV_PREDICTED" 'o/r#7' "prev predicted parsed to JSON"
  assert_contains "$LEDGER_PREV_PREDICTED" 'o/r#8' "all predicted bullets parsed"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_gh_failure_sets_degraded_flag() {
  # Separate setup: override gh stub to fail for search prs
  local TMP2; TMP2=$(mktemp -d)
  local STUB2="$TMP2/bin"; mkdir -p "$STUB2"
  cat > "$STUB2/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"search prs"*) echo "gh: auth error" >&2; exit 1 ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$STUB2/gh"
  local OLD_PATH="$PATH"
  export PATH="$STUB2:$PATH"
  local OLD_VAULT="$CEO_VAULT"
  export CEO_VAULT="$TMP2/vault"; mkdir -p "$CEO_VAULT/CEO"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1 || true
  assert_eq "$YESTERDAY_MERGED" "[]" "degraded: YESTERDAY_MERGED is []"
  assert_eq "${YESTERDAY_MERGED_DEGRADED:-0}" "1" "degraded flag set to 1"
  export PATH="$OLD_PATH"
  export CEO_VAULT="$OLD_VAULT"
  rm -rf "$TMP2"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
