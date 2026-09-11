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

# Dotfile paths written under the synced CEO/log/ by any non-test script.
#
# Three things this has to see, all of which it missed when the arm below was
# inverted in #394 — and a missed spelling now reads as proof, since the arm
# passes when discovery returns nothing:
#
#   - `${LOG_DIR}/...` as well as `$LOG_DIR/...`
#   - a directory held in an intermediate variable, which is how
#     ceo-discord-report.sh wrote `.last-deliver-*` for months without this
#     noticing, and without any stignore pattern covering it
#   - `scripts/ceo` itself, a 2500-line CLI the old glob never scanned because it
#     has no .sh extension
#
# `_ceo_state_dir`-derived paths are the correct destination and are not matched.
_discover_state_files() {
  local f
  for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/ceo"; do
    case "$f" in
      *.test.sh|*test-common.sh|*test-harness.sh|*debug-*) continue ;;
    esac
    [ -f "$f" ] || continue
    awk '
      BEGIN { vars["LOG_DIR"] = 1 }
      # Any variable ever assigned something that resolves to the synced log dir
      # joins the alternation, so a write through it is seen. LOG_DIR is seeded
      # because it is the base name every other one derives from.
      /^[^#]*[A-Za-z_][A-Za-z0-9_]*=.*(\$\{?LOG_DIR\}?|CEO_DIR\}?\/log|CEO_VAULT\}?\/CEO\/log)/ {
        v = $0
        sub(/=.*$/, "", v)            # keep the name, drop the value
        sub(/^.*[;&|(]/, "", v)       # a second statement on the line
        gsub(/[^A-Za-z0-9_]/, "", v)  # leading space, `local `, quotes
        sub(/^local/, "", v)
        if (v != "") vars[v] = 1
      }
      {
        # The fully-spelled forms, which name no intermediate variable.
        l0 = $0
        while (match(l0, /\$\{?(CEO_DIR\}?\/log|CEO_VAULT\}?\/CEO\/log)"?\/\.[a-zA-Z-]+/)) {
          m0 = substr(l0, RSTART, RLENGTH)
          l0 = substr(l0, RSTART + RLENGTH)
          sub(/^.*\//, "", m0)
          print m0
        }
        for (v in vars) {
          l = $0
          while (match(l, "\\$\\{?" v "\\}?\"?/\\.[a-zA-Z-]+")) {
            m = substr(l, RSTART, RLENGTH)
            l  = substr(l, RSTART + RLENGTH)
            sub(/^.*\//, "", m)
            print m
          }
        }
      }' "$f"
  done | sed 's/^\.\././' | sort -u
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

test_the_discovery_step_can_still_see_a_violation() {
  # The positive control for the arm below. That arm's entire content is "discovery
  # returned nothing", so a discovery step that has quietly gone blind is
  # indistinguishable from a clean tree — the test reports success at the moment it
  # stops working. #394 shipped exactly that: the pattern matched only the literal
  # `$LOG_DIR/.x` form, so `.last-deliver-*`, written through an intermediate
  # variable, was invisible and had been syncing between hosts unnoticed.
  #
  # Each spelling below is one that was missed. Seed it, prove discovery finds it,
  # remove it.
  local probe="$SCRIPT_DIR/zz-stignore-probe.sh" spelling found
  for spelling in \
    'echo x > "$LOG_DIR/.probe-plain"' \
    'echo x > "${LOG_DIR}/.probe-braced"' \
    '_d="$CEO_DIR/log"; echo x > "$_d/.probe-indirect"' \
    '  _dd="$CEO_DIR/log"; _p="$_dd/.probe-indented"' \
    'local _e="$CEO_DIR/log"; echo x > "$_e/.probe-local"'
  do
    printf '#!/bin/bash\n%s\n' "$spelling" > "$probe"
    found=$(_discover_state_files | grep -c '^\.probe-' || true)
    rm -f "$probe"
    if [ "$found" -ge 1 ]; then
      assert_eq "seen" "seen" "discovery sees: $spelling"
    else
      assert_eq "BLIND" "seen" "discovery is blind to: $spelling"
    fi
  done
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
  # wrong: the cron-skips/stdout/stderr journals also live under CEO/log/ and are
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
