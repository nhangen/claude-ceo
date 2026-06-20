#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  # stub the sprint helper to return one item
  cat > "$SCRIPT_DIR/.ceo-zenhub-sprint.stub" <<'STUB'
#!/usr/bin/env bash
echo '[{"number":7,"repo":"awesomemotive/x","title":"Sprint Y"}]'
STUB
  chmod +x "$SCRIPT_DIR/.ceo-zenhub-sprint.stub"
  export CEO_SPRINT_HELPER="$SCRIPT_DIR/.ceo-zenhub-sprint.stub"
  export CEO_VAULT="$TMP/vault"; mkdir -p "$CEO_VAULT/CEO"
}
teardown() { rm -rf "$TMP" "$SCRIPT_DIR/.ceo-zenhub-sprint.stub"; unset CEO_SPRINT_HELPER CEO_VAULT; }

test_exports_sprint_items_and_count() {
  setup
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1 || true
  assert_contains "$CURRENT_SPRINT_ITEMS" '"number":7' "sprint items exported"
  assert_eq "$CURRENT_SPRINT_COUNT" "1" "sprint count exported"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
