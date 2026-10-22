#!/bin/bash
# ceo-cron.sh tests — _redact_secrets (#566). Every case lives in
# scripts/redaction-cases.jsonl, the shared (input, must-not-contain) corpus
# ollama-agent/tests/test_redaction_fixture.py walks against transport.py. Add a new credential shape once, to the
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
  local row id input bad keep out body body16 hex32
  body=$(fake_token "")
  body16=${body:0:16}
  hex32=$(fake_hex32)
  jq -e -s 'length > 0 and all(.[]; ((.must_not_contain // []) + (.must_contain // [])) | length > 0)' \
    < "$SCRIPT_DIR/redaction-cases.jsonl" >/dev/null || {
    fail_test "fixture is empty, unparsable, or has a row that asserts nothing"
    return 0
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    input=$(printf '%s' "$row" | jq -r '.input' | sed -e "s|{{BODY16}}|$body16|g" -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
    out=$(printf '%s\n' "$input" | _redact_secrets)
    while IFS= read -r bad; do
      [ -n "$bad" ] || continue
      assert_not_contains "$out" "$bad" "$id: '$bad' must not survive redaction"
    done < <(printf '%s' "$row" | jq -r '.must_not_contain // [] | .[]' | sed -e "s|{{BODY16}}|$body16|g" -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
    while IFS= read -r keep; do
      [ -n "$keep" ] || continue
      assert_contains "$out" "$keep" "$id: '$keep' must survive redaction"
    done < <(printf '%s' "$row" | jq -r '.must_contain // [] | .[]' | sed -e "s|{{BODY16}}|$body16|g" -e "s|{{BODY}}|$body|g" -e "s|{{HEX32}}|$hex32|g")
  done < "$SCRIPT_DIR/redaction-cases.jsonl"
}

test_script_tail_redacts_key_longer_than_window() {
  _redacts_init
  sed -n '/^_script_tail() {/,/^}/p' "$SCRIPT_DIR/ceo-cron.sh" > "$TEST_HOME/tail-fn.sh"
  # shellcheck source=/dev/null  # generated fixture
  . "$TEST_HOME/tail-fn.sh"
  local log="$TEST_HOME/err.log" i out
  {
    printf '%s\n' "boot failed" "-----BEGIN RSA PRIVATE KEY-----"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'KEYBODY%02dFAKEFAKEFAKE\n' "$i"; done
    printf '%s\n' "-----END RSA PRIVATE KEY-----" "exit 1"
  } > "$log"
  out=$(_script_tail "$log" 0)
  assert_not_contains "$out" "KEYBODY" "key body beyond the 10-line window must not reach the tail"
  assert_contains "$out" "exit 1" "lines after the key must survive"
}

test_script_tail_redacts_key_whose_begin_is_cut_by_the_byte_window() {
  _redacts_init
  sed -n '/^_script_tail() {/,/^}/p' "$SCRIPT_DIR/ceo-cron.sh" > "$TEST_HOME/tail-fn.sh"
  # shellcheck source=/dev/null  # generated fixture
  . "$TEST_HOME/tail-fn.sh"
  local log="$TEST_HOME/err.log" i out
  {
    printf '%s\n' "boot failed" "-----BEGIN RSA PRIVATE KEY-----"
    for i in $(seq 1 1100); do printf 'KEYBODY%04dFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n' "$i"; done
    printf '%s\n' "-----END RSA PRIVATE KEY-----" "exit 1"
  } > "$log"
  out=$(_script_tail "$log" 0)
  assert_not_contains "$out" "KEYBODY" "key body whose BEGIN line fell outside the 64 KB window must not reach the tail"
  assert_not_contains "$out" "END RSA" "the orphan END marker must not reach the tail"
  assert_contains "$out" "exit 1" "lines after the key must survive"
}

run_tests
