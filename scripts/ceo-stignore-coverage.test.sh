#!/bin/bash
# Every host-local runtime file the scripts write under CEO/log must be excluded
# from Syncthing by syncthing/shared.stignore.
#
# #299 renamed the single `.fail-count` to `.fail-count-<trigger>` and the
# stignore kept the bare name, which silently stopped matching. All nine
# per-trigger counters then synced between hosts, reintroducing the very bug
# #299 fixed — a healthy playbook zeroing a failing one's streak — except across
# hosts instead of across triggers, plus Syncthing conflict copies on concurrent
# writes. Nothing failed; both hosts just agreed on a wrong number.
#
# So the check derives the file list from the source rather than restating it: a
# state file added or renamed later is picked up here automatically, which is the
# only version of this test that survives the next rename.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STIGNORE="$REPO_ROOT/syncthing/shared.stignore"

# Dotfile paths written under $LOG_DIR / $CEO_DIR/log by any non-test script.
# A trailing "-" in the captured name means the source interpolated a trigger or
# similar suffix, so the example path substitutes a concrete one.
_discover_state_files() {
  local f
  for f in "$SCRIPT_DIR"/*.sh; do
    case "$f" in
      *.test.sh|*test-common.sh|*test-harness.sh|*debug-*) continue ;;
    esac
    awk 'match($0, /\$(LOG_DIR|CEO_DIR\/log)"?\/\.[a-z-]+/) {
      m = substr($0, RSTART, RLENGTH)
      sub(/^\$(LOG_DIR|CEO_DIR\/log)"?\//, "", m)
      print m
    }' "$f"
  done | sort -u
}

# Does any stignore pattern glob-match this vault-relative path?
_is_ignored() {
  local path="$1" line
  while IFS= read -r line; do
    case "$line" in ''|'//'*|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the pattern is data — glob expansion is the point
    case "$path" in $line) return 0 ;; esac
  done < "$STIGNORE"
  return 1
}

test_stignore_covers_every_host_local_log_file() {
  local name example found=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=$((found + 1))
    example="$name"
    case "$name" in *-) example="${name}example" ;; esac
    if _is_ignored "CEO/log/$example"; then
      assert_eq "ignored" "ignored" "CEO/log/$example is excluded from sync"
    else
      assert_eq "NOT-ignored" "ignored" \
        "CEO/log/$example is host-local state but no shared.stignore pattern matches it"
    fi
  done < <(_discover_state_files)

  # A discovery step that silently finds nothing would make every assertion above
  # vacuous and this test permanently green.
  if [ "$found" -lt 4 ]; then
    printf '  FAIL [%s] discovery found only %d state files; the awk pattern has drifted from the source\n' \
      "${CURRENT_TEST:-stignore}" "$found"
    _record_assertion_fail
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_bare_fail_count_pattern_would_not_cover_the_per_trigger_counters() {
  # Pins the specific regression: assert the pre-fix pattern really was the
  # problem, so this file documents a demonstrated failure rather than a theory.
  local path="CEO/log/.fail-count-morning"
  local bare="CEO/log/.fail-count"
  # shellcheck disable=SC2254
  case "$path" in $bare) assert_eq "matched" "no-match" \
      "the bare pattern must NOT match a per-trigger counter — if it does, this test is meaningless" ;;
    *) assert_eq "no-match" "no-match" "the bare .fail-count pattern does not match .fail-count-<trigger>" ;;
  esac
  if _is_ignored "$path"; then
    assert_eq "ignored" "ignored" "the current stignore does cover .fail-count-<trigger>"
  else
    assert_eq "NOT-ignored" "ignored" "the current stignore must cover .fail-count-<trigger>"
  fi
}

test_stignore_file_exists_and_is_readable() {
  assert_file_exists "$STIGNORE" "syncthing/shared.stignore must exist for this check to mean anything"
}

run_tests
