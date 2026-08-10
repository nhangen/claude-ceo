#!/bin/bash
# Tests for ceo-gather.sh — truncation must not abort the run (#293).
#
# These run the gather under `set -euo pipefail`, matching ceo-cron.sh, because
# that is the only mode the bug appears in: a truncating consumer that closes
# its input early makes the producer die on SIGPIPE, pipefail surfaces 141, and
# errexit aborts before any playbook work happens. The sibling suite
# (ceo-gather.test.sh) sources under `set +eu` and cannot observe this.

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
  unset CEO_VAULT
  rm -rf "$TMP"
}

# Source the gather under production's shell options and report the exit status
# alongside the variable under test. Anything that trips errexit shows up as a
# non-zero RC here.
_run_gather_strict() {
  local var="$1"
  ( set -euo pipefail
    source "$SCRIPT_DIR/ceo-gather.sh" >/dev/null 2>&1
    printf 'RC=0|VALUE_LINES=%s\n' "$(printf '%s' "${!var}" | grep -c . || true)"
  ) || printf 'RC=%s|VALUE_LINES=-\n' "$?"
}

# A Pending.md far past the 20-line cap must truncate, not abort. Reverting the
# fix to `grep … | head -20` makes this fail with RC=141.
#
# The padding is load-bearing, not decoration. SIGPIPE only fires if the producer
# is still writing when the consumer closes, so the matched output has to exceed
# the ~64KB pipe buffer — 500 short lines fit inside it and the bug hides. The
# real Pending.md that broke production was 952 lines of paragraph-length text.
test_oversized_pending_does_not_abort() {
  local pad; pad=$(printf 'x%.0s' $(seq 1 300))
  { for i in $(seq 1 500); do echo "- [ ] [ask] (qid: q-$i) question $i $pad"; done; } \
    > "$CEO_VAULT/Pending.md"

  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0" \
    "an oversized Pending.md must not abort the gather (#293 — SIGPIPE via head)"
  assert_contains "$out" "VALUE_LINES=20" \
    "PENDING_ASK_QUESTIONS must still be capped at 20 lines"
}

# The complement: an under-cap file returns every line and still exits clean, so
# the fix can't pass by truncating to nothing.
test_small_pending_returns_all_lines() {
  { for i in 1 2 3; do echo "- [ ] [ask] (qid: q-$i) question $i"; done; } \
    > "$CEO_VAULT/Pending.md"

  local out; out=$(_run_gather_strict PENDING_ASK_QUESTIONS)
  assert_contains "$out" "RC=0|VALUE_LINES=3" \
    "an under-cap Pending.md must return all its lines"
}

# Same invariant on the sibling site: Profile.md's Active Domains section past
# the byte cap must truncate rather than abort.
test_oversized_active_domains_does_not_abort() {
  { echo "## Active Domains"
    for i in $(seq 1 2000); do echo "- domain $i with padding to exceed the byte cap"; done
    echo "## Next Section"; } > "$CEO_VAULT/Profile.md"

  local out; out=$(GATHER_MAX_FILE=512 _run_gather_strict ACTIVE_DOMAINS_CONTENT)
  assert_contains "$out" "RC=0" \
    "an oversized Active Domains section must not abort the gather (#293)"
}

run_tests
