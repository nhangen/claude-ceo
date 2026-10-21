#!/bin/bash
# ceo-cron.sh tests — _redact_secrets (#566). Every case lives in
# scripts/redaction-cases.jsonl, the shared (input, must-not-contain) corpus
# pytest-walks against transport.py. Add a new credential shape once, to the
# fixture plus both implementations — never here alone. No fixture here names
# a credential; placeholders are expanded from the sanctioned fake twins
# (#572).
source "$(cd "$(dirname "$0")" && pwd)/ceo-cron-test-common.sh"

# Each run_tests body is its own subshell, so the extracted function must be
# sourced inside every body that calls it — a suite-level source is invisible
# to later bodies (#566). The closing `}` is alone on column 1, which is what
# makes this range exactly the function's own lines.
_redacts_init() {
  sed -n '/^_redact_secrets() {/,/^}/p' "$SCRIPT_DIR/ceo-cron.sh" > "$TEST_HOME/redact-fn.sh"
  # shellcheck source=/dev/null  # generated fixture
  . "$TEST_HOME/redact-fn.sh"
}

test_redaction_fixture_walk_function_extraction() {
  _redacts_init
  grep -q '^_redact_secrets() {' "$TEST_HOME/redact-fn.sh" || {
    fail_test "extraction found no _redact_secrets() in ceo-cron.sh"
    return 0
  }
  # A fixture walk whose harness cannot name its subject proves nothing; run
  # one redaction so a shell-quoting break in the stub shows here and not as
  # a mysteriously empty corpus result.
  local out
  out=$(printf '%s\n' "password=$(fake_token pw_)" | _redact_secrets)
  assert_not_contains "$out" "$(fake_token pw_)" "smoke: joined fake secret must be redacted"
}

test_redaction_fixture_walk() {
  _redacts_init
  local row id input bad keep out body hex32
  body=$(fake_token "")
  hex32=$(fake_hex32)
  jq -e -s '. | length > 0' < "$SCRIPT_DIR/redaction-cases.jsonl" >/dev/null || {
    fail_test "fixture is empty or unparsable"
    return 0
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    input=$(printf '%s' "$row" | jq -r '.input' | sed -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
    out=$(printf '%s\n' "$input" | _redact_secrets)
    while IFS= read -r bad; do
      [ -n "$bad" ] || continue
      assert_not_contains "$out" "$bad" "$id: '$bad' must not survive redaction"
    done < <(printf '%s' "$row" | jq -r '.must_not_contain // [] | .[]' | sed -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
    while IFS= read -r keep; do
      [ -n "$keep" ] || continue
      assert_contains "$out" "$keep" "$id: '$keep' must survive redaction"
    done < <(printf '%s' "$row" | jq -r '.must_contain // [] | .[]' | sed -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
  done < "$SCRIPT_DIR/redaction-cases.jsonl"
}

run_tests
