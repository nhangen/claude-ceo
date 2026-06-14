#!/bin/bash
# Self-contained tests for swarm.json bootstrap + host self-registration
# (task C1). Drives the callable _swarm_bootstrap / _swarm_register_host
# functions directly against a temp CEO_VAULT so the full `ceo setup` pass
# (and its many other side effects) is never invoked.
#
# Invariant under test: never silently let two machines share a host id.
# An explicit CEO_HOSTNAME is trusted and registers idempotently; an unset
# id whose `hostname -s` value already appears in hosts[] is ambiguous and
# must refuse.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/ceo-config.sh"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  TEST_VAULT=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_HOME" "$TEST_VAULT"
  unset TEST_HOME TEST_VAULT
}

# Run a snippet with the ceo library loaded (CEO_LIB_ONLY=1 skips dispatch),
# CEO_VAULT bound to the temp vault, HOME isolated, and an optional PATH
# prefix carrying stub binaries. $1 = explicit CEO_HOSTNAME (or "" to unset),
# $2 = extra PATH prefix dir (or ""), $3 = bash snippet.
_run_swarm() {
  local host="$1" path_prefix="$2" snippet="$3"
  local path_env="$PATH"
  [ -n "$path_prefix" ] && path_env="$path_prefix:$PATH"
  if [ -n "$host" ]; then
    env -i HOME="$TEST_HOME" PATH="$path_env" CEO_VAULT="$TEST_VAULT" \
      CEO_HOSTNAME="$host" bash -c "
        set -uo pipefail
        source '$LIB'
        $snippet
      "
  else
    env -i HOME="$TEST_HOME" PATH="$path_env" CEO_VAULT="$TEST_VAULT" \
      bash -c "
        set -uo pipefail
        source '$LIB'
        $snippet
      "
  fi
}

# Stub `hostname` per stub-cli-argv-validation: validate argv shape, exit
# non-zero on anything but the `-s` invocation the production code uses.
_make_hostname_stub() {
  local dir="$1" value="$2"
  mkdir -p "$dir"
  cat > "$dir/hostname" << STUB
#!/bin/bash
case "\$*" in
  -s) echo "$value" ;;
  *) echo "hostname stub: unexpected argv: \$*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$dir/hostname"
}

test_bootstrap_creates_swarm_json_with_first_host() {
  _run_swarm "ml-1" "" '_swarm_bootstrap && _swarm_register_host'
  assert_file_exists "$TEST_VAULT/CEO/swarm.json" "bootstrap must create swarm.json"
  assert_eq "$(jq -r '.schema_version' "$TEST_VAULT/CEO/swarm.json")" "1" "schema_version"
  assert_eq "$(jq -c '.hosts' "$TEST_VAULT/CEO/swarm.json")" '["ml-1"]' "hosts seeded with this host"
  assert_eq "$(jq -c '.owners' "$TEST_VAULT/CEO/swarm.json")" '{}' "owners empty on fresh bootstrap"
}

test_register_is_idempotent_for_same_host() {
  _run_swarm "ml-1" "" '_swarm_bootstrap && _swarm_register_host'
  _run_swarm "ml-1" "" '_swarm_register_host'
  assert_eq "$(jq -c '.hosts' "$TEST_VAULT/CEO/swarm.json")" '["ml-1"]' "re-register same host must not duplicate"
}

test_second_host_appends() {
  _run_swarm "ml-1" "" '_swarm_bootstrap && _swarm_register_host'
  _run_swarm "mac" "" '_swarm_register_host'
  assert_eq "$(jq -c '.hosts' "$TEST_VAULT/CEO/swarm.json")" '["ml-1","mac"]' "second host appends"
}

test_existing_swarm_json_not_clobbered() {
  mkdir -p "$TEST_VAULT/CEO"
  cat > "$TEST_VAULT/CEO/swarm.json" << 'JSON'
{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "morning-brief": "ml-1" } }
JSON
  _run_swarm "mac" "" '_swarm_bootstrap && _swarm_register_host'
  assert_eq "$(jq -c '.hosts' "$TEST_VAULT/CEO/swarm.json")" '["ml-1","mac"]' "host appended, existing preserved"
  assert_eq "$(jq -r '.owners["morning-brief"]' "$TEST_VAULT/CEO/swarm.json")" "ml-1" "owners preserved"
}

test_unset_hostname_collision_refuses() {
  local stubdir="$TEST_HOME/stubs"
  _make_hostname_stub "$stubdir" "ml-1"
  # Seed swarm.json with the value `hostname -s` will return, then register
  # with CEO_HOSTNAME UNSET → ambiguous → must refuse.
  mkdir -p "$TEST_VAULT/CEO"
  cat > "$TEST_VAULT/CEO/swarm.json" << 'JSON'
{ "schema_version": 1, "hosts": ["ml-1"], "owners": {} }
JSON
  local rc=0 out
  out=$(_run_swarm "" "$stubdir" '_swarm_register_host' 2>&1) || rc=$?
  assert_eq "$rc" "1" "unset-id collision must refuse with non-zero"
  assert_contains "$out" "CEO_HOSTNAME" "refusal must instruct setting CEO_HOSTNAME"
  assert_eq "$(jq -c '.hosts' "$TEST_VAULT/CEO/swarm.json")" '["ml-1"]' "hosts unchanged after refusal"
}

# --- ceo swarm doctor: detect/merge Syncthing .sync-conflict copies ---------
#
# These drive the full `ceo` binary (dispatcher → cmd_swarm → cmd_swarm_doctor)
# with CEO_VAULT bound to the temp vault. The conflict copies use the real
# Syncthing naming `swarm.sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX.json` — the
# filename's embedded timestamp is the tiebreak key (lexicographically-greatest
# filename = most recent conflict wins) for owner keys absent from the live file.

_doctor() {
  env HOME="$TEST_HOME" CEO_VAULT="$TEST_VAULT" CEO_HOSTNAME="ml-1" \
    PATH="$PATH" bash "$CEO_CLI" swarm doctor "$@"
}

_seed_live_swarm() {
  mkdir -p "$TEST_VAULT/CEO"
  cat > "$TEST_VAULT/CEO/swarm.json" << 'JSON'
{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }
JSON
}

test_doctor_no_conflicts_exits_zero() {
  _seed_live_swarm
  local rc=0 out
  out=$(_doctor 2>&1) || rc=$?
  assert_eq "$rc" "0" "doctor with no conflicts must exit 0"
  assert_contains "$out" "no conflicts" "must report no conflicts"
}

test_doctor_detect_readonly_exits_nonzero_no_mutation() {
  _seed_live_swarm
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-120000-ABCDEFG.json" << 'JSON'
{ "schema_version": 1, "hosts": ["mac"], "owners": { "pb1": "mac", "pb2": "mac" } }
JSON
  local before; before=$(cat "$TEST_VAULT/CEO/swarm.json")
  local rc=0 out
  out=$(_doctor 2>&1) || rc=$?
  assert_eq "$rc" "1" "doctor (read-only) with a conflict must exit non-zero"
  assert_contains "$out" "ml-1" "proposed merge must show host union"
  assert_contains "$out" "mac" "proposed merge must show host union"
  assert_contains "$out" "pb1" "must call out the contested owner key"
  assert_eq "$(cat "$TEST_VAULT/CEO/swarm.json")" "$before" "read-only must NOT modify swarm.json"
  assert_file_exists "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-120000-ABCDEFG.json" \
    "read-only must NOT delete the conflict copy"
}

test_doctor_fix_merges_host_union_and_removes_conflict() {
  _seed_live_swarm
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-120000-ABCDEFG.json" << 'JSON'
{ "schema_version": 1, "hosts": ["mac"], "owners": { "pb1": "mac", "pb2": "mac" } }
JSON
  local rc=0
  _doctor --fix >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "--fix must exit 0 on success"
  assert_eq "$(jq -c '.hosts | sort' "$TEST_VAULT/CEO/swarm.json")" '["mac","ml-1"]' \
    "--fix must produce the host union"
  assert_eq "$(jq -r '.owners.pb1' "$TEST_VAULT/CEO/swarm.json")" "ml-1" \
    "live wins for a key present in both"
  assert_eq "$(jq -r '.owners.pb2' "$TEST_VAULT/CEO/swarm.json")" "mac" \
    "conflict-only key is brought in"
  assert_eq "$(ls "$TEST_VAULT/CEO/"swarm.sync-conflict-*.json 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "--fix must remove conflict copies after a successful write"
}

test_doctor_owner_tiebreak_greatest_filename_wins() {
  _seed_live_swarm
  # pb3 is absent from live; two conflicts disagree. The lexicographically
  # greatest FILENAME (later timestamp) must win → 130000 over 120000.
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-120000-AAAAAAA.json" << 'JSON'
{ "schema_version": 1, "hosts": ["mac"], "owners": { "pb3": "mac" } }
JSON
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-130000-BBBBBBB.json" << 'JSON'
{ "schema_version": 1, "hosts": ["box"], "owners": { "pb3": "box" } }
JSON
  local rc=0
  _doctor --fix >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "--fix must exit 0"
  assert_eq "$(jq -r '.owners.pb3' "$TEST_VAULT/CEO/swarm.json")" "box" \
    "live-absent contested key: greatest conflict filename wins"
  assert_eq "$(jq -r '.owners.pb1' "$TEST_VAULT/CEO/swarm.json")" "ml-1" \
    "live still wins for keys it owns"
}

test_doctor_tolerates_malformed_conflict_copy() {
  _seed_live_swarm
  printf '%s\n' '{bad json' > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-140000-CCCCCCC.json"
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-120000-DDDDDDD.json" << 'JSON'
{ "schema_version": 1, "hosts": ["mac"], "owners": { "pb2": "mac" } }
JSON
  local rc=0 out
  out=$(_doctor --fix 2>&1) || rc=$?
  assert_eq "$rc" "0" "doctor must not crash on a malformed conflict copy"
  assert_contains "$out" "swarm.sync-conflict-20260613-140000-CCCCCCC.json" \
    "must name the skipped malformed file in a diagnostic"
  assert_eq "$(jq -r '.owners.pb2' "$TEST_VAULT/CEO/swarm.json")" "mac" \
    "valid conflict still processed despite a malformed sibling"
  assert_eq "$(jq -c '.hosts | sort' "$TEST_VAULT/CEO/swarm.json")" '["mac","ml-1"]' \
    "malformed file contributes no hosts and does not win"
}

test_doctor_drops_non_string_owner_value() {
  _seed_live_swarm
  cat > "$TEST_VAULT/CEO/swarm.sync-conflict-20260613-150000-EEEEEEE.json" << 'JSON'
{ "schema_version": 1, "hosts": ["mac"], "owners": { "pbNull": null, "pbValid": "mac" } }
JSON
  local rc=0
  _doctor --fix >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "--fix must exit 0"
  assert_eq "$(jq -r '.owners | has("pbNull")' "$TEST_VAULT/CEO/swarm.json")" "false" \
    "null owner value must be dropped, not written as the string \"null\""
  assert_eq "$(jq -r '.owners.pbValid' "$TEST_VAULT/CEO/swarm.json")" "mac" \
    "valid conflict-only owner key still merges alongside a dropped null"
}

run_tests
