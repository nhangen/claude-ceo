#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
PB="$SCRIPT_DIR/../docs/playbooks"

test_morning_active_legacy_disabled() {
  assert_contains "$(cat "$PB/morning.md")" "status: active" "morning active"
  for legacy in morning-scan morning-brief pending-drip pr-triage; do
    assert_contains "$(cat "$PB/$legacy.md")" "status: disabled" "$legacy disabled"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
