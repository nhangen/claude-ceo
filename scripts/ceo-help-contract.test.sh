#!/bin/bash
# The help contract (#367): asking a `ceo` subcommand for help performs no work.
#
# `ceo playbook sync --help` performed a live vault sync because the subcommand
# recognized only the flags it knew and silently dropped the rest. The fix
# guards two layers -- a pre-dispatch intercept in the top-level `case`, and a
# guard inside each subcommand function. The intercept shadows the function
# guards for every CLI invocation, so the CLI-driven suites cannot tell whether
# the inner guards still exist. This file drives the functions DIRECTLY, with
# CEO_LIB_ONLY=1, so a removed inner guard fails here instead of waiting for a
# future in-repo caller to rediscover it.
#
# Every arm asserts the absence of a write, not just an exit code. `--help`
# exiting 0 was never the bug.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
  # Bind CEO_VAULT first: ceo_load_config short-circuits on an already-set
  # vault, which keeps the developer's real ~/.ceo/config from leaking values
  # (CEO_OWNER_STALE_S, CEO_OS) into this harness process. setup() rebinds it.
  export CEO_VAULT="${CEO_VAULT:-$(mktemp -d)}"
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}

_load_ceo_helpers

setup() {
  TMP=$(mktemp -d)
  HOME_BACKUP="$HOME"
  export HOME="$TMP/home"; mkdir -p "$HOME/.ceo"
  export CEO_VAULT="$TMP/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  VAULT_PB="$CEO_DIR/playbooks"
  REPO_PB="$TMP/repo/docs/playbooks"
  mkdir -p "$VAULT_PB" "$REPO_PB" "$CEO_DIR"
  export CEO_REPO_PLAYBOOK_DIR="$REPO_PB"

  # A repo playbook absent from the vault: sync has real work queued, so a
  # guard that fails open shows up as a file appearing in the vault.
  printf -- '---\nname: pb\nstatus: active\nscope: each\n---\n# pb\n' > "$REPO_PB/pb.md"

  # An owner with no heartbeat is stale, so owners-health has an inbox line and
  # a state-file write queued for the same reason.
  printf '%s\n' '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb": "ml-1" } }' \
    > "$CEO_DIR/swarm.json"

  # `ghost` has no playbook file, so a real scan drops it. Asserting it survives
  # is how a scan that ran anyway becomes visible -- `pb` alone would not, since
  # the repo playbook is also named `pb` and a real scan would rewrite the entry
  # to the same name.
  cat > "$HOME/.ceo/registry.json" << 'JSON'
{
  "schema_version": 3,
  "playbooks": [
    { "name": "pb",    "description": "d", "status": "active", "trigger": "cron", "scope": "each" },
    { "name": "ghost", "description": "d", "status": "active", "trigger": "cron", "scope": "each" }
  ]
}
JSON

  # disable-when-absent is a documented no-op success, so a disable that ran
  # anyway would be invisible unless the playbook starts enabled.
  printf '%s\n' '["pb"]' > "$HOME/.ceo/enabled.json"

  _snapshot_state
}

# Checksum every file the fixture owns. `_wrote_anything` diffs against this, so
# a modified file counts, not just a created one: swarm.json, enabled.json and
# registry.json all exist at setup and would otherwise be invisible.
_snapshot_state() {
  STATE_SNAPSHOT="$TMP/state.snapshot"
  _state_manifest > "$STATE_SNAPSHOT"
}

_state_manifest() {
  find "$CEO_DIR" "$HOME/.ceo" -type f 2>/dev/null | sort | while read -r f; do
    printf '%s %s\n' "$(shasum "$f" | cut -d" " -f1)" "$f"
  done
}

teardown() {
  rm -rf "$TMP"
  export HOME="$HOME_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR CEO_HOSTNAME VAULT_PB REPO_PB TMP \
    STATE_SNAPSHOT STUB_BIN OUTBOUND_LOG
}

# Any file under the fixture that was created, removed, or modified since
# setup, as a space-separated list of basenames. Empty means nothing wrote.
_wrote_anything() {
  diff <(cat "$STATE_SNAPSHOT") <(_state_manifest) 2>/dev/null \
    | grep -E '^[<>]' | awk '{print $NF}' | xargs -n1 basename 2>/dev/null \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

_call() { CALL_OUT=$("$@" 2>&1); CALL_RC=$?; }

_assert_help_only() {
  local label="$1" expected_usage="$2"
  assert_eq "$CALL_RC" "0" "$label must exit 0"
  assert_contains "$CALL_OUT" "$expected_usage" "$label must print its usage"
  assert_eq "$(_wrote_anything)" "" "$label must write nothing"
}

test_sync_function_answers_help() {
  _call cmd_playbook_sync --help
  _assert_help_only "cmd_playbook_sync --help" "Usage: ceo playbook sync"
}

test_diff_function_answers_help() {
  _call cmd_playbook_diff --help
  _assert_help_only "cmd_playbook_diff --help" "Usage: ceo playbook diff"
}

test_scan_function_answers_help() {
  _call cmd_playbook_scan --help
  _assert_help_only "cmd_playbook_scan --help" "Usage: ceo playbook scan"
  # This, not the generic write check, is what pins scan: `ghost` has no
  # playbook file, so a scan that ran would drop it. A real scan needs a
  # crontab stub this fixture deliberately does not carry, so it has no control
  # arm below -- the ghost entry is the whole assertion.
  assert_eq "$(jq -r '[.playbooks[].name] | sort | join(",")' "$HOME/.ceo/registry.json")" "ghost,pb" \
    "scan --help must leave the registry untouched, ghost entry and all"
}

test_list_function_answers_help() {
  _call cmd_playbook_list --help
  _assert_help_only "cmd_playbook_list --help" "Usage: ceo playbook list"
}

test_enable_function_answers_help_after_a_name() {
  _call cmd_playbook_enable pb --help
  _assert_help_only "cmd_playbook_enable pb --help" "Usage: ceo playbook enable"
}

test_disable_function_answers_help_after_a_name() {
  # pb is enabled in setup on purpose: disabling an already-disabled playbook
  # is a no-op success, which would make the write assertion vacuous.
  assert_contains "$(cat "$HOME/.ceo/enabled.json")" "pb" "precondition: pb starts enabled"
  _call cmd_playbook_disable pb --help
  _assert_help_only "cmd_playbook_disable pb --help" "Usage: ceo playbook disable"
}

test_info_function_answers_help_after_a_name() {
  _call cmd_playbook_info pb --help
  _assert_help_only "cmd_playbook_info pb --help" "Usage: ceo playbook info"
}

test_assign_function_answers_help_after_a_name() {
  _call cmd_playbook_assign pb ml-1 --help
  _assert_help_only "cmd_playbook_assign pb ml-1 --help" "Usage: ceo playbook assign"
}

test_owners_health_function_answers_help() {
  # The sibling arg-reject masks the write half: with only the help guard gone,
  # this returns 1 before writing. The exit code and usage are what this arm
  # pins; the write is pinned by ceo-swarm.test.sh through the CLI.
  _call cmd_swarm_owners_health --help
  _assert_help_only "cmd_swarm_owners_health --help" "Usage: ceo swarm owners-health"
}

test_swarm_doctor_function_answers_help() {
  _call cmd_swarm_doctor --help
  _assert_help_only "cmd_swarm_doctor --help" "Usage: ceo swarm doctor"
}

test_help_answers_before_the_vault_requirement() {
  # sync and diff open with `: "${CEO_VAULT:?...}"`. The guard sits above it, so
  # a sourced caller on a host that has never run `ceo setup` still gets usage
  # rather than a FATAL. The CLI path is covered by the top-level intercept and
  # cannot see this ordering.
  unset CEO_VAULT
  _call cmd_playbook_sync --help
  assert_eq "$CALL_RC" "0" "cmd_playbook_sync --help must exit 0 with CEO_VAULT unset"
  assert_contains "$CALL_OUT" "Usage: ceo playbook sync" "usage must print with CEO_VAULT unset"
  assert_not_contains "$CALL_OUT" "CEO_VAULT must be set" "help must answer above the vault gate"
}

test_fixture_would_detect_a_write() {
  # The arms above are worth only their exit codes unless the fixture has real
  # work queued for each command AND `_wrote_anything` can see it. Prove both,
  # per write target, or a "must write nothing" assertion is decoration.
  cmd_playbook_sync >/dev/null 2>&1 || true
  assert_contains "$(_wrote_anything)" "pb.md" "control: sync must write the vault playbook"

  _snapshot_state
  cmd_playbook_disable pb >/dev/null 2>&1 || true
  assert_contains "$(_wrote_anything)" "enabled.json" "control: disable must rewrite enabled.json"

  _snapshot_state
  cmd_swarm_owners_health >/dev/null 2>&1 || true
  local wrote; wrote=$(_wrote_anything)
  assert_contains "$wrote" "owner-staleness-state.json" \
    "control: owners-health must write the staleness state"
  assert_contains "$wrote" "$CEO_HOSTNAME.md" \
    "control: owners-health must append to the synced inbox"
}


# --- The CLI-wide gate ---
# `ceo test --help` ran a full morning-brief: `claude`, `gh`, and four dated
# files into the synced vault. `preflight`, `doctor`, and `pr-sources` ignored
# argv the same way. The gate sits ahead of the dispatch table, so these arms
# drive the CLI rather than a function.
#
# Every arm below runs with stubbed `claude` and `gh` on PATH. That is not
# tidiness: if the gate regresses, `ceo test --help` reaches a real model call,
# and a test suite must never be able to spend money or touch the network.

_stub_outbound() {
  STUB_BIN="$TMP/stub-bin"
  OUTBOUND_LOG="$TMP/outbound.log"
  mkdir -p "$STUB_BIN"
  : > "$OUTBOUND_LOG"
  local b
  for b in claude gh; do
    cat > "$STUB_BIN/$b" <<STUB
#!/bin/bash
echo "$b \$*" >> "$OUTBOUND_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN/$b"
  done
}

# Run the real CLI with outbound tools stubbed and the fixture's env bound.
_cli() {
  _stub_outbound
  CALL_OUT=$(env HOME="$HOME" CEO_VAULT="$CEO_VAULT" CEO_DIR="$CEO_DIR" \
    CEO_HOSTNAME="$CEO_HOSTNAME" CEO_REPO_PLAYBOOK_DIR="$CEO_REPO_PLAYBOOK_DIR" \
    PATH="$STUB_BIN:$PATH" bash "$CEO_CLI" "$@" 2>&1)
  CALL_RC=$?
}

_vault_file_count() { find "$CEO_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }

_assert_gate() {
  local label="$1" before="$2"
  assert_eq "$CALL_RC" "0" "$label must exit 0"
  assert_contains "$CALL_OUT" "Usage:" "$label must print usage"
  assert_eq "$(_vault_file_count)" "$before" "$label must write nothing into the vault"
  assert_eq "$(wc -l < "$OUTBOUND_LOG" | tr -d ' ')" "0" \
    "$label must not invoke claude or gh"
}

test_cli_test_help_runs_no_morning_brief() {
  local before; before=$(_vault_file_count)
  _cli test --help
  _assert_gate "ceo test --help" "$before"
}

test_cli_preflight_help_makes_no_api_calls() {
  local before; before=$(_vault_file_count)
  _cli preflight --help
  _assert_gate "ceo preflight --help" "$before"
}

test_cli_doctor_help_spawns_nothing() {
  local before; before=$(_vault_file_count)
  _cli doctor --help
  _assert_gate "ceo doctor --help" "$before"
}

test_cli_pr_sources_help_writes_no_config() {
  local before; before=$(_vault_file_count)
  _cli pr-sources --help
  _assert_gate "ceo pr-sources --help" "$before"
  assert_eq "$([ -e "$HOME/.ceo/pr-sources.json" ] && echo yes || echo no)" "no" \
    "pr-sources --help must not write its config"
}

test_cli_creds_still_answers_its_own_help() {
  # creds is excluded from the gate because it handles help itself. Confirm the
  # exclusion did not cost it its answer.
  _cli creds --help
  assert_eq "$CALL_RC" "0" "ceo creds --help must exit 0"
  assert_contains "$CALL_OUT" "Usage: ceo creds" "creds must print its own usage, not the top-level one"
}

test_cli_bare_help_word_works_on_the_groups() {
  # "Run: ceo playbook help" is what the CLI's own unknown-command error says,
  # and that spelling was still behind ceo_require_vault.
  _cli playbook help
  assert_eq "$CALL_RC" "0" "ceo playbook help must exit 0"
  assert_contains "$CALL_OUT" "Usage: ceo playbook" "must print the playbook overview"
  _cli swarm help
  assert_eq "$CALL_RC" "0" "ceo swarm help must exit 0"
  assert_contains "$CALL_OUT" "Usage: ceo swarm" "must print the swarm overview"
}

test_cli_help_needs_no_vault_for_any_command() {
  # ceo_require_vault runs ahead of preflight/test/chat/cron/schedule/playbook/
  # swarm. On a host that has never run `ceo setup`, help must still answer.
  _stub_outbound
  local sandbox cmd rc out
  sandbox=$(mktemp -d)
  for cmd in "test --help" "preflight --help" "chat --help" "cron --help" \
             "schedule --help" "playbook sync --help" "swarm doctor --help" \
             "playbook help" "swarm help"; do
    # shellcheck disable=SC2086
    out=$(env -i HOME="$sandbox" PATH="$STUB_BIN:$PATH" bash "$CEO_CLI" $cmd 2>&1); rc=$?
    assert_eq "$rc" "0" "ceo $cmd must exit 0 with no vault configured"
    assert_not_contains "$out" "CEO_VAULT unresolved" "ceo $cmd must not hit the vault gate"
  done
  rm -rf "$sandbox"
}

run_tests
