#!/bin/bash
# Self-contained test harness. Runs every function named test_*.

set -uo pipefail  # note: no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/count-blessings.sh"
LIB="$SCRIPT_DIR/blessings-lib.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

assert_fails() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL [%s] %s (expected non-zero exit)\n' "$CURRENT_TEST" "$msg"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR/cache"
}

teardown() {
  rm -rf "$TEST_HOME"
  unset CEO_VAULT CEO_DIR TEST_HOME
}

test_harness_works() {
  assert_eq "1" "1" "arithmetic still works"
}

test_add_writes_bullet_to_blessings_file() {
  bash "$CLI" add "family" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" "- family" "bullet written"
  assert_contains "$content" "type: ea-blessings" "frontmatter created"
}

test_add_appends_without_overwriting() {
  bash "$CLI" add "first" >/dev/null
  bash "$CLI" add "second" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" "- first" "first preserved"
  assert_contains "$content" "- second" "second appended"
}

test_add_rejects_empty_argument() {
  assert_fails "empty add should fail" bash "$CLI" add ""
}

test_add_rejects_newline_in_argument() {
  assert_fails "newline smuggling rejected" bash "$CLI" add $'line1\nline2'
}

test_add_rejects_overlong_argument() {
  local long
  long=$(printf 'x%.0s' {1..501})
  assert_fails "501-char entry rejected" bash "$CLI" add "$long"
}

test_add_handles_shell_metacharacters_literally() {
  bash "$CLI" add "\$(rm -rf /tmp/should-not-happen); echo pwned" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" '$(rm -rf /tmp/should-not-happen); echo pwned' "metachars stored verbatim"
}

test_add_ensures_trailing_newline_before_append() {
  # pre-seed a file without trailing newline
  printf -- '---\ntype: ea-blessings\n---\n\n- existing' > "$CEO_DIR/blessings.md"
  bash "$CLI" add "new" >/dev/null
  local lines
  lines=$(grep -c '^- ' "$CEO_DIR/blessings.md")
  assert_eq "$lines" "2" "both bullets present on their own lines"
}

test_list_shows_numbered_bullets() {
  bash "$CLI" add "first" >/dev/null
  bash "$CLI" add "second" >/dev/null
  bash "$CLI" add "third" >/dev/null
  local out
  out=$(bash "$CLI" list)
  assert_contains "$out" "- first" "first present"
  assert_contains "$out" "- second" "second present"
  assert_contains "$out" "- third" "third present"
  assert_contains "$out" "     1	" "numbered"
}

test_list_strips_frontmatter() {
  bash "$CLI" add "only-one" >/dev/null
  local out
  out=$(bash "$CLI" list)
  [[ "$out" != *"type: ea-blessings"* ]] || {
    printf '  FAIL [%s] frontmatter leaked into list output\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
}

test_list_on_missing_file_is_empty() {
  local out
  out=$(bash "$CLI" list 2>&1 || true)
  # Missing file is not an error — just empty output.
  assert_eq "$out" "" "empty output on missing file"
}

test_list_on_empty_body_is_empty() {
  # File exists with frontmatter but no bullets yet.
  printf -- '---\ntype: ea-blessings\n---\n\n' > "$CEO_DIR/blessings.md"
  local out
  out=$(bash "$CLI" list 2>&1)
  local rc=$?
  assert_eq "$rc" "0" "exit 0 on empty body"
  assert_eq "$out" "" "empty output on empty body"
}

# --- runner ---
tests=$(declare -F | awk '{print $3}' | grep '^test_' || true)
if [[ -z "$tests" ]]; then
  printf 'no tests discovered\n' >&2
  exit 1
fi
for t in $tests; do
  CURRENT_TEST="$t"
  printf 'RUN %s\n' "$t"
  setup
  "$t"
  teardown
done

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%d FAILURE(S)\n' "$FAILS"
  exit 1
fi
printf '\nALL PASS\n'
