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
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"search prs"*"--merged"*) echo '[{"number":7,"title":"Did it","repository":{"nameWithOwner":"o/r"}}]' ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 99 ;;
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
  assert_contains "$LEDGER_RECENT" 'predicted today' "ledger tail loaded"
  assert_contains "$LEDGER_PREV_PREDICTED" 'o/r#7' "prev predicted parsed to JSON"
  assert_contains "$LEDGER_PREV_PREDICTED" 'o/r#8' "all predicted bullets parsed"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
