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

# --- ceo swarm owners-health: alert when a single-playbook owner host is stale -
#
# A scope:single playbook runs ONLY on its owner host (swarm.json owners{}).
# There is no failover, so an owner going offline silently stops that playbook
# everywhere. owners-health reads the SYNCED per-host heartbeat
# (CEO/heartbeats/<host>.json, written by the daemon with {host, ts:ISO8601})
# and escalates to the inbox ON TRANSITION fresh->stale only — transition-gated
# via a host-local state file under ~/.ceo (no append-on-every-fire).
#
# Tests inject "now" via CEO_SWARM_NOW_EPOCH so staleness is deterministic
# without stubbing date(1). The stale threshold is hours; heartbeats are written
# in ISO8601 with whatever offset the producing host used.

_owners_health() {
  env HOME="$TEST_HOME" CEO_VAULT="$TEST_VAULT" CEO_HOSTNAME="checker" \
    CEO_SWARM_NOW_EPOCH="${OH_NOW:-}" PATH="$PATH" \
    bash "$CEO_CLI" swarm owners-health "$@"
}

# Seed swarm.json with a single-scope owner map.
_seed_owners() {
  mkdir -p "$TEST_VAULT/CEO"
  printf '%s\n' "$1" > "$TEST_VAULT/CEO/swarm.json"
}

# Write a synced heartbeat for <host> with an ISO8601 ts <secs> before/after
# a fixed reference epoch. Positive secs = older (in the past).
_write_heartbeat_iso() {
  local host="$1" iso="$2"
  mkdir -p "$TEST_VAULT/CEO/heartbeats"
  printf '{ "host": "%s", "ts": "%s" }\n' "$host" "$iso" > "$TEST_VAULT/CEO/heartbeats/$host.json"
}

# A fixed reference "now": 2026-06-13T12:00:00Z == epoch 1781697600.
OH_REF_EPOCH=1781697600

_iso_at_offset() {
  # $1 = seconds to subtract from OH_REF_EPOCH, rendered as UTC ISO8601.
  local secs="$1" epoch=$((OH_REF_EPOCH - $1))
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

_inbox_count() {
  local marker="$1" file="$TEST_VAULT/CEO/inbox/checker.md"
  [ -f "$file" ] || { echo 0; return; }
  grep -c -F "$marker" "$file"
}

test_owners_health_fresh_owner_healthy_no_inbox() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 60)"   # 1 minute old → fresh
  local rc=0 out
  out=$(OH_NOW="$OH_REF_EPOCH" _owners_health 2>&1) || rc=$?
  assert_eq "$rc" "0" "fresh owner must exit 0"
  assert_contains "$out" "ml-1" "must report the owner host"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "0" "fresh owner must NOT write an inbox line"
}

test_owners_health_stale_owner_transition_alerts() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1", "pb2": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 36000)"  # 10h old → stale
  local rc=0 out
  out=$(OH_NOW="$OH_REF_EPOCH" _owners_health 2>&1) || rc=$?
  assert_eq "$rc" "1" "stale owner must exit non-zero (issues found)"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "fresh->stale must append exactly one inbox line"
  local line; line=$(grep -F 'owner-staleness:ml-1' "$TEST_VAULT/CEO/inbox/checker.md")
  assert_contains "$line" "ml-1" "alert names the stale host"
  assert_contains "$line" "pb1" "alert names an owned playbook"
  assert_contains "$line" "pb2" "alert names the second owned playbook"
  assert_eq "$(jq -r '.["ml-1"]' "$TEST_HOME/.ceo/owner-staleness-state.json")" "stale" \
    "state file records the host as stale"
}

test_owners_health_no_realert_while_still_stale() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 36000)"
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || true
  local before; before=$(cat "$TEST_HOME/.ceo/owner-staleness-state.json")
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || true
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "second stale run must NOT re-append"
  assert_eq "$(cat "$TEST_HOME/.ceo/owner-staleness-state.json")" "$before" \
    "state unchanged on a no-transition stale run"
}

test_owners_health_recovery_clears_state() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 36000)"   # stale first
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || true
  assert_eq "$(jq -r '.["ml-1"] // "absent"' "$TEST_HOME/.ceo/owner-staleness-state.json")" "stale" \
    "precondition: host flagged stale"
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 60)"      # recovered
  local rc=0
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "recovered owner must exit 0"
  assert_eq "$(jq -r '.["ml-1"] // "absent"' "$TEST_HOME/.ceo/owner-staleness-state.json")" "absent" \
    "recovery clears the host from state"
}

test_owners_health_missing_heartbeat_is_stale() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  # No heartbeat file written at all → owner has never beat / long gone.
  local rc=0
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "missing heartbeat must be treated as stale (non-zero)"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "missing heartbeat alerts on transition"
}

test_owners_health_future_ts_within_skew_is_fresh() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset -120)"  # 2 minutes in the FUTURE
  local rc=0
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "a slightly-future ts within clock-skew tolerance is fresh, not stale"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "0" "future-within-tolerance must NOT alert"
}

test_owners_health_far_future_ts_beyond_skew_is_stale() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset -7200)"  # 2 hours in the FUTURE
  local rc=0
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "a wildly-future ts beyond skew tolerance is untrustworthy → stale"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "beyond-skew future alerts on transition"
}

# A recent heartbeat in the REAL daemon (B4) shape — JS new Date().toISOString()
# always emits fractional millis + "Z" (e.g. 2026-06-14T12:34:56.789Z). On a
# BSD/macOS checker host the parser must accept it; before the parser fix the
# fractional ".789" failed `date -j -f %S%z`, routing a healthy owner to the
# stale path → false outage alert.
test_owners_health_fractional_second_heartbeat_is_fresh() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  local epoch=$((OH_REF_EPOCH - 60))   # 1 minute old → fresh
  local base
  base=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%S)
  _write_heartbeat_iso "ml-1" "${base}.789Z"   # real B4 fractional-millis shape
  local rc=0 out
  out=$(OH_NOW="$OH_REF_EPOCH" _owners_health 2>&1) || rc=$?
  assert_eq "$rc" "0" "a recent fractional-second (B4) heartbeat must parse → fresh, exit 0"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "0" \
    "recent fractional-second heartbeat must NOT alert (no parse-failure false outage)"
}

# Genuinely malformed ts must STILL route to stale — the parser fix must not
# broaden into accepting garbage as a valid epoch.
test_owners_health_malformed_ts_still_stale() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "not-a-date"
  local rc=0
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "an unparseable heartbeat ts must be treated as stale (non-zero)"
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "malformed ts alerts on transition"
}

# Defense-in-depth: the synced inbox marker dedupes even when the host-local
# state file is wiped (fresh checker host / cleared ~/.ceo). Without the marker
# grep, the lost transition memory re-appends a duplicate of a still-present
# synced alert line.
test_owners_health_marker_dedupe_survives_state_wipe() {
  _seed_owners '{ "schema_version": 1, "hosts": ["ml-1"], "owners": { "pb1": "ml-1" } }'
  _write_heartbeat_iso "ml-1" "$(_iso_at_offset 36000)"   # 10h old → stale
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || true
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" "first transition writes one line"
  rm -f "$TEST_HOME/.ceo/owner-staleness-state.json"      # simulate wiped host-local state
  OH_NOW="$OH_REF_EPOCH" _owners_health >/dev/null 2>&1 || true
  assert_eq "$(_inbox_count 'owner-staleness:ml-1')" "1" \
    "marker grep prevents a duplicate after the state file is wiped"
}

run_tests
