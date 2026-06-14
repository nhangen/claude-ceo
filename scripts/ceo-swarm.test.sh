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

run_tests
