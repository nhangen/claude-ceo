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

test_cache_picks_three_when_many_available() {
  # shellcheck source=../blessings-lib.sh
  source "$LIB"
  mkdir -p "$CEO_DIR"
  {
    printf -- '---\ntype: ea-blessings\n---\n\n'
    for i in 1 2 3 4 5 6 7 8 9 10; do printf -- '- entry %d\n' "$i"; done
  } > "$CEO_DIR/blessings.md"

  ensure_blessings_cache

  local cache="$CEO_DIR/cache/blessings-today.md"
  [[ -f "$cache" ]] || { printf '  FAIL [%s] cache not created\n' "$CURRENT_TEST"; FAILS=$((FAILS+1)); return; }

  local today; today=$(date +%Y-%m-%d)
  assert_contains "$(cat "$cache")" "date: $today" "today stamped"

  local bullet_count
  bullet_count=$(grep -c '^- ' "$cache")
  assert_eq "$bullet_count" "3" "exactly three picks"
}

test_cache_picks_all_when_fewer_than_three() {
  source "$LIB"
  mkdir -p "$CEO_DIR"
  printf -- '---\ntype: ea-blessings\n---\n\n- only-one\n' > "$CEO_DIR/blessings.md"
  ensure_blessings_cache
  local count
  count=$(grep -c '^- ' "$CEO_DIR/cache/blessings-today.md")
  assert_eq "$count" "1" "one-entry file yields one pick"
}

test_cache_no_op_when_already_today() {
  source "$LIB"
  mkdir -p "$CEO_DIR/cache"
  printf -- '- first\n- second\n- third\n' > "$CEO_DIR/blessings.md"
  local today; today=$(date +%Y-%m-%d)
  printf -- '---\ndate: %s\n---\n- cached-sentinel\n' "$today" > "$CEO_DIR/cache/blessings-today.md"
  ensure_blessings_cache
  # sentinel must still be present — helper skipped regen
  assert_contains "$(cat "$CEO_DIR/cache/blessings-today.md")" "cached-sentinel" "cache preserved"
}

test_cache_regenerates_when_stale() {
  source "$LIB"
  mkdir -p "$CEO_DIR/cache"
  printf -- '- a\n- b\n- c\n' > "$CEO_DIR/blessings.md"
  printf -- '---\ndate: 1999-01-01\n---\n- stale-sentinel\n' > "$CEO_DIR/cache/blessings-today.md"
  ensure_blessings_cache
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"stale-sentinel"* ]] || {
    printf '  FAIL [%s] stale cache was not replaced\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
}

test_cache_handles_missing_source_file() {
  source "$LIB"
  ensure_blessings_cache  # no blessings.md exists
  local cache="$CEO_DIR/cache/blessings-today.md"
  [[ -f "$cache" ]] || { printf '  FAIL [%s] expected empty cache file\n' "$CURRENT_TEST"; FAILS=$((FAILS+1)); return; }
  local bullet_count
  bullet_count=$(grep -c '^- ' "$cache" 2>/dev/null || true)
  assert_eq "$bullet_count" "0" "no bullets when source missing"
}

test_cache_strips_frontmatter_before_picking() {
  source "$LIB"
  mkdir -p "$CEO_DIR"
  {
    printf -- '---\ntype: ea-blessings\n---\n\n'
    printf -- '- real-entry\n'
  } > "$CEO_DIR/blessings.md"
  ensure_blessings_cache
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"type: ea-blessings"* ]] || {
    printf '  FAIL [%s] frontmatter bled into cache\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
  assert_contains "$content" "- real-entry" "real entry picked"
}

test_show_outputs_cache_file() {
  bash "$CLI" add "a" >/dev/null
  bash "$CLI" add "b" >/dev/null
  bash "$CLI" add "c" >/dev/null
  bash "$CLI" repick >/dev/null
  local out
  out=$(bash "$CLI" show)
  local today; today=$(date +%Y-%m-%d)
  assert_contains "$out" "date: $today" "cache date visible"
}

test_show_on_missing_cache_is_empty() {
  local out
  out=$(bash "$CLI" show 2>&1 || true)
  assert_eq "$out" "" "empty on no cache"
}

test_repick_forces_regeneration() {
  bash "$CLI" add "a" >/dev/null
  bash "$CLI" add "b" >/dev/null
  bash "$CLI" add "c" >/dev/null
  bash "$CLI" repick >/dev/null
  # overwrite cache with sentinel so we can detect a re-pick
  local today; today=$(date +%Y-%m-%d)
  printf -- '---\ndate: %s\n---\n- sentinel\n' "$today" > "$CEO_DIR/cache/blessings-today.md"
  bash "$CLI" repick >/dev/null
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"sentinel"* ]] || {
    printf '  FAIL [%s] repick did not regenerate\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
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
