#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/test-harness.sh"
HELPER="$SCRIPT_DIR/ceo-zenhub-sprint.sh"

setup() {
  TMP=$(mktemp -d)
  STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
  # curl stub: validates it's a POST to the zenhub graphql endpoint with auth,
  # returns a canned current-sprint payload.
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"api.zenhub.com/public/graphql"*) : ;;
  *) echo "stub curl: unexpected args: $args" >&2; exit 99 ;;
esac
case "$args" in
  *"Authorization"*|*"-H"*) : ;;
  *) echo "stub curl: missing auth header" >&2; exit 99 ;;
esac
cat <<'JSON'
{"data":{"workspace":{"sprints":{"nodes":[{"state":"OPEN","issues":{"nodes":[
{"number":42,"title":"Sprint task A","repository":{"ownerName":"awesomemotive","name":"optin-monster-app"}}
]}}]}}}}
JSON
STUB
  chmod +x "$STUB_BIN/curl"
  export PATH="$STUB_BIN:$PATH"
  export ZENHUB_TOKEN="test-token"
  export ZENHUB_WORKSPACE_ID="ws_test"
}
teardown() { rm -rf "$TMP"; unset ZENHUB_TOKEN ZENHUB_WORKSPACE_ID; }

test_emits_current_sprint_issues() {
  setup
  out=$(bash "$HELPER")
  assert_contains "$out" '"number": 42' "sprint issue number present"
  assert_contains "$out" 'optin-monster-app' "repo present"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_degrades_to_empty_array_when_token_missing() {
  setup
  unset ZENHUB_TOKEN
  out=$(bash "$HELPER"); rc=$?
  assert_eq "$rc" "0" "exit 0 when token missing"
  assert_eq "$out" "[]" "empty array when token missing"
  teardown
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
