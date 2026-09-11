#!/bin/bash
# Self-contained test harness for the ceo-cron.sh script-runner branch.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # consumed by the ceo-cron-*.test.sh shards that source this file
CEO_CLI="$SCRIPT_DIR/ceo"
# shellcheck disable=SC2034  # consumed by the ceo-cron-*.test.sh shards that source this file
CRON="$SCRIPT_DIR/ceo-cron.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  # Explicit, not inherited from HOME: scripts that call ceo_pin_home_or_warn
  # re-export HOME from passwd, so a $HOME-derived state path would write to the
  # real user's home from inside a test. See _ceo_state_dir in ceo-config.sh.
  export CEO_STATE_DIR="$TEST_HOME/.ceo/state"
  # The generated registry is host-local now ($HOME/.ceo/registry.json), not in
  # the synced vault. Both `ceo playbook scan` (write) and `ceo cron` (read)
  # resolve this path; tests seed/inspect it here, not under $CEO_DIR.
  REGISTRY_FILE="$HOME/.ceo/registry.json"
  # Bypass the ollama daemon HTTP probe in tests (the stubbed ollama binary
  # has no daemon backing it). Production runs leave this unset.
  export CEO_OLLAMA_SKIP_PROBE=1

  # Isolate cron lock to this test invocation
  export CEO_LOCK_FILE="$TEST_HOME/ceo-cron.lock"

  # Isolate repo playbooks so `ceo playbook scan` only scans the test fixtures
  # created in $CEO_DIR/playbooks, rather than leaking the production repo playbooks.
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"

  # $HOME/.ceo/state is where the per-trigger cron state lives since #394.
  # Production creates it on demand in _ceo_state_migrate, but arms that seed a
  # fail-count or a cooldown stamp write there before the dispatcher runs.
  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/approvals" "$CEO_DIR/reports" "$CEO_REPO_PLAYBOOK_DIR" "$HOME/.ceo" "$CEO_STATE_DIR"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/IDENTITY.md"
  : > "$CEO_DIR/TRAINING.md"
  : > "$CEO_DIR/inbox.md"
  echo "- [ ] test task" > "$CEO_DIR/approvals/pending.md"

  # Stub gh: PR search must not hit real GitHub or the keychain in tests. Per
  # stub-cli-argv-validation it matches the argv production actually emits and
  # exits loudly on any other shape. `auth status` exits non-zero on purpose --
  # the unauthenticated branch is what the preflight arms assert against.
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/gh" << 'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh-invoked.txt"
case "$1 ${2:-}" in
  "auth status") echo "gh stub: not logged in" >&2; exit 1 ;;
  "auth token")  echo "gh stub: no token for '${4:-}'" >&2; exit 1 ;;
  "search prs")  echo "gh stub: unauthenticated" >&2; exit 1 ;;
  *) echo "gh stub: unexpected argv: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/gh"

  # Stub crontab so playbook scan's cron install can't touch the user's real crontab.
  cat > "$TEST_HOME/.bun/bin/crontab" << 'STUB'
#!/bin/bash
# no-op stub for tests
if [ "${1:-}" = "-l" ]; then
  cat "$HOME/.fake-crontab" 2>/dev/null || true
  exit 0
fi
cat > "$HOME/.fake-crontab"
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  : > "$HOME/.fake-crontab"

  # Stub claude on PATH so dispatcher invocations are detectable. Default behavior
  # is success — individual tests override $TEST_HOME/.bun/bin/claude to simulate failure.
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
echo "claude-fired" > "$HOME/claude-invoked.txt"
printf '%s' "${CEO_MODEL_SOURCE:-UNSET}" > "$HOME/claude-model-source.txt"
echo "ACTION: 1 | read | noop | n/a"
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"

  # Stub ollama on PATH for runner:ollama / runner:ollama-think tests. Captures
  # the model argument so tests can assert which model was dispatched.
  # Presence stub: production checks `command -v ollama` before dispatching, but
  # generation now goes through the HTTP API (curl), not `ollama run`. This stub
  # only needs to exist; the curl stub below does the real emulation.
  cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/ollama"

  # _ollama_run posts to the ollama HTTP API (POST /api/generate). Emulate it:
  # validate the request shape (model present, num_ctx a positive integer),
  # capture model/prompt/num_ctx so tests can assert what was dispatched, record
  # full argv (so timeout tests can check --max-time), and return a canned
  # completion. Per stub-cli-argv-validation the stub exits non-zero on a
  # malformed generate call. Any non-generate curl (Discord webhook, daemon
  # probe) execs the real binary so unrelated behavior is unchanged; tests that
  # need different curl behavior override this file.
  cat > "$TEST_HOME/.bun/bin/curl" << 'STUB'
#!/bin/bash
args="$*"
url="" ; data="" ; prev=""
for a in "$@"; do
  case "$prev" in -d|--data|--data-binary|--data-raw) data="$a" ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/generate)
    echo "$args" >> "$HOME/curl-invoked.txt"
    [ "$data" = "@-" ] && data="$(cat)"
    model=$(printf '%s' "$data" | jq -r '.model // empty' 2>/dev/null)
    numctx=$(printf '%s' "$data" | jq -r '.options.num_ctx // empty' 2>/dev/null)
    if [ -z "$model" ]; then echo "curl stub: /api/generate body missing .model" >&2; exit 91; fi
    case "$numctx" in ''|*[!0-9]*|0) echo "curl stub: /api/generate missing positive .options.num_ctx (got '$numctx')" >&2; exit 92 ;; esac
    printf '%s\n' "$model" >> "$HOME/ollama-invoked-model.txt"
    printf '%s' "$data" | jq -r '.prompt // empty' > "$HOME/ollama-invoked-prompt.txt"
    { printf '%s' "$data" | jq -r '.prompt // empty'; printf '\n---CALL---\n'; } >> "$HOME/ollama-invoked-prompts.txt"
    printf '%s' "$numctx" > "$HOME/ollama-invoked-numctx.txt"
    printf '%s' "${CEO_MODEL_SOURCE:-UNSET}" > "$HOME/ollama-model-source.txt"
    printf 'ollama-stub-response' | jq -Rs '{response:.}'
    exit 0 ;;
  *)
    exec /usr/bin/curl "$@" ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/curl"

  # macOS lacks `timeout` from GNU coreutils; the dispatcher uses
  # `timeout N claude ...`. Stub it as a transparent passthrough.
  if ! command -v timeout >/dev/null 2>&1; then
    cat > "$TEST_HOME/.bun/bin/timeout" << 'STUB'
#!/bin/bash
shift  # discard the duration arg
exec "$@"
STUB
    chmod +x "$TEST_HOME/.bun/bin/timeout"
  fi

  export PATH="$TEST_HOME/.bun/bin:$PATH"
}

teardown() {
  # Every arm that dispatches is a tripwire for the #399 keying, not just the one
  # arm that probes it. A single arm can only catch a bare-name write on the code
  # path it happens to exercise — reverting one dry-run line was green across 87
  # tests, which is the shape of the next regression: someone adds a log line and
  # spells the old name by habit.
  #
  # Here rather than in an arm because this runs after all ~200 of them, and the
  # fixture's CEO_DIR accumulates every write the suite made.
  local _bare
  for _bare in cron-skips cron-stdout cron-stderr cron-raw; do
    if [ -e "${CEO_DIR:-}/log/$_bare.log" ]; then
      printf '  FAIL [%s] wrote the shared %s.log — #399 keyed it by host; use $SKIPS_LOG / $CRON_STDOUT_LOG / $CRON_STDERR_LOG\n' \
        "${CURRENT_TEST:-teardown}" "$_bare"
      FAILS=$((FAILS + 1))
    fi
  done

  # Before rm -rf below, since the register lives inside TEST_HOME.
  if [ -f "$TEST_HOME/.fixture-scripts" ]; then
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] && rm -f "$f"
    done < "$TEST_HOME/.fixture-scripts"
  fi
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_STATE_DIR TEST_HOME HOME_BACKUP PATH_BACKUP CEO_REPO_PLAYBOOK_DIR CEO_OLLAMA_SKIP_PROBE CEO_LOCK_FILE
}



# $'\n', not "$(printf '\n')": command substitution strips trailing newlines, so
# the latter is the empty string and `case $f in *""*)` then matches every path.
# The first version of this refused every registration, which the new arms caught.
_FIXTURE_NEWLINE=$'\n'

# _fixture_script <path>... — chmod +x each path and register it for teardown.
#
# These fixtures have to live in SCRIPT_DIR: the runner resolves a playbook's
# `script:` relative to the checked-out scripts/ directory, which is tracked.
# What was wrong was the cleanup, not the location — an `rm -f` on the last line
# of a test body is skipped by a failing assertion, a `return`, or an `exit`,
# leaving an untracked executable in a tracked directory, one `git add -A` from
# a commit (test-writes-stay-in-the-fixture). teardown runs on all of those; a
# test body's last line does not. An interrupt is covered too, but by a separate
# mechanism -- run_tests traps INT/TERM and calls teardown, which it did not
# before this change, so the two have to hold together.
#
# It also protects the -P 4 reasoning in .github/workflows/test.yml, which rests
# on no two suites writing the same fixed path under scripts/. A leaked fixture
# from an aborted run makes that hand-maintained property false for every later
# run on the same checkout.
_fixture_script() {
  local f
  # Loudly, not by returning 1 nobody checks: without the register the fixture
  # stays in scripts/, which is the leak this helper exists to prevent, and
  # these suites run `set -uo pipefail` without -e so a silent failure here
  # would sail past.
  [ -d "${TEST_HOME:-}" ] || {
    echo "_fixture_script: TEST_HOME is not a directory — refusing to register" >&2
    return 1
  }
  for f in "$@"; do
    case "$f" in
      *"$_FIXTURE_NEWLINE"*)
        # The register is newline-delimited, so a path containing one is swept
        # in fragments — and the tail fragment is relative, so `rm -f` runs
        # against the harness cwd instead of SCRIPT_DIR. No fixture needs one.
        echo "_fixture_script: refusing a path containing a newline" >&2
        return 1 ;;
    esac
    chmod +x "$f"
    # A file, not a shell array: test bodies run in a subshell, so an array
    # appended there never reaches teardown in the parent. This is the same
    # channel test-harness.sh uses to carry a subshell's failure count out.
    printf '%s\n' "$f" >> "$TEST_HOME/.fixture-scripts" || return 1
  done
}

# --- shared helpers hoisted from ceo-cron.test.sh (sourced by every ceo-cron-*.test.sh shard) ---

# _stub_gh_prs <count> — replaces the base gh stub with one whose
# `search prs --review-requested` returns <count> PRs. Same argv discipline as
# the base stub: anything unexpected exits 99 rather than returning a plausible
# empty result (stub-cli-argv-validation).
_stub_gh_prs() {
  local n="${1:-0}"
  # A bad argument here would otherwise surface as an arithmetic error inside a
  # test whose own assertion then fails for an unrelated-looking reason.
  case "$n" in
    ''|*[!0-9]*) echo "_stub_gh_prs: PR count must be a non-negative integer, got '$n'" >&2; return 1 ;;
  esac
  local prs_json="[]"
  if [ "$n" -gt 0 ]; then
    prs_json=$(jq -n --argjson count "$n" '[range(1; $count + 1) | {
      number: (100 + .),
      title: "Review PR \(.)",
      createdAt: "2026-09-01T12:00:00Z",
      repository: { nameWithOwner: "testorg/testrepo" }
    }]') || { echo "_stub_gh_prs: jq failed building $n PRs" >&2; return 1; }
  fi

  cat > "$TEST_HOME/.bun/bin/gh" << STUB
#!/bin/bash
echo "\$*" >> "\$HOME/gh-invoked.txt"
case "\$1 \${2:-}" in
  "auth status"*)
    case "\$*" in
      *"--json"*) echo '[{"user":"testuser"}]'; exit 0 ;;
      *) echo "Logged in to github.com account testuser (keyring)"; exit 0 ;;
    esac ;;
  "auth token"*)
    echo "ghp_faketoken12345"
    exit 0 ;;
  "search prs"*)
    case "\$*" in
      *"--review-requested"*)
        printf '%s\n' '$prs_json'
        exit 0 ;;
      *"--state open"*"--author"*)
        echo '[]'
        exit 0 ;;
      *"--merged"*)
        echo '[]'
        exit 0 ;;
      *)
        echo "gh stub: unexpected search prs flags: \$*" >&2
        exit 99 ;;
    esac ;;
  *)
    echo "gh stub: unexpected argv: \$*" >&2
    exit 99 ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/gh"
}

# _stub_gh_prs_review_search_fails — auth fine, only the review-requested search
# fails, the way a rate limit does. Models the half of reality _stub_gh_prs
# cannot: every arm there exits 0, so a suite built on it alone pins the shape
# that makes a degraded source and a quiet day indistinguishable rather than
# probing it. Only the review arm fails, because a test whose every search fails
# passes whether the code keys on the review search or on any of the others.
_stub_gh_prs_review_search_fails() {
  cat > "$TEST_HOME/.bun/bin/gh" << 'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh-invoked.txt"
case "$1 ${2:-}" in
  "auth status"*)
    case "$*" in
      *"--json"*) echo '[{"user":"testuser"}]'; exit 0 ;;
      *) echo "Logged in to github.com account testuser (keyring)"; exit 0 ;;
    esac ;;
  "auth token"*)
    echo "ghp_faketoken12345"
    exit 0 ;;
  "search prs"*)
    case "$*" in
      *"--review-requested"*)
        echo "gh: API rate limit exceeded for user ID 1234567." >&2
        exit 1 ;;
      *"--state open"*"--author"*) echo '[]'; exit 0 ;;
      *"--merged"*) echo '[]'; exit 0 ;;
      *)
        echo "gh stub: unexpected search prs flags: $*" >&2
        exit 99 ;;
    esac ;;
  *)
    echo "gh stub: unexpected argv: $*" >&2
    exit 99 ;;
esac
STUB
  chmod +x "$TEST_HOME/.bun/bin/gh"
}


# --- #173: script playbooks signal fired/noop so _record_success notifies only
# on real work, not on every heartbeat tick. Contract: cron exports
# CEO_RUNNER_OUTCOME_FILE; a script writes "fired" (notify) or "noop" (silent);
# absent => the prior per-trigger default. ---

_write_outcome_playbook() {  # $1=trigger  $2=outcome-to-write (empty = write nothing)
  local trig="$1" outcome="$2"
  cat > "$CEO_DIR/playbooks/$trig.md" << PB
---
name: $trig
description: outcome-signal test
trigger: cron
schedule: "*/30 * * * *"
preflight: none
tier: read
status: active
runner: script
script: $trig-test.sh
---
PB
  cat > "$SCRIPT_DIR/$trig-test.sh" << SH
#!/bin/bash
[ -n "$outcome" ] && [ -n "\$CEO_RUNNER_OUTCOME_FILE" ] && printf '%s' "$outcome" > "\$CEO_RUNNER_OUTCOME_FILE"
exit 0
SH
  _fixture_script "$SCRIPT_DIR/$trig-test.sh"
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
}


_write_pending_drip_registry() {
  cat > "$CEO_DIR/playbooks/pending-drip.md" << 'PB'
---
name: pending-drip
description: Test pending drip
trigger: cron
schedule: "0 9 * * *"
model: haiku
preflight: has_pending_items
tier: read
status: active
---
PB
  cat > "$REGISTRY_FILE" << JSON
{"schema_version":3,"playbooks":[{"name":"pending-drip","file":"$CEO_DIR/playbooks/pending-drip.md","model":"haiku","preflight":"has_pending_items","trigger":"cron","tier":"read","status":"active"}]}
JSON
  printf -- '- [ ] pending approval sentinel\n' > "$CEO_DIR/approvals/pending.md"
  printf -- '- [ ] **file:** sentinel.md **question:** sentinel ask?\n' > "$CEO_VAULT/Pending.md"
}


_stub_claude_log_entry() {
  local status="$1"
  local output="$2"
  # The read-tier single-call path (scripts/ceo-cron.sh) always invokes claude
  # with --output-format json and extracts the body via `jq -r '.result'`, so
  # the stub must emit a JSON envelope, not the raw LOG_ENTRY text.
  local body="LOG_ENTRY:
## 12:00 - pending-drip
**Status:** $status
**Playbook:** pending-drip.md
**Output:**
$output
**Errors:**
- none
END_LOG_ENTRY"
  local json
  json=$(printf '%s' "$body" | jq -Rsc '{result: ., total_cost_usd: 0.001, session_id: "test"}')
  cat > "$TEST_HOME/.bun/bin/claude" << STUB
#!/bin/bash
cat >/dev/null
cat <<'OUT'
$json
OUT
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}


# --- inputs: per-playbook injection filter (0.11.0) ---

# Helper: stub claude to capture stdin (the SINGLE_PROMPT) for inspection.
# Removes any prior capture file so a stale read can't pass an assertion if
# the run errors out before the stub fires.
_stub_claude_capture_stdin() {
  rm -f "$HOME/claude-stdin.txt" "$HOME/claude-invoked.txt"
  cat > "$TEST_HOME/.bun/bin/claude" << 'STUB'
#!/bin/bash
cat > "$HOME/claude-stdin.txt"
echo "claude-fired" > "$HOME/claude-invoked.txt"
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/claude"
}


# --- #137 run-modes: scheduled (cron/daemon, --scheduled) enforces active;
#     manual (default / --manual, on-demand) runs any valid status per
#     docs/playbooks/SCHEMA.md status-semantics. ---

_register_status_playbook() {
  cat > "$CEO_DIR/playbooks/$1.md" << PB
---
name: $1
description: run-mode fixture
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: read
status: $2
---
PB
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1
}


# --- #138: --dry-run preview mode ---
# Preview output is host-local scratch. It moved out of the synced vault to
# $HOME/.ceo/state/preview/ in #394 — the tests inherit the isolation because
# setup() points HOME at the fixture.
_ceo_state() { echo "$CEO_STATE_DIR"; }
_preview_file() { echo "$(_ceo_state)/preview/$1-$(date +%Y-%m-%d).md"; }


# --- #139: hosts: frontmatter (host-scoped scheduling, recorded not enforced) ---
_hosts_in_registry() {
  jq -r --arg n "$1" '.playbooks[] | select(.name==$n) | .hosts | tojson' "$REGISTRY_FILE" 2>/dev/null
}


# --- #140: --test-all (fleet dry-run sweep) ---
_test_all_report() { echo "$(_ceo_state)/preview/test-all/$(date +%Y-%m-%d).md"; }


# Register an active read-tier playbook at a caller-chosen schedule + preflight.
# Distinct schedules avoid the scan-time collision detector (two active cron
# playbooks at the same minute is refused).
_register_pb_sched() {
  local name="$1" sched="$2" preflight="${3:-none}"
  cat > "$CEO_DIR/playbooks/$name.md" << PB
---
name: $name
description: test-all fixture
trigger: cron
schedule: "$sched"
preflight: $preflight
tier: read
status: active
---
PB
}


# --- runner:ollama-agent (bridge) dispatch — epic #197 slice A (#199) ---

# Stub for the bridge CLI. Per stub-cli-argv-validation it pattern-matches the
# exact argv production uses and exits non-zero on any other shape; on a match
# it records the invocation and emits the caller-supplied JSON on stdout.
_make_agent_stub() {
  local json="$1"
  # The argv gate is order-coupled: it matches the flag sequence the dispatch
  # emits (ceo-cron.sh). Reordering flags in production reddens every agent test
  # (fails safe, never silently green); a missing flag exits 97.
  cat > "$HOME/.bun/bin/agent-stub" << STUB
#!/bin/bash
case " \$* " in
  *" --task "*" --task-name "*" --registry "*" --cwd "*" --run-id "*" --json "*) : ;;
  *) echo "agent stub: unexpected argv (missing --task/--cwd/--run-id?): \$*" >&2; exit 97 ;;
esac
printf '%s\n' "\$*" > "\$HOME/agent-argv.txt"
echo invoked >> "\$HOME/agent-invoked.txt"
cat << 'AGENTJSON'
$json
AGENTJSON
STUB
  chmod +x "$HOME/.bun/bin/agent-stub"
  export CEO_OLLAMA_AGENT_CMD="$HOME/.bun/bin/agent-stub"
}


_register_agent_pb() {
  local name="$1" tier="$2"
  printf '{"tasks":{}}' > "$CEO_DIR/bridge-registry.json"
  cat > "$CEO_DIR/playbooks/$name.md" << PB
---
name: $name
description: ollama-agent bridge dispatch test
trigger: cron
schedule: "0 9 * * *"
preflight: none
tier: $tier
status: active
runner: ollama-agent
registry: $CEO_DIR/bridge-registry.json
---
# body
PB
}


# Faithful reproduction of pattern-tracker finding-add's dedup CONTRACT: one row
# per distinct (pr_url|file_path|line_no|summary). pt hashes that 4-tuple into a
# finding_id and INSERTs only on a new id; the stub stores the raw 4-tuple key —
# the dedup behavior is identical, without coupling the test to sha1 internals.
# Argv-validates --db (stub-cli-argv-validation). The "db" is a flat file, one
# unique key per line, so the test just counts lines.
_make_pt_stub() {
  PT_STUB_DB="$HOME/pt-stub-db.txt"
  cat > "$HOME/.bun/bin/pt-stub" << 'STUB'
#!/bin/bash
db=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db) db="$2"; shift 2 ;;
    *) echo "pt-stub: unexpected argv: $1" >&2; exit 99 ;;
  esac
done
[ -z "$db" ] && { echo "pt-stub: missing --db" >&2; exit 99; }
touch "$db"
ins=0; dup=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  key=$(printf '%s' "$line" | jq -r '[.pr_url, .file_path, (.line_no|tostring), .summary] | join("|")')
  if grep -qxF "$key" "$db" 2>/dev/null; then
    dup=$((dup + 1))
  else
    printf '%s\n' "$key" >> "$db"
    ins=$((ins + 1))
  fi
done
echo "inserted=$ins skipped_dup=$dup"
STUB
  chmod +x "$HOME/.bun/bin/pt-stub"
  export CEO_PT_FINDING_CMD="$HOME/.bun/bin/pt-stub --db $PT_STUB_DB"
}


# Stub for `pt event-add` (slice D run-event emit). Argv-validates --db
# (stub-cli-argv-validation) and appends each emitted JSONL row verbatim so a
# test can assert the row shape the cron dispatch built.
_make_pt_event_stub() {
  PT_EVENT_DB="$HOME/pt-event-db.txt"
  cat > "$HOME/.bun/bin/pt-event-stub" << 'STUB'
#!/bin/bash
db=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db) db="$2"; shift 2 ;;
    *) echo "pt-event-stub: unexpected argv: $1" >&2; exit 99 ;;
  esac
done
[ -z "$db" ] && { echo "pt-event-stub: missing --db" >&2; exit 99; }
cat >> "$db"
echo "inserted=1 skipped_dup=0 invalid=0"
STUB
  chmod +x "$HOME/.bun/bin/pt-event-stub"
  export CEO_PT_EVENT_CMD="$HOME/.bun/bin/pt-event-stub --db $PT_EVENT_DB"
}

# The three dispatcher journals are keyed by host since #399, so a test cannot
# name the file — `hostname -s` differs per machine. Read the whole family,
# including the pre-#399 bare names, so an assertion stays true whichever file
# the run wrote to.
_skips_log()  { cat "$CEO_DIR"/log/cron-skips.log  "$CEO_DIR"/log/cron-skips-*.log  2>/dev/null || true; }
_stdout_log() { cat "$CEO_DIR"/log/cron-stdout.log "$CEO_DIR"/log/cron-stdout-*.log 2>/dev/null || true; }
_stderr_log() { cat "$CEO_DIR"/log/cron-stderr.log "$CEO_DIR"/log/cron-stderr-*.log 2>/dev/null || true; }

# The single file this host writes, for arms that need a path rather than the
# contents — seeding one, truncating it, or making it unwritable. Resolved
# through the production helper so the test never spells the name itself.
#
# Only valid when the run under test uses the ambient host. An arm that
# dispatches with CEO_HOSTNAME set writes a different file, and must read the
# family with _skips_log / _stdout_log / _stderr_log instead.
_skips_log_path()  { echo "$CEO_DIR/log/cron-skips-$(_host_slug).log"; }
_stdout_log_path() { echo "$CEO_DIR/log/cron-stdout-$(_host_slug).log"; }
_stderr_log_path() { echo "$CEO_DIR/log/cron-stderr-$(_host_slug).log"; }
_host_slug() { bash -c ". '$SCRIPT_DIR/ceo-config.sh' >/dev/null 2>&1; _ceo_host_slug"; }

# The dispatcher's completion log is keyed by host since #397
# (cron-runs-<host>.log), so a test cannot name the file: `hostname -s` differs
# per machine. Read the whole family, including the pre-#397 bare name, so an
# assertion stays true whichever file the run wrote to.
_runs_log() {
  cat "$CEO_DIR"/log/cron-runs.log "$CEO_DIR"/log/cron-runs-*.log 2>/dev/null || true
}

# Per-trigger fail counters (#298 — the counter used to be one global file, so a
# healthy playbook's success zeroed a failing playbook's streak). With no
# argument this reads the only counter present, which is what nearly every test
# needs since it exercises a single playbook; pass a trigger explicitly when a
# test runs more than one, and the ambiguous case is reported rather than
# silently picking whichever sorted first.
_fail_count() {
  local trigger="${1:-}"
  if [ -n "$trigger" ]; then
    cat "$(_ceo_state)/.fail-count-$trigger" 2>/dev/null || echo "missing"
    return
  fi
  local files=("$(_ceo_state)"/.fail-count-*)
  if [ "${#files[@]}" -gt 1 ]; then echo "AMBIGUOUS(${#files[@]} counters — pass a trigger)"; return; fi
  if [ -f "${files[0]}" ]; then cat "${files[0]}"; else echo "missing"; fi
}
