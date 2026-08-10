#!/bin/bash
# Tests for ceo-gather.sh — truncation must not abort the run (#293).
#
# These run the gather under `set -euo pipefail`, matching ceo-cron.sh, because
# that is the only mode the bug appears in: a truncating consumer that closes
# its input early makes the producer die on SIGPIPE, pipefail surfaces 141, and
# errexit aborts before any playbook work happens. The sibling suite
# (ceo-gather.test.sh) sources under `set +eu` with no pipefail, so a
# `grep | head` pipeline there always reports head's 0 — it structurally cannot
# observe this bug class.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  OLD_HOME="$HOME"
  OLD_PATH="$PATH"
  export HOME="$TMP"
  export CEO_VAULT="$TMP/vault"
  mkdir -p "$CEO_VAULT/CEO/approvals" "$CEO_VAULT/CEO/log"

  mkdir -p "$TMP/.ceo"
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": [] }, "gitlab": { "usernames": [] } }
JSON

  # Stub out the network tools so the gather is deterministic and offline. Both
  # report unauthenticated, which skips their blocks entirely.
  mkdir -p "$TMP/bin"
  for _tool in gh glab; do
    cat > "$TMP/bin/$_tool" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$TMP/bin/$_tool"
  done
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  export HOME="$OLD_HOME"
  export PATH="$OLD_PATH"
  # Restore readability first or the rm fails on the unreadable-file fixture.
  chmod -R u+rwX "$TMP" 2>/dev/null || true
  unset CEO_VAULT
  rm -rf "$TMP"
}

# Source the gather under production's shell options and report the exit status
# alongside the variable under test and the degradation flag. Anything that trips
# errexit shows up as a non-zero RC here instead of killing the harness.
# Run in a SEPARATE bash process, not `( set -euo pipefail … ) || …`. A subshell
# used as the left operand of `||` has errexit suppressed, so that shape silently
# reports RC=0 for a run that production would abort — it cannot observe the very
# bug this suite exists for. A child process also matches production: ceo-cron.sh
# is its own process with `set -euo pipefail` at the top. Exported env (HOME,
# CEO_VAULT, PATH) is inherited.
_run_gather_strict() {
  local var="$1" rc=0 out
  out=$(bash -c '
    set -euo pipefail
    source "$1" >/dev/null 2>&1
    var="$2"
    printf "RC=0|LINES=%s|DEGRADED=%s|STATUS=%s|FIRST=%s\n" \
      "$(printf "%s" "${!var}" | grep -c . || true)" \
      "${FILE_GATHER_DEGRADED:-0}" \
      "${CEO_GATHER_STATUS:-?}" \
      "$(printf "%s" "${!var}" | head -1)"
  ' _ "$SCRIPT_DIR/ceo-gather.sh" "$var" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'RC=%s|LINES=-|DEGRADED=-|STATUS=-|FIRST=-\n' "$rc"
  else
    printf '%s\n' "$out"
  fi
}

# Write a Pending.md whose matched output is large enough to still be streaming
# when a truncating consumer closes the pipe. SIGPIPE only fires if the producer
# is mid-write, so the payload must exceed the ~64KB pipe buffer — 500 short
# lines fit inside it and the bug hides. Guarded by _assert_fixture_reproduces
# below rather than trusted.
_write_oversized_pending() {
  local pad; pad=$(printf 'x%.0s' $(seq 1 300))
  local i
  : > "$CEO_VAULT/Pending.md"
  for i in $(seq 1 500); do
    echo "- [ ] [ask] (qid: q-$i) question $i $pad" >> "$CEO_VAULT/Pending.md"
  done
}

# The fixture is only meaningful if it actually reproduces the original bug, and
# the threshold depends on the platform's pipe buffer plus head's read-ahead —
# neither visible here. So assert the pre-fix form still dies on this exact file,
# and that it dies of SIGPIPE (141) specifically rather than some other error.
# Without this, shrinking the fixture silently returns the suite to
# green-against-broken, which is how the first draft of this test passed.
# Separate process for the same reason as _run_gather_strict — `( … ) || rc=$?`
# suppresses errexit and reports a misleading 0.
_assert_fixture_reproduces() {
  local file="$1" rc=0
  bash -c '
    set -euo pipefail
    _naive=$(grep -n "^- \[ \]" "$1" 2>/dev/null | head -20)
    printf "%s" "$_naive" >/dev/null
  ' _ "$file" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "141" \
    "fixture must still SIGPIPE the pre-fix \`grep | head\` form, or it proves nothing"
}

# An oversized Pending.md must truncate, not abort. Reverting to
# `grep … | head -20` makes this fail with RC=141.
test_oversized_pending_does_not_abort() {
  _write_oversized_pending
  _assert_fixture_reproduces "$CEO_VAULT/Pending.md"

  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0|LINES=20" \
    "an oversized Pending.md must truncate to 20 lines, not abort (#293)"
  # Pin *which* 20. The contract is "top entries only", and a line-count-only
  # assertion passes just as happily on the last 20. grep -n makes this cheap.
  assert_contains "$out" "FIRST=1:- [ ] [ask] (qid: q-1)" \
    "the cap must keep the FIRST 20 matches, not the last"
  assert_contains "$out" "DEGRADED=0" \
    "a successful truncation is not a degradation"
}

# The complement: an under-cap file returns every line and still exits clean, so
# the fix cannot pass by truncating to nothing.
test_small_pending_returns_all_lines() {
  { for i in 1 2 3; do echo "- [ ] [ask] (qid: q-$i) question $i"; done; } \
    > "$CEO_VAULT/Pending.md"

  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0|LINES=3" \
    "an under-cap Pending.md must return all its lines"
}

# grep exits 1 when nothing matches, which pipefail surfaced just as fatally as
# the SIGPIPE. Empty is a legitimate state — the pending-drip preflight skips on
# it — so it must not abort. This behavior is load-bearing and was untested.
test_empty_pending_does_not_abort() {
  : > "$CEO_VAULT/Pending.md"
  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0|LINES=0" \
    "an empty Pending.md must skip, not abort (grep rc=1 under pipefail)"
  assert_contains "$out" "DEGRADED=0" \
    "legitimately-empty is not a degradation"
}

# Same path: file has content but no *unchecked* items.
test_all_checked_pending_does_not_abort() {
  { for i in 1 2 3; do echo "- [x] [ask] (qid: q-$i) done $i"; done; } \
    > "$CEO_VAULT/Pending.md"
  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0|LINES=0" \
    "a fully-checked Pending.md must skip, not abort"
  assert_contains "$out" "DEGRADED=0" \
    "no unchecked items is a quiet day, not a failure"
}

# The distinction a bare `|| true` destroys: an unreadable file yields the same
# empty string as a file with nothing in it. Tolerating grep's exit 1 must not
# also tolerate exit 2, or the gather reports "quiet day" on an IO error.
test_unreadable_pending_marks_degraded() {
  echo "- [ ] [ask] (qid: q-1) question" > "$CEO_VAULT/Pending.md"
  chmod 000 "$CEO_VAULT/Pending.md"

  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  chmod 644 "$CEO_VAULT/Pending.md"

  assert_contains "$out" "RC=0" \
    "an unreadable Pending.md must not abort the gather"
  assert_contains "$out" "DEGRADED=1" \
    "an unreadable Pending.md must mark the gather degraded, not read as empty"
  assert_not_contains "$out" "STATUS=empty" \
    "an IO error must never be reported as a quiet day (#293 review)"
}

# Sibling site: Profile.md's Active Domains section past the byte cap must
# truncate rather than abort. Note GATHER_MAX_FILE is set unconditionally inside
# the gather, so the cap here is its value (10000), not anything a caller sets.
test_oversized_active_domains_does_not_abort() {
  { echo "## Active Domains"
    for i in $(seq 1 2000); do echo "- domain $i with padding to exceed the byte cap"; done
    echo "## Next Section"; } > "$CEO_VAULT/Profile.md"

  local out; out=$(_run_gather_strict ACTIVE_DOMAINS_CONTENT)
  assert_contains "$out" "RC=0" \
    "an oversized Active Domains section must not abort the gather (#293)"
  # Without this the test passes with the content empty, so a broken sed pattern
  # would sail through.
  assert_contains "$out" "FIRST=## Active Domains" \
    "the section must actually be captured, not silently emptied"
}

# The ledger glob: dir present but holding no .md leaves the glob literal, ls
# exits non-zero, and pipefail + errexit aborted the whole gather — same blast
# radius as #293, different mechanism.
test_empty_ledger_dir_does_not_abort() {
  mkdir -p "$CEO_VAULT/CEO/model"
  local out; out=$(_run_gather_strict LEDGER_RECENT)
  assert_contains "$out" "RC=0" \
    "a model/ dir with no .md files must not abort the gather"
}

run_tests
