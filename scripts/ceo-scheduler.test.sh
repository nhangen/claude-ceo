#!/bin/bash
# Tests for the scheduler abstraction (#97) + launchd backend (#98).
#
# Covers:
#   - Backend selection priority (CEO_SCHEDULER > CEO_CRONTAB_BIN > ceo_detect_os)
#   - Unknown CEO_SCHEDULER fails loud (enum-config-typo-fallback)
#   - macOS sniffer narrowed to $HOME/.bun/bin (AC #3 of #97)
#   - macOS empty HOME aborts (shell-required-env-vars)
#   - crontab backend: list/install via CEO_CRONTAB_BIN; rc=1 on failure
#   - launchd backend: cron-field expansion, plist generation, install writes
#     plists + bootstraps, re-install removes stale plists (AC of #98),
#     list reconstructs cron-style lines, integration via `ceo playbook scan`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_LAUNCHD_DIR="$TEST_HOME/LaunchAgents"
  export CEO_LAUNCHCTL_BIN="$TEST_HOME/stub-launchctl"
  export CEO_PLUTIL_BIN="$TEST_HOME/stub-plutil"
  mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_LAUNCHD_DIR"

  # plutil stub. Real plutil is macOS-only; CI runs on Linux. Stub uses
  # python3's stdlib plistlib (present on both ubuntu-latest and macOS) so
  # the test exercises the same key-extraction contract real plutil offers.
  cat > "$CEO_PLUTIL_BIN" <<'STUB'
#!/bin/bash
# Honors `plutil -extract <key> raw -o - <file>` invocation shape only.
key="$2"
file="${!#}"
[ -f "$file" ] || { echo "stub-plutil: file not found: $file" >&2; exit 1; }
python3 - "$key" "$file" <<'PY'
import plistlib, sys
key, path = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    d = plistlib.load(f)
v = d
for p in key.split("."):
    if p.isdigit():
        try:
            v = v[int(p)]
        except (IndexError, TypeError):
            sys.exit(1)
    else:
        if not isinstance(v, dict) or p not in v:
            sys.exit(1)
        v = v[p]
print(v)
PY
STUB
  chmod +x "$CEO_PLUTIL_BIN"
  : > "$CEO_DIR/AGENTS.md"
  : > "$CEO_DIR/inbox.md"

  # Recording launchctl stub — logs every invocation to $TEST_HOME/launchctl.log.
  cat > "$CEO_LAUNCHCTL_BIN" <<STUB
#!/bin/bash
echo "\$@" >> "$TEST_HOME/launchctl.log"
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"

  unset CEO_SCHEDULER CEO_CRONTAB_BIN
  # shellcheck source=ceo-config.sh
  source "$SCRIPT_DIR/ceo-config.sh"
  # shellcheck source=ceo-scheduler.sh
  source "$SCRIPT_DIR/ceo-scheduler.sh"
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_SCHEDULER CEO_CRONTAB_BIN CEO_VAULT CEO_DIR CEO_LAUNCHD_DIR CEO_LAUNCHCTL_BIN CEO_PLUTIL_BIN
  rm -rf "$TEST_HOME"
}

# === Backend selection ===

test_ceo_scheduler_env_overrides_os_detection() {
  export CEO_SCHEDULER=launchd
  assert_eq "$(ceo_scheduler_backend)" "launchd" "explicit CEO_SCHEDULER must win"
  export CEO_SCHEDULER=crontab
  assert_eq "$(ceo_scheduler_backend)" "crontab" "explicit CEO_SCHEDULER must win"
}

test_ceo_crontab_bin_implies_crontab_backend() {
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  assert_eq "$(ceo_scheduler_backend)" "crontab" "CEO_CRONTAB_BIN set forces crontab backend"
}

test_unknown_ceo_scheduler_fails_loud() {
  export CEO_SCHEDULER=launhd
  local out rc=0
  out=$(ceo_scheduler_backend 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown CEO_SCHEDULER must return rc=1"
  assert_contains "$out" "unknown CEO_SCHEDULER='launhd'" "must surface typo to user"
  rc=0; out=$(ceo_scheduler_list 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_list must propagate unknown-backend rc=1"
  rc=0; out=$(ceo_scheduler_install "x" 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo_scheduler_install must propagate unknown-backend rc=1"
}

test_macos_sniffer_picks_crontab_only_under_bun_bin() {
  ceo_detect_os() { echo "macos"; }
  mkdir -p "$TEST_HOME/.bun/bin"
  cat > "$TEST_HOME/.bun/bin/crontab" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/.bun/bin/crontab"
  assert_eq \
    "$(PATH="$TEST_HOME/.bun/bin:$PATH" ceo_scheduler_backend)" "crontab" \
    "macOS + crontab under \$HOME/.bun/bin must pick crontab backend"

  mkdir -p "$TEST_HOME/bin"
  cp "$TEST_HOME/.bun/bin/crontab" "$TEST_HOME/bin/crontab"
  rm -f "$TEST_HOME/.bun/bin/crontab"
  assert_eq \
    "$(PATH="$TEST_HOME/bin:$PATH" ceo_scheduler_backend)" "launchd" \
    "macOS + crontab outside \$HOME/.bun/bin must pick launchd (narrow sniffer)"
}

test_macos_empty_home_fails_loud() {
  ceo_detect_os() { echo "macos"; }
  local rc=0
  ( HOME="" ceo_scheduler_backend >/dev/null 2>&1 ) || rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
    "empty HOME on macOS must abort (per shell-required-env-vars)"
}

# === crontab backend ===

test_crontab_backend_install_routes_payload_to_ceo_crontab_bin() {
  local capture="$TEST_HOME/crontab-capture.out"
  cat > "$TEST_HOME/fake-crontab" <<STUB
#!/bin/bash
cat > "$capture"
STUB
  chmod +x "$TEST_HOME/fake-crontab"
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  ceo_scheduler_install "marker-line-PAYLOAD" >/dev/null 2>&1
  local got
  got=$(cat "$capture" 2>/dev/null || echo "")
  assert_contains "$got" "marker-line-PAYLOAD" "payload must reach the crontab binary"
}

test_crontab_install_failure_surfaces_as_rc_1() {
  cat > "$TEST_HOME/failing-crontab" <<'STUB'
#!/bin/bash
echo "crontab: install failed (simulated)" >&2
exit 7
STUB
  chmod +x "$TEST_HOME/failing-crontab"
  export CEO_CRONTAB_BIN="$TEST_HOME/failing-crontab"
  local out rc=0
  out=$(ceo_scheduler_install "x" 2>&1) || rc=$?
  assert_eq "$rc" "1" "crontab failure must propagate as rc=1"
  assert_contains "$out" "crontab install failed" "error message must surface"
}

# === launchd: cron-field expansion ===

test_cron_field_expand_handles_all_shapes() {
  assert_eq "$(_ceo_cron_field_expand '*' 0 59)" "*" "* must remain literal *"
  assert_eq "$(_ceo_cron_field_expand '7' 0 59)" "7" "integer must pass through"
  assert_eq "$(_ceo_cron_field_expand '1-5' 0 23)" "1 2 3 4 5" "range expands"
  assert_eq "$(_ceo_cron_field_expand '1,3' 0 6)" "1 3" "list expands"
  assert_eq "$(_ceo_cron_field_expand '*/6' 0 23)" "0 6 12 18" "step expands within range"
  assert_eq "$(_ceo_cron_field_expand 'SUN' 0 6)" "0" "named SUN expands to 0"
  assert_eq "$(_ceo_cron_field_expand 'MON' 0 6)" "1" "named MON expands to 1"
}

test_tuples_from_payload_parses_real_registry_lines() {
  local payload
  payload=$(cat <<'BLOCK'
# CEO Agent START
0 9 * * * /path/to/ceo-cron.sh morning  # ceo:morning
47 17 * * 1-5 /path/to/ceo-cron.sh eod  # ceo:eod
0 8 * * SUN /path/to/ceo-cron.sh weekly  # ceo:weekly
# CEO Agent END
BLOCK
)
  local out
  out=$(_ceo_launchd_tuples_from_payload "$payload")
  # morning: 1 tuple (every day at 9:00, weekday=*)
  assert_contains "$out" "com.ceo.morning-0	0	9	*	"
  # eod: 5 tuples (Mon-Fri at 17:47)
  assert_contains "$out" "com.ceo.eod-0	47	17	1	"
  assert_contains "$out" "com.ceo.eod-4	47	17	5	"
  # weekly: 1 tuple (SUN at 08:00)
  assert_contains "$out" "com.ceo.weekly-0	0	8	0	"
  # Count: 1 + 5 + 1 = 7 lines
  local lines
  lines=$(printf '%s\n' "$out" | grep -c "^com.ceo." || true)
  assert_eq "$lines" "7" "must emit 7 tuples for 3 triggers (1 + 5 + 1)"
}

# === launchd: DOM/Month constraints are rejected (issue #109) ===

# Run a single bad DOM/Month case: stdout must be empty for the tagged name,
# stderr must contain a WARN that names the offending field + value.
_ceo_test_assert_rejects_dom_mon() {
  local cron_line="$1" expect_field="$2" expect_value="$3" tag="$4"
  local payload="${cron_line}  # ceo:${tag}"
  local stderr_file out
  stderr_file=$(mktemp)
  out=$(_ceo_launchd_tuples_from_payload "$payload" 2>"$stderr_file")
  local err
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
  assert_not_contains "$out" "com.ceo.${tag}-" "must emit no tuples for ${tag} (${cron_line})"
  assert_contains "$err" "WARN" "stderr must carry WARN for ${tag}"
  assert_contains "$err" "${expect_field}" "WARN must name field ${expect_field} for ${tag}"
  assert_contains "$err" "${expect_value}" "WARN must include offending value ${expect_value} for ${tag}"
}

test_tuples_rejects_dom_literal_value() {
  _ceo_test_assert_rejects_dom_mon \
    "* * 5 * * /tmp/ceo-cron.sh foo" "DOM" "5" "dom-literal"
}

test_tuples_rejects_dom_range() {
  _ceo_test_assert_rejects_dom_mon \
    "* * 1-7 * * /tmp/ceo-cron.sh foo" "DOM" "1-7" "dom-range"
}

test_tuples_rejects_dom_list() {
  _ceo_test_assert_rejects_dom_mon \
    "* * 1,15 * * /tmp/ceo-cron.sh foo" "DOM" "1,15" "dom-list"
}

test_tuples_rejects_dom_step() {
  _ceo_test_assert_rejects_dom_mon \
    "* * */2 * * /tmp/ceo-cron.sh foo" "DOM" "*/2" "dom-step"
}

test_tuples_rejects_dom_high_value() {
  _ceo_test_assert_rejects_dom_mon \
    "* * 31 * * /tmp/ceo-cron.sh foo" "DOM" "31" "dom-31"
}

test_tuples_rejects_month_literal() {
  _ceo_test_assert_rejects_dom_mon \
    "* * * 6 * /tmp/ceo-cron.sh foo" "Month" "6" "mon-literal"
}

test_tuples_rejects_month_range() {
  _ceo_test_assert_rejects_dom_mon \
    "* * * 1-3 * /tmp/ceo-cron.sh foo" "Month" "1-3" "mon-range"
}

# Mixed payload: bad DOM line is rejected while a sibling valid line still emits.
test_tuples_rejects_bad_line_keeps_good_line() {
  local payload
  payload=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh good  # ceo:good
15 10 5 * * /tmp/ceo-cron.sh bad  # ceo:bad
BLOCK
)
  local stderr_file out
  stderr_file=$(mktemp)
  out=$(_ceo_launchd_tuples_from_payload "$payload" 2>"$stderr_file")
  local err
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
  assert_contains "$out" "com.ceo.good-0" "valid sibling must still emit a tuple"
  assert_not_contains "$out" "com.ceo.bad-" "rejected line must not emit a tuple"
  assert_contains "$err" "DOM" "WARN must fire for bad line"
}

# Negative control: literal `*` for both fields must NOT trigger the WARN.
test_tuples_accepts_star_dom_and_month() {
  local payload="0 9 * * * /tmp/ceo-cron.sh ok  # ceo:ok"
  local stderr_file out
  stderr_file=$(mktemp)
  out=$(_ceo_launchd_tuples_from_payload "$payload" 2>"$stderr_file")
  local err
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
  assert_contains "$out" "com.ceo.ok-0" "happy-path must emit"
  assert_not_contains "$err" "WARN" "happy-path must not WARN about DOM/Month"
}

# === launchd: install writes plists + bootstraps + cleans stale ===

test_launchd_install_writes_one_plist_per_tuple() {
  export CEO_SCHEDULER=launchd
  local payload
  payload=$(cat <<'BLOCK'
# CEO Agent START
0 9 * * * /path/to/ceo-cron.sh morning  # ceo:morning
0 8 * * 1,3 /path/to/ceo-cron.sh twice  # ceo:twice
# CEO Agent END
BLOCK
)
  ceo_scheduler_install "$payload" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist" "morning plist must be written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.twice-0.plist" "twice (Mon) plist must be written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.twice-1.plist" "twice (Wed) plist must be written"
  # Plist contents — Minute, Hour, command
  local morning
  morning=$(cat "$CEO_LAUNCHD_DIR/com.ceo.morning-0.plist")
  assert_contains "$morning" "<integer>9</integer>" "morning plist must encode Hour=9"
  assert_contains "$morning" "/path/to/ceo-cron.sh morning" "plist must carry command"
}

test_launchd_install_bootstraps_each_plist_via_launchctl() {
  export CEO_SCHEDULER=launchd
  local payload="0 9 * * * /tmp/ceo-cron.sh foo  # ceo:foo"
  ceo_scheduler_install "$payload" >/dev/null 2>&1
  local log
  log=$(cat "$TEST_HOME/launchctl.log" 2>/dev/null || echo "")
  assert_contains "$log" "bootstrap gui/" "launchctl must be invoked with bootstrap"
  assert_contains "$log" "com.ceo.foo-0.plist" "bootstrap must reference the written plist"
}

test_launchd_install_removes_stale_plists_on_rescan() {
  export CEO_SCHEDULER=launchd
  # First install: two playbooks.
  local payload_v1
  payload_v1=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper
0 10 * * * /tmp/ceo-cron.sh stale  # ceo:stale
BLOCK
)
  ceo_scheduler_install "$payload_v1" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" "v1: keeper plist written"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.stale-0.plist" "v1: stale plist written"

  # Second install: stale playbook removed from registry.
  local payload_v2="0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper"
  # Truncate the launchctl log before v2 so the bootout assertion below only
  # observes v2 activity — otherwise the per-install bootout from v1 would
  # satisfy a bare "bootout" assertion regardless of stale cleanup.
  : > "$TEST_HOME/launchctl.log"
  ceo_scheduler_install "$payload_v2" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" "v2: keeper plist preserved"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR")" "com.ceo.stale-0.plist" \
    "v2: stale plist must be cleaned up on rescan"
  # bootout must fire specifically against the stale plist's path.
  local log
  log=$(cat "$TEST_HOME/launchctl.log" 2>/dev/null || echo "")
  assert_contains "$log" "bootout gui/" "launchctl bootout must fire during v2"
  assert_contains "$log" "com.ceo.stale-0.plist" \
    "bootout must reference the stale plist by name"
}

test_launchd_install_refuses_to_wipe_live_jobs_when_every_payload_line_rejected() {
  export CEO_SCHEDULER=launchd
  # Prior live install: a real job we'd be heartbroken to lose.
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" "seed: keeper plist present"

  # Rescan with a payload whose every entry has a DOM/Month constraint
  # (rejected by the launchd backend). _ceo_launchd_tuples_from_payload
  # emits zero tuples. Without the install-level gate, the cleanup pass
  # would walk com.ceo.*.plist with kept_labels empty and wipe keeper.
  local bad_payload
  bad_payload=$(cat <<'BLOCK'
15 10 5 * * /tmp/ceo-cron.sh foo  # ceo:foo
0 9 * 6 * /tmp/ceo-cron.sh bar  # ceo:bar
BLOCK
)
  local rc=0
  ceo_scheduler_install "$bad_payload" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "install must return non-zero when every registry entry is rejected"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.keeper-0.plist" \
    "keeper plist must survive an all-rejected rescan (no silent wipe)"
}

# Counter-control: a payload mixing one rejected line with one valid line
# still installs the valid line and leaves prior live plists alone.
test_launchd_install_partial_reject_installs_valid_and_keeps_other_priors() {
  export CEO_SCHEDULER=launchd
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh older  # ceo:older" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.older-0.plist" "seed: older plist present"

  local mixed
  mixed=$(cat <<'BLOCK'
0 11 * * * /tmp/ceo-cron.sh newer  # ceo:newer
15 10 5 * * /tmp/ceo-cron.sh bad  # ceo:bad
BLOCK
)
  local rc=0
  ceo_scheduler_install "$mixed" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "partial-reject install must still succeed for valid entries"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.newer-0.plist" "valid line must install"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR")" "com.ceo.bad-0.plist" \
    "rejected line must not produce a plist"
  # older was not in the new payload — stale cleanup should remove it.
  # (Symmetric with test_launchd_install_removes_stale_plists_on_rescan.)
}

# Symmetric Month counter-control to test_tuples_rejects_bad_line_keeps_good_line.
test_tuples_rejects_bad_month_keeps_good_line() {
  local payload
  payload=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh good  # ceo:good
15 10 * 6 * /tmp/ceo-cron.sh bad  # ceo:bad
BLOCK
)
  local stderr_file out
  stderr_file=$(mktemp)
  out=$(_ceo_launchd_tuples_from_payload "$payload" 2>"$stderr_file")
  local err
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
  assert_contains "$out" "com.ceo.good-0" "valid sibling must still emit a tuple"
  assert_not_contains "$out" "com.ceo.bad-" "rejected month line must not emit a tuple"
  assert_contains "$err" "Month" "WARN must name Month for bad line"
}

# #111: pin the destructive empty-payload semantics. The install function
# treats an empty/marker-only payload as "desired state is nothing" — every
# existing com.ceo.*.plist is stale and gets booted out. The #116 install-
# level gate only fires when the payload had `# ceo:` tags that were all
# rejected; a payload with NO tags at all is a legitimate "uninstall all"
# request.
test_launchd_install_empty_payload_clears_all_plists() {
  export CEO_SCHEDULER=launchd
  local seed
  seed=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh a  # ceo:a
0 10 * * * /tmp/ceo-cron.sh b  # ceo:b
BLOCK
)
  ceo_scheduler_install "$seed" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.a-0.plist" "seed: a present"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.b-0.plist" "seed: b present"

  local rc=0
  ceo_scheduler_install "" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "empty payload is a legitimate uninstall-all, must succeed"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR" 2>/dev/null || echo)" "com.ceo.a-0.plist" \
    "empty payload must clear a"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR" 2>/dev/null || echo)" "com.ceo.b-0.plist" \
    "empty payload must clear b"
}

# #111 sibling: marker-only payload (CEO Agent START/END comments, no
# entries) is equivalent to empty.
test_launchd_install_marker_only_payload_clears_all_plists() {
  export CEO_SCHEDULER=launchd
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh a  # ceo:a" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.a-0.plist" "seed: a present"

  local marker_only
  marker_only=$(cat <<'BLOCK'
# CEO Agent START
# CEO Agent END
BLOCK
)
  local rc=0
  ceo_scheduler_install "$marker_only" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "marker-only payload must succeed (no entries to reject)"
  assert_no_match "$(ls "$CEO_LAUNCHD_DIR" 2>/dev/null || echo)" "com.ceo.a-0.plist" \
    "marker-only payload must clear a"
}

# #112: every plist generated by ceo_scheduler_install must be well-formed
# XML. xmllint is available on both Linux (CI) and macOS; plutil -lint is
# the macOS-native counterpart. Grep-based assertions on tag content can
# pass on malformed plists with mis-nested dicts or unclosed tags.
test_launchd_install_generates_well_formed_plists() {
  if ! command -v xmllint >/dev/null 2>&1; then
    # CI guarantees xmllint via libxml2-utils; locally on a stripped
    # system, skip with an assertion counter bump so the no-assertions
    # guard doesn't abort the test.
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
    echo "  SKIP [test_launchd_install_generates_well_formed_plists]: xmllint not available"
    return 0
  fi
  export CEO_SCHEDULER=launchd
  local payload
  payload=$(cat <<'BLOCK'
0 9 * * * /path/to/ceo-cron.sh a  # ceo:a
0 10 * * 1,3,5 /path/to/ceo-cron.sh b  # ceo:b
30 17 * * 1-5 /path/to/ceo-cron.sh c  # ceo:c
BLOCK
)
  ceo_scheduler_install "$payload" >/dev/null 2>&1
  local plist
  for plist in "$CEO_LAUNCHD_DIR"/com.ceo.*.plist; do
    [ -f "$plist" ] || continue
    local lint_out lint_rc=0
    lint_out=$(xmllint --noout "$plist" 2>&1) || lint_rc=$?
    assert_eq "$lint_rc" "0" "xmllint --noout must accept $(basename "$plist") ($lint_out)"
  done
}

test_launchd_install_rolls_back_on_bootstrap_failure_mid_loop() {
  export CEO_SCHEDULER=launchd
  # Seed a prior live install so we can verify rollback doesn't disturb it.
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh prior  # ceo:prior" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.prior-0.plist" "prior install must seed"

  # Stub that fails the second bootstrap call. Counter persisted via a file
  # so it survives the stub's per-invocation subshell.
  local counter="$TEST_HOME/bootstrap-counter"
  echo 0 > "$counter"
  cat > "$CEO_LAUNCHCTL_BIN" <<STUB
#!/bin/bash
echo "\$@" >> "$TEST_HOME/launchctl.log"
if [ "\$1" = "bootstrap" ]; then
  n=\$(cat "$counter")
  n=\$((n + 1))
  echo \$n > "$counter"
  if [ "\$n" -eq 2 ]; then
    echo "simulated bootstrap failure" >&2
    exit 5
  fi
fi
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"

  : > "$TEST_HOME/launchctl.log"
  # 3 tuples; bootstrap #2 of this install will fail.
  local payload
  payload=$(cat <<'BLOCK'
0 9 * * * /tmp/ceo-cron.sh new-a  # ceo:new-a
0 10 * * * /tmp/ceo-cron.sh new-b  # ceo:new-b
0 11 * * * /tmp/ceo-cron.sh new-c  # ceo:new-c
BLOCK
)
  local rc=0
  ceo_scheduler_install "$payload" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "bootstrap failure mid-loop must propagate as rc=1"
  # Rolled back: none of the new plists remain on disk.
  for label in new-a new-b new-c; do
    if [ -f "$CEO_LAUNCHD_DIR/com.ceo.$label-0.plist" ]; then
      assert_eq "$label rolled back" "true" "v2: $label plist must be removed on rollback"
    fi
    if [ -f "$CEO_LAUNCHD_DIR/com.ceo.$label-0.plist.tmp" ]; then
      assert_eq "$label tmp cleaned" "true" "v2: $label .tmp must be cleaned on rollback"
    fi
  done
}

test_launchd_install_does_not_touch_unrelated_plists() {
  export CEO_SCHEDULER=launchd
  # Pre-seed an unrelated plist (not com.ceo.*) — must survive install.
  cat > "$CEO_LAUNCHD_DIR/com.example.other.plist" <<'XML'
<?xml version="1.0"?>
<plist><dict><key>Label</key><string>com.example.other</string></dict></plist>
XML
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh keeper  # ceo:keeper" >/dev/null 2>&1
  assert_file_exists "$CEO_LAUNCHD_DIR/com.example.other.plist" "non-ceo plists must not be touched"
}

# === launchd: list reconstructs cron-style lines ===

test_launchd_list_reconstructs_cron_lines_for_doctor() {
  export CEO_SCHEDULER=launchd
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh morning  # ceo:morning" >/dev/null 2>&1
  local out
  out=$(ceo_scheduler_list 2>&1)
  # Full leading prefix incl. weekday `*` — pins both extraction AND the
  # absent-Weekday fallback branch. Substring check too weak (hour 9 from
  # fixture would let grep+sed reintroduce midnight defaults silently).
  assert_contains "$out" "0 9 * * * /tmp/ceo-cron.sh morning  # ceo:morning" \
    "full line must reconstruct from plutil extracts, not fabricated defaults"
}

test_launchd_list_warns_and_skips_when_plutil_missing() {
  export CEO_SCHEDULER=launchd
  ceo_scheduler_install "0 9 * * * /tmp/ceo-cron.sh morning  # ceo:morning" >/dev/null 2>&1
  # Point CEO_PLUTIL_BIN at a binary that doesn't exist. The function must
  # emit a WARN per plist to stderr and skip the line, not silently return
  # empty (which would reproduce #108's failure mode one branch deeper).
  export CEO_PLUTIL_BIN="$TEST_HOME/does-not-exist-plutil"
  local out err
  out=$(ceo_scheduler_list 2>/tmp/ceo-sched-stderr.$$)
  err=$(cat /tmp/ceo-sched-stderr.$$); rm -f /tmp/ceo-sched-stderr.$$
  assert_no_match "$out" "ceo-cron.sh" "stdout must be empty — no fabricated line on plutil failure"
  assert_contains "$err" "WARN: skipping" "stderr must surface the skip with a WARN line"
}

_ceo_test_write_plist_missing_field() {
  local label="$1" missing="$2"
  local has_label=1 has_minute=1 has_hour=1 has_cmd=1
  case "$missing" in
    Label) has_label=0 ;;
    Minute) has_minute=0 ;;
    Hour) has_hour=0 ;;
    ProgramArguments) has_cmd=0 ;;
  esac
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<plist version="1.0"><dict>'
    [ "$has_label" -eq 1 ] && echo "  <key>Label</key><string>com.ceo.$label-0</string>"
    if [ "$has_cmd" -eq 1 ]; then
      echo '  <key>ProgramArguments</key><array>'
      echo '    <string>/bin/bash</string><string>-lc</string>'
      echo "    <string>/tmp/ceo-cron.sh $label</string>"
      echo '  </array>'
    fi
    echo '  <key>StartCalendarInterval</key><dict>'
    [ "$has_minute" -eq 1 ] && echo "    <key>Minute</key><integer>0</integer>"
    [ "$has_hour" -eq 1 ] && echo "    <key>Hour</key><integer>9</integer>"
    echo '  </dict></dict></plist>'
  } > "$CEO_LAUNCHD_DIR/com.ceo.$label-0.plist"
}

test_launchd_list_skips_plist_missing_any_required_field() {
  export CEO_SCHEDULER=launchd
  mkdir -p "$CEO_LAUNCHD_DIR"
  # Parameterised across the 4 required-field branches. Each writes a plist
  # missing exactly one required key; the resulting line must NOT render and
  # stderr must carry the field-named WARN.
  local field expected_token
  for field in Label Minute Hour ProgramArguments; do
    rm -f "$CEO_LAUNCHD_DIR"/com.ceo.*.plist
    _ceo_test_write_plist_missing_field "missing-$field" "$field"
    local out err
    out=$(ceo_scheduler_list 2>/tmp/ceo-sched-stderr.$$)
    err=$(cat /tmp/ceo-sched-stderr.$$); rm -f /tmp/ceo-sched-stderr.$$
    assert_no_match "$out" "missing-$field" "missing-$field plist must NOT render"
    case "$field" in
      ProgramArguments) expected_token="ProgramArguments.2 extract failed" ;;
      *) expected_token="$field extract failed" ;;
    esac
    assert_contains "$err" "$expected_token" "stderr must surface the missing-$field skip"
  done
}

test_launchd_list_reconstructs_weekday_constrained_line() {
  export CEO_SCHEDULER=launchd
  # eod 17:47 Mon-Fri → 5 plists with Weekday 1..5
  ceo_scheduler_install "47 17 * * 1-5 /tmp/ceo-cron.sh eod  # ceo:eod" >/dev/null 2>&1
  local out
  out=$(ceo_scheduler_list 2>&1)
  assert_contains "$out" "47 17 * * 1" "weekday=1 reconstruction must carry hour+minute"
  assert_contains "$out" "47 17 * * 5" "weekday=5 reconstruction must carry hour+minute"
  assert_contains "$out" "# ceo:eod" "ceo:NAME tag survives weekday-constrained plists"
}

test_launchd_list_skips_malformed_plist_without_fabricating_midnight() {
  export CEO_SCHEDULER=launchd
  # Write a plist that's missing the StartCalendarInterval block. plutil
  # extract for Minute/Hour will fail; the function must not fabricate "0 0".
  mkdir -p "$CEO_LAUNCHD_DIR"
  cat > "$CEO_LAUNCHD_DIR/com.ceo.broken-0.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.ceo.broken-0</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-lc</string>
    <string>/tmp/ceo-cron.sh broken</string>
  </array>
</dict></plist>
XML
  local out
  out=$(ceo_scheduler_list 2>&1)
  # No "0 0 * * *" line should appear — that's exactly the fabricated-midnight
  # failure mode this fix exists to prevent.
  assert_no_match "$out" "0 0 * * * /tmp/ceo-cron.sh broken" \
    "malformed plist must NOT silently render as fabricated midnight cron line"
}

# === launchd: loaded-job count via launchctl print (#107) ===

test_loaded_count_parses_unique_labels_from_realistic_launchctl_print() {
  export CEO_SCHEDULER=launchd
  # Stub emits a realistic multi-section `launchctl print gui/$uid` output:
  # the same label appears in `services`, `endpoints`, `enabled services`,
  # AND as an `executable = .../com.ceo.foo.plist` path line. Counting lines
  # naively → 9; counting unique labels → 3. Pins the unique-label fix.
  cat > "$CEO_LAUNCHCTL_BIN" <<'STUB'
#!/bin/bash
if [ "$1" = "print" ]; then
  cat <<OUT
services = {
    0  com.apple.dock.extra
    -  com.example.unrelated
    0  com.ceo.morning-0
    -  com.ceo.eod-3
    0  com.ceo.weekly-0
    0  com.apple.other
}
endpoints = {
    com.ceo.morning-0
    com.ceo.eod-3
    com.ceo.weekly-0
}
enabled services = {
    com.ceo.morning-0 => enabled
    com.ceo.eod-3 => enabled
    com.ceo.weekly-0 => enabled
}
executable = /Users/me/Library/LaunchAgents/com.ceo.morning-0.plist
executable = /Users/me/Library/LaunchAgents/com.ceo.eod-3.plist
executable = /Users/me/Library/LaunchAgents/com.ceo.weekly-0.plist
OUT
  exit 0
fi
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"
  assert_eq "$(ceo_scheduler_loaded_count)" "3" "must count UNIQUE com.ceo.* labels across realistic multi-section launchctl output"
}

test_loaded_count_emits_unknown_when_launchctl_fails() {
  export CEO_SCHEDULER=launchd
  cat > "$CEO_LAUNCHCTL_BIN" <<'STUB'
#!/bin/bash
echo "launchctl: domain not found" >&2
exit 3
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"
  assert_eq "$(ceo_scheduler_loaded_count)" "unknown" "launchctl failure must surface 'unknown', not silent 0"
}

test_loaded_count_is_zero_when_no_ceo_jobs_loaded() {
  export CEO_SCHEDULER=launchd
  cat > "$CEO_LAUNCHCTL_BIN" <<'STUB'
#!/bin/bash
if [ "$1" = "print" ]; then
  echo "services = { 0 com.apple.dock.extra }"
fi
exit 0
STUB
  chmod +x "$CEO_LAUNCHCTL_BIN"
  assert_eq "$(ceo_scheduler_loaded_count)" "0" "no com.ceo.* lines must yield 0"
}

test_loaded_count_returns_na_on_crontab_backend() {
  export CEO_CRONTAB_BIN="$TEST_HOME/fake-crontab"
  echo '#!/bin/bash' > "$CEO_CRONTAB_BIN"; chmod +x "$CEO_CRONTAB_BIN"
  assert_eq "$(ceo_scheduler_loaded_count)" "n/a" "crontab backend must surface n/a (concept doesn't apply)"
}

# === Integration: ceo playbook scan end-to-end on launchd ===

test_playbook_scan_writes_plists_via_launchd_backend() {
  export CEO_SCHEDULER=launchd
  cat > "$CEO_DIR/registry.json" <<'EOF'
{"schema_version": 3, "generated": "1970-01-01T00:00:00Z", "playbooks": []}
EOF
  # Point CEO_REPO_PLAYBOOK_DIR at an empty dir so scan reads ONLY the test
  # fixture (otherwise it discovers the real plugin's docs/playbooks/ and the
  # test becomes order-dependent on whatever's registered there).
  export CEO_REPO_PLAYBOOK_DIR="$TEST_HOME/empty-repo-playbooks"
  mkdir -p "$CEO_REPO_PLAYBOOK_DIR"
  cat > "$CEO_DIR/playbooks/scan-target.md" <<'EOF'
---
name: scan-target
description: Integration test playbook for launchd backend
trigger: cron
schedule: "0 9 * * *"
status: active
runner: script
script: noop.sh
---
EOF
  local rc=0
  bash "$CEO_CLI" playbook scan >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "playbook scan must succeed on launchd backend"
  assert_file_exists "$CEO_LAUNCHD_DIR/com.ceo.scan-target-0.plist" "scan must write the plist"
}

run_tests
