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
#
# An approximation: this is bash globbing, not Syncthing's matcher. They agree on
# every pattern in the file today (the one difference that matters is that
# Syncthing's `*` does not cross `/` while bash's does, and no pattern here
# relies on it), but a green result is evidence the text is present and
# plausible, not that Syncthing honors it.
_is_ignored() {
  local path="$1" line
  while IFS= read -r line; do
    case "$line" in ''|'//'*|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the pattern is data — glob expansion is the point
    case "$path" in $line) return 0 ;; esac
  done < "$STIGNORE"
  return 1
}

test_no_host_local_state_is_written_under_the_synced_log_dir() {
  # This arm used to assert that every host-local dotfile written under $LOG_DIR
  # was matched by a shared.stignore pattern. #394 removed the need for that
  # question by removing its subject: the per-trigger cron state, the scan
  # marker, and the nathan-inbox cursors all moved to $HOME/.ceo/state/, so the
  # correct assertion is now the stronger one — nothing writes host-local state
  # there at all.
  #
  # That inversion matters because the old test could only ever be as good as the
  # deployment of the file it checked. A pattern present in the tracked stignore
  # protects a host that copied it into its vault root, and nothing verifies that
  # copy: on 2026-09-09 both swarm hosts were found running an August copy. A
  # path that is never written cannot leak regardless of what any host deployed.
  #
  # A new $LOG_DIR/.something write is the regression this catches. The fix is
  # _ceo_state_migrate in ceo-config.sh, not a new stignore line.
  local found=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=$((found + 1))
    fail_test "host-local state '$name' is written under the synced CEO/log/" \
      "use _ceo_state_migrate (ceo-config.sh) so it lands in \$HOME/.ceo/state instead"
  done < <(_discover_state_files)
  if [ "$found" -eq 0 ]; then
    assert_eq "0" "0" "no host-local dotfile state is written under CEO/log/"
  fi
}

test_stignore_still_covers_the_pre_394_state_paths() {
  # #394 moved the per-trigger cron state to $HOME/.ceo/state/, so no current
  # source line writes these paths and the discovery step above no longer finds
  # them. The patterns still matter: an upgrading host has the old files sitting
  # in its vault until its first run migrates them, and hosts do not upgrade
  # together. Removing them would resync that window.
  #
  # The preview entry is asserted as the directory, not a file inside it. The
  # pattern is `CEO/log/preview/`, which Syncthing applies to the directory and
  # everything beneath; the bash `case` in _is_ignored does not walk into it. That
  # is the approximation _is_ignored already warns about, showing up in the one
  # place in this file where the two matchers actually differ.
  local path
  for path in \
    "CEO/log/.fail-count-morning-scan" \
    "CEO/log/.last-run-morning-scan" \
    "CEO/log/.last-scan" \
    "CEO/log/.from-nathan-seen" \
    "CEO/log/.nathan-nb-counter" \
    "CEO/log/preview/"
  do
    if _is_ignored "$path"; then
      assert_eq "ignored" "ignored" "$path is excluded from sync"
    else
      assert_eq "NOT-ignored" "ignored" \
        "$path is legacy host-local state but no shared.stignore pattern matches it"
    fi
  done
}

test_stignore_covers_the_completion_log_under_both_names() {
  # cron-runs.log is host-local runtime state like the counters above, but it is
  # not a dotfile, so _discover_state_files never sees it and this needs its own
  # arm. It synced for months and Syncthing forked it into ten .sync-conflict
  # copies (#397).
  #
  # Widening the discovery awk to non-dot names is the obvious repair and it is
  # wrong: cron-skips.log and cron-stderr.log also live under CEO/log/ and are
  # deliberately synced (SCHEMA.md), so a wider pattern reds the suite on two
  # correct files. Hardcoding here is the price of that, and the header's
  # derive-don't-restate promise does not reach this case.
  local path
  for path in \
    "CEO/log/cron-runs.log" \
    "CEO/log/cron-runs-ml1.log" \
    "CEO/log/cron-runs-unknown.log" \
    "CEO/log/cron-runs.sync-conflict-20260909-060125-UISIR4Z.log"
  do
    if _is_ignored "$path"; then
      assert_eq "ignored" "ignored" "$path is excluded from sync"
    else
      assert_eq "NOT-ignored" "ignored" \
        "$path is host-local state but no shared.stignore pattern matches it"
    fi
  done
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
