#!/bin/bash
# Self-contained test harness for ceo-config.sh.
# Mirrors the count-blessings.test.sh shape — portable across BSD and GNU userlands.

set -uo pipefail  # no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/ceo-config.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_HOME"
  unset TEST_HOME
}

test_load_config_returns_nonzero_when_unresolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "ceo_load_config must return 1 when no source resolves CEO_VAULT"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_load_config_honors_env_bypass() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" CEO_VAULT="$TEST_HOME/explicit" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
    [ \"\$CEO_VAULT\" = \"$TEST_HOME/explicit\" ]
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "explicit CEO_VAULT in env must short-circuit discovery"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_load_config_finds_legacy_candidate() {
  local rc=0 vault_path
  mkdir -p "$TEST_HOME/Documents/Obsidian/CEO"
  vault_path=$(env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_load_config
    echo \"\$CEO_VAULT\"
  " 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "ceo_load_config must succeed when a candidate vault exists"
  assert_eq "$vault_path" "$TEST_HOME/Documents/Obsidian" "must export the discovered vault path"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_require_vault_exits_when_unresolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "ceo_require_vault must exit 1 when no source resolves CEO_VAULT"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_require_vault_returns_zero_when_resolved() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" CEO_VAULT="$TEST_HOME/explicit" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo_require_vault must return 0 when CEO_VAULT resolves"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_report_fails_loud_on_unresolved_vault() {
  local rc=0 out
  out=$(env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash "$SCRIPT_DIR/ceo-report.sh" intake test-trigger "content" 2>&1) || rc=$?
  assert_eq "$rc" "1" "ceo-report.sh must exit 1 when no vault resolves"
  case "$out" in
    *FATAL*) ;;
    *) printf '  FAIL [%s] stderr missing FATAL\n    got: %q\n' "$CURRENT_TEST" "$out"; FAILS=$((FAILS + 1)) ;;
  esac
  if [ -d "$TEST_HOME/empty/Documents/Obsidian/CEO" ]; then
    printf '  FAIL [%s] silent provision under default path\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_callers_fail_loud_on_unresolved_vault() {
  local rc=0 out _outer_test="$CURRENT_TEST"
  for script in "ceo-log.sh" "ceo-cleanup.sh" "ceo-scan.sh" "ceo-gather.sh" "count-blessings.sh"; do
    rc=0
    out=$(env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash "$SCRIPT_DIR/$script" 2>&1) || rc=$?
    assert_eq "$rc" "1" "$script must exit 1 when no vault resolves"
    case "$out" in
      *FATAL*) ;;
      *) printf '  FAIL [%s] stderr missing FATAL\n    got: %q\n' "$CURRENT_TEST" "$out"; FAILS=$((FAILS + 1)) ;;
    esac
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_ceo_help_works_on_fresh_host() {
  local rc=0
  env -i HOME="$TEST_HOME/empty" PATH="$PATH" bash "$SCRIPT_DIR/ceo" help >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "ceo help must exit 0 on a host with no CEO_VAULT"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_registry_validate_accepts_integer_current_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":3,"playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "integer schema_version at current version must validate"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_registry_validate_rejects_non_integer_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":1.5,"playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "float schema_version must reject instead of falling through"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_registry_validate_rejects_string_schema() {
  local registry="$TEST_HOME/registry.json"
  printf '{"schema_version":"2","playbooks":[]}\n' > "$registry"

  local rc=0
  env -i PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_registry_validate '$registry'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "string schema_version must reject instead of coercing"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# ceo_inbox_has_unchecked — preflight helper that scans both the legacy
# CEO/inbox.md (user-curated) and per-host CEO/inbox/<host>.md shadow files.
# Used by morning-brief and inbox cron preflights.

_inbox_check() {
  local ceo_dir="$1"
  bash -c "
    set -uo pipefail
    source '$LIB'
    CEO_DIR='$ceo_dir' ceo_inbox_has_unchecked
  " >/dev/null 2>&1
}

test_inbox_has_unchecked_returns_nonzero_when_no_files_exist() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "1" "no inbox files anywhere → nothing to do"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inbox_has_unchecked_finds_legacy_inbox_md() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO"
  printf -- '- [ ] something\n' > "$TEST_HOME/CEO/inbox.md"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "0" "unchecked item in legacy inbox.md must trigger preflight"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inbox_has_unchecked_skips_legacy_when_all_checked() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO"
  printf -- '- [x] done\n' > "$TEST_HOME/CEO/inbox.md"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "1" "all-checked legacy inbox.md must not trigger preflight"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inbox_has_unchecked_finds_per_host_shadow_file() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO/inbox"
  printf -- '- [ ] from-mac\n' > "$TEST_HOME/CEO/inbox/mac-mini.md"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "0" "unchecked item in per-host shadow must trigger preflight"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inbox_has_unchecked_skips_per_host_when_all_checked() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO/inbox"
  printf -- '- [x] done-on-mac\n' > "$TEST_HOME/CEO/inbox/mac-mini.md"
  printf -- '- [x] done-on-wsl\n' > "$TEST_HOME/CEO/inbox/wsl-host.md"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "1" "all-checked per-host shadow files must not trigger preflight"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_inbox_has_unchecked_with_legacy_clean_and_shadow_dirty() {
  local rc=0
  mkdir -p "$TEST_HOME/CEO/inbox"
  printf -- '- [x] legacy-done\n' > "$TEST_HOME/CEO/inbox.md"
  printf -- '- [ ] shadow-pending\n' > "$TEST_HOME/CEO/inbox/host-b.md"
  _inbox_check "$TEST_HOME/CEO" || rc=$?
  assert_eq "$rc" "0" "must find unchecked items even when legacy is clean"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_real_home_ignores_env_HOME() {
  # Regression guard: rtk and ccusage discover state via $HOME-rooted paths.
  # When the script is invoked from env -i / sandbox / sudo without -E, $HOME
  # may point somewhere that doesn't have the real user's DBs. The helper
  # must resolve from passwd, not from $HOME.
  local got expected
  expected=$(eval echo "~$(id -un)")
  if [ ! -d "$expected" ]; then
    if [ -n "${CI:-}" ]; then
      printf '  FAIL [%s] CI environment must have a real home for the test user\n' "$CURRENT_TEST"
      FAILS=$((FAILS + 1))
      return 0
    fi
    printf "  SKIP [%s] expected home %q is not a directory\n" "$CURRENT_TEST" "$expected"
    return 0
  fi
  got=$(env -i HOME=/tmp/this-is-not-the-real-home PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_real_home
  ")
  assert_eq "$got" "$expected" "ceo_resolve_real_home must use passwd, not \$HOME"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_real_home_falls_back_to_dscl_when_getent_returns_empty() {
  # Verifies the elif → if fix: when getent is on PATH but produces empty
  # output (Homebrew gnu-getent is host-resolution only, not passwd), the
  # resolver must fall through to dscl on Darwin. With the old elif shape
  # the dscl branch was unreachable once command -v getent succeeded.
  if [ "$(uname)" != "Darwin" ]; then
    printf "  SKIP [%s] non-Darwin\n" "$CURRENT_TEST"
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
    return 0
  fi
  local stub_dir="$TEST_HOME/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/getent" << 'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$stub_dir/getent"

  local got expected
  expected=$(eval echo "~$(id -un)")
  if [ ! -d "$expected" ]; then
    if [ -n "${CI:-}" ]; then
      printf '  FAIL [%s] CI environment must have a real home for the test user\n' "$CURRENT_TEST"
      FAILS=$((FAILS + 1))
      return 0
    fi
    printf "  SKIP [%s] expected home %q is not a directory\n" "$CURRENT_TEST" "$expected"
    return 0
  fi
  got=$(env -i HOME=/tmp/fake PATH="$stub_dir:/usr/bin:/bin" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_real_home
  ")
  assert_eq "$got" "$expected" "must fall through to dscl when getent on PATH returns empty"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pin_home_or_warn_emits_warn_on_resolver_failure() {
  # Force ceo_resolve_real_home to fail by stripping all binaries from PATH:
  # id, getent, and dscl are all unqualified inside the helper. Use absolute
  # /bin/bash because env(1) needs to locate bash itself before applying the
  # stripped PATH to the child process.
  local empty_dir="$TEST_HOME/empty"
  mkdir -p "$empty_dir"
  local stderr rc=0
  stderr=$(env -i HOME=/tmp/fake PATH="$empty_dir" /bin/bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_pin_home_or_warn
  " 2>&1 >/dev/null) || rc=$?
  assert_eq "$rc" "1" "ceo_pin_home_or_warn must return 1 when resolver fails"
  case "$stderr" in
    *"WARN: ceo_pin_home_or_warn"*"passwd resolution failed"*) ;;
    *) printf '  FAIL [%s] expected WARN line on stderr, got: %q\n' "$CURRENT_TEST" "$stderr"
       FAILS=$((FAILS + 1)) ;;
  esac
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_plugin_cli_returns_runtime_and_abs_path() {
  local cache="$TEST_HOME/.claude/plugins/cache/nhangen-tools/token-scope/1.3.1/src"
  mkdir -p "$cache"
  : > "$cache/cli.ts"

  local out rc=0
  out=$(env HOME="$TEST_HOME" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_plugin_cli 'nhangen-tools/token-scope' 'src/cli.ts'
  " 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "resolver should succeed when cache + entry exist"
  local line1 line2
  line1=$(printf '%s\n' "$out" | sed -n '1p')
  line2=$(printf '%s\n' "$out" | sed -n '2p')
  assert_eq "$line1" "bun" "default runtime should be bun"
  assert_eq "$line2" "$TEST_HOME/.claude/plugins/cache/nhangen-tools/token-scope/1.3.1/src/cli.ts" \
    "second line should be absolute entry path"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_plugin_cli_picks_latest_version() {
  local base="$TEST_HOME/.claude/plugins/cache/nhangen-tools/token-scope"
  for v in 1.2.0 1.3.0 1.3.1; do
    mkdir -p "$base/$v/src"
    : > "$base/$v/src/cli.ts"
  done

  local out rc=0
  out=$(env HOME="$TEST_HOME" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_plugin_cli 'nhangen-tools/token-scope' 'src/cli.ts'
  " 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "resolver should succeed with multiple versions present"
  local picked
  picked=$(printf '%s\n' "$out" | sed -n '2p')
  assert_eq "$picked" "$base/1.3.1/src/cli.ts" "resolver must pick the highest version via sort -V"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_plugin_cli_fails_when_plugin_absent() {
  local rc=0
  env HOME="$TEST_HOME" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_plugin_cli 'nhangen-tools/token-scope' 'src/cli.ts'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "resolver must return 1 when no cache directory exists"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_plugin_cli_fails_when_entry_missing() {
  local cache="$TEST_HOME/.claude/plugins/cache/nhangen-tools/token-scope/1.3.1"
  mkdir -p "$cache"

  local rc=0
  env HOME="$TEST_HOME" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_plugin_cli 'nhangen-tools/token-scope' 'src/cli.ts'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "resolver must return 1 when entry file is missing"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_resolve_plugin_cli_honors_runtime_override() {
  local cache="$TEST_HOME/.claude/plugins/cache/owner/tool/0.1.0/bin"
  mkdir -p "$cache"
  : > "$cache/run.js"

  local out rc=0
  out=$(env HOME="$TEST_HOME" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_resolve_plugin_cli 'owner/tool' 'bin/run.js' 'node'
  " 2>/dev/null) || rc=$?
  assert_eq "$rc" "0" "resolver should succeed with custom runtime"
  local runtime
  runtime=$(printf '%s\n' "$out" | sed -n '1p')
  assert_eq "$runtime" "node" "runtime arg must override the bun default"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# --- ceo_write_alert_frontmatter / ceo_read_alert_field ---

test_write_alert_frontmatter_emits_required_fields() {
  local out
  out=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=firing --since=2026-05-13T18:00:00-0400 \
      --host=ml1 --last-check=2026-05-13T19:00:00-0400
  ")
  assert_eq "$(printf '%s\n' "$out" | sed -n '1p')" "---" "first line must be frontmatter delimiter"
  case "$out" in
    *"status: firing"*) ;;
    *) printf '  FAIL [%s] missing status\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)) ;;
  esac
  case "$out" in
    *"since: 2026-05-13T18:00:00-0400"*) ;;
    *) printf '  FAIL [%s] missing since\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)) ;;
  esac
  case "$out" in
    *"last_check: 2026-05-13T19:00:00-0400"*) ;;
    *) printf '  FAIL [%s] missing last_check\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)) ;;
  esac
  case "$out" in
    *"host: ml1"*) ;;
    *) printf '  FAIL [%s] missing host\n' "$CURRENT_TEST"; FAILS=$((FAILS + 1)) ;;
  esac
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "---" "last line must be closing delimiter"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_alert_frontmatter_rejects_invalid_status() {
  local stderr rc=0
  stderr=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=frring --since=t --host=h --last-check=t
  " 2>&1 >/dev/null) || rc=$?
  assert_eq "$rc" "1" "invalid status must return 1"
  case "$stderr" in
    *"invalid"*"status"*) ;;
    *) printf '  FAIL [%s] expected error on stderr, got: %q\n' "$CURRENT_TEST" "$stderr"
       FAILS=$((FAILS + 1)) ;;
  esac
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_alert_frontmatter_accepts_clear_and_firing() {
  for s in clear firing; do
    local rc=0
    bash -c "
      set -uo pipefail
      source '$LIB'
      ceo_write_alert_frontmatter --status=$s --since=t --host=h --last-check=t
    " >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "0" "status=$s must be accepted"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_alert_frontmatter_rejects_unknown_status() {
  local rc=0
  bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=unknown --since=t --host=h --last-check=t
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "status=unknown is reserved as a consumer-side corruption sentinel and must not be writable"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_alert_frontmatter_requires_since_and_host() {
  local rc=0
  bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=clear --host=h --last-check=t
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "missing --since must return 1"
  rc=0
  bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=clear --since=t --last-check=t
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "missing --host must return 1"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_alert_frontmatter_emits_extra_fields() {
  local out
  out=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_write_alert_frontmatter --status=firing --since=t --host=h --last-check=t \
      --field dump_folder_gb=20 --field c_free_gb=999 --field measurement_failed=0
  ")
  for kv in "dump_folder_gb: 20" "c_free_gb: 999" "measurement_failed: 0"; do
    assert_contains "$out" "$kv" "missing $kv in output"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_alert_field_parses_timestamps_with_colons() {
  local f="$TEST_HOME/disk.md"
  cat > "$f" << 'EOF'
---
status: firing
since: 2026-01-01T00:00:00-0500
last_check: 2026-05-13T18:29:43-0400
host: testhost
---
EOF
  local got
  got=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_read_alert_field '$f' since
  ")
  assert_eq "$got" "2026-01-01T00:00:00-0500" "since must round-trip including colons (regression: -F': *' bug)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_alert_field_rc1_for_missing_field() {
  local f="$TEST_HOME/disk.md"
  cat > "$f" << 'EOF'
---
status: clear
---
EOF
  local got rc=0
  got=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_read_alert_field '$f' nonexistent
  ") || rc=$?
  assert_eq "$got" "" "missing field must print empty"
  assert_eq "$rc"  "1" "missing field must return rc=1 so callers distinguish corruption from absence"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_alert_field_rc2_for_missing_file() {
  local got rc=0
  got=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_read_alert_field '$TEST_HOME/no-such-file.md' status
  ") || rc=$?
  assert_eq "$got" "" "missing file must print empty"
  assert_eq "$rc"  "2" "missing file must return rc=2 (legitimate first-run, distinct from corruption)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_alert_field_anchored_match() {
  # `host` must not match `hostname`. Regression test for prefix-matching awk.
  local f="$TEST_HOME/disk.md"
  cat > "$f" << 'EOF'
---
hostname: ml1-long
status: firing
---
EOF
  local got rc=0
  got=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_read_alert_field '$f' host
  ") || rc=$?
  assert_eq "$rc"  "1" "field 'host' must not match line 'hostname:' (anchored match)"
  assert_eq "$got" "" "no spurious value when only a prefix-named field is present"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_read_alert_field_rc0_for_present_empty_value() {
  local f="$TEST_HOME/disk.md"
  printf -- '---\nstatus:\nhost: ml1\n---\n' > "$f"
  local got rc=0
  got=$(bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_read_alert_field '$f' status
  ") || rc=$?
  assert_eq "$rc"  "0" "field present with empty value is rc=0 (not rc=1) — value-empty != field-absent"
  assert_eq "$got" "" "empty value prints empty"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_write_and_read_roundtrip() {
  local f="$TEST_HOME/alert.md"
  bash -c "
    set -uo pipefail
    source '$LIB'
    { ceo_write_alert_frontmatter --status=firing \
        --since=2026-01-01T00:00:00-0500 \
        --last-check=2026-05-13T19:00:00-0400 \
        --host=ml1 \
        --field dump_folder_gb=20
      printf '\n# body\n'
    } > '$f'
  "
  local status since host dump
  status=$(bash -c "set -uo pipefail; source '$LIB'; ceo_read_alert_field '$f' status")
  since=$(bash -c "set -uo pipefail; source '$LIB'; ceo_read_alert_field '$f' since")
  host=$(bash -c "set -uo pipefail; source '$LIB'; ceo_read_alert_field '$f' host")
  dump=$(bash -c "set -uo pipefail; source '$LIB'; ceo_read_alert_field '$f' dump_folder_gb")
  assert_eq "$status" "firing" "round-trip status"
  assert_eq "$since" "2026-01-01T00:00:00-0500" "round-trip since (colons preserved)"
  assert_eq "$host" "ml1" "round-trip host"
  assert_eq "$dump" "20" "round-trip extra field"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_require_vault_rejects_empty_home() {
  # F10 fail-on-revert: removing the ${HOME:?...} guard at the top of
  # ceo_require_vault lets the fail-counter write fall through to /.claude/...
  # under empty HOME. set -u alone does not catch set-but-empty.
  local rc=0 out
  out=$(env -i HOME="" CEO_VAULT="" PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " 2>&1) || rc=$?
  
  # Manual assertion count for the custom rc check
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL [%s] ceo_require_vault must exit non-zero when HOME is empty (got 0)\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  
  assert_contains "$out" "HOME" "empty-HOME error must mention HOME"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_require_vault_increments_fail_counter_atomically_with_mkdir_fallback() {
  # F3 fail-on-revert: with CEO_TEST_FORCE_MKDIR_LOCK=1 the mkdir directory-lock
  # path runs even on hosts with flock. Three sequential failures must yield a
  # counter value of 3 — reverting the lock-gated write to an unguarded one
  # would still increment correctly here, but reverting the validator
  # ($fails fallthrough to "0" on non-numeric) would crash arithmetic on a
  # pre-corrupted file.
  local counter_file="$TEST_HOME/.claude/ceo-cron-config-fails"
  local fails_value
  for _i in 1 2 3; do
    env -i HOME="$TEST_HOME" CEO_VAULT="" CEO_TEST_FORCE_MKDIR_LOCK=1 PATH="$PATH" bash -c "
      set -uo pipefail
      source '$LIB'
      ceo_require_vault
    " >/dev/null 2>&1 || true
  done
  fails_value=$(cat "$counter_file" 2>/dev/null || echo missing)
  assert_eq "$fails_value" "3" "fail counter must reach 3 after three calls under mkdir-fallback"
  # Pre-corrupt the counter and verify the numeric validator resets to 0+1=1.
  echo "garbage" > "$counter_file"
  env -i HOME="$TEST_HOME" CEO_VAULT="" CEO_TEST_FORCE_MKDIR_LOCK=1 PATH="$PATH" bash -c "
    set -uo pipefail
    source '$LIB'
    ceo_require_vault
  " >/dev/null 2>&1 || true
  fails_value=$(cat "$counter_file" 2>/dev/null || echo missing)
  assert_eq "$fails_value" "1" "corrupted counter must reset to 1 on next failure"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_path_uses_home() {
  local got
  got=$(env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_path")
  assert_eq "$got" "$TEST_HOME/.ceo/pr-sources.json" "pr-sources path must be under \$HOME/.ceo"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_path_rejects_empty_home() {
  # Sibling helpers all guard `: "${HOME:?...}"`; verify pr_sources_path mirrors that.
  local rc=0
  env -i HOME="" PATH="$PATH" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_path" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && rc=1
  assert_eq "$rc" "1" "ceo_pr_sources_path must reject empty HOME (mirrors sibling :?: guard)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_github_accounts_reads_config() {
  local cfg="$TEST_HOME/pr-sources.json"
  printf '%s\n' '{"github":{"accounts":["nhangenam","nhangen"]}}' > "$cfg"
  local got
  got=$(bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$cfg'" | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "nhangenam,nhangen" "must list both configured accounts in order"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_github_accounts_empty_array_returns_empty_when_no_gh() {
  local cfg="$TEST_HOME/pr-sources.json"
  printf '%s\n' '{"github":{"accounts":[]}}' > "$cfg"
  local got
  # PATH stripped so gh discovery fallback can't fire.
  got=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_HOME" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$cfg'")
  assert_eq "$got" "" "empty accounts array with no gh available → empty stdout"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_exclude_orgs() {
  local cfg="$TEST_HOME/pr-sources.json"
  printf '%s\n' '{"github":{"exclude_orgs":["dependabot","copilot"]}}' > "$cfg"
  local got
  got=$(bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_exclude_orgs '$cfg'" | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "dependabot,copilot" "exclude_orgs must round-trip"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_dedupe_default_true() {
  local rc=0
  bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_dedupe '$TEST_HOME/missing.json'" || rc=$?
  assert_eq "$rc" "0" "missing config defaults dedupe=true (rc=0)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_dedupe_explicit_false() {
  local cfg="$TEST_HOME/pr-sources.json"
  printf '%s\n' '{"dedupe":false}' > "$cfg"
  local rc=0
  bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_dedupe '$cfg'" || rc=$?
  assert_eq "$rc" "1" "explicit dedupe:false returns rc=1"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_malformed_json_falls_through() {
  local cfg="$TEST_HOME/pr-sources.json"
  printf '%s\n' '{not valid json' > "$cfg"
  local got
  got=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_HOME" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$cfg'" 2>/dev/null)
  assert_eq "$got" "" "malformed JSON must not crash; falls through to empty when no gh"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

# Stub-gh tests: place a fake `gh` on PATH that emits a known `gh auth status`
# block, then assert the helper falls back correctly. Pin the fall-through
# contract per the auditor's MEDIUM finding.
_setup_stub_gh() {
  # Args: $1 = TEST_HOME, $2 = "auth-multi" | "auth-empty" | "auth-fail"
  local home="$1" mode="$2"
  local stub_dir="$home/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<EOSCRIPT
#!/bin/bash
case "\$1 \$2" in
  "auth status")
EOSCRIPT
  case "$mode" in
    auth-multi)
      cat >> "$stub_dir/gh" <<'EOSCRIPT'
    cat <<EOSTATUS
github.com
  ✓ Logged in to github.com account stubuser1 (keyring)
  ✓ Logged in to github.com account stubuser2 (keyring)
EOSTATUS
    exit 0 ;;
EOSCRIPT
      ;;
    auth-empty)
      cat >> "$stub_dir/gh" <<'EOSCRIPT'
    echo "Not logged in"
    exit 1 ;;
EOSCRIPT
      ;;
    auth-fail)
      cat >> "$stub_dir/gh" <<'EOSCRIPT'
    exit 1 ;;
EOSCRIPT
      ;;
  esac
  cat >> "$stub_dir/gh" <<'EOSCRIPT'
  *) echo "stub: unsupported subcommand: $*" >&2; exit 1 ;;
esac
EOSCRIPT
  chmod +x "$stub_dir/gh"
  echo "$stub_dir"
}

test_pr_sources_github_accounts_discovers_via_gh_when_config_missing() {
  local stub_dir got
  stub_dir=$(_setup_stub_gh "$TEST_HOME" auth-multi)
  got=$(env -i HOME="$TEST_HOME" PATH="$stub_dir:/usr/bin:/bin" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$TEST_HOME/missing.json'" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "stubuser1,stubuser2" "missing config must fall through to gh discovery"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_github_accounts_empty_array_triggers_discovery() {
  # Auditor finding: explicit empty array should fall through to gh, not silently
  # emit nothing. Test must FAIL if the early `[ -n "$accounts" ]; return 0` is
  # changed to unconditionally return 0 after the config branch.
  local cfg="$TEST_HOME/pr-sources.json" stub_dir got
  printf '%s\n' '{"github":{"accounts":[]}}' > "$cfg"
  stub_dir=$(_setup_stub_gh "$TEST_HOME" auth-multi)
  got=$(env -i HOME="$TEST_HOME" PATH="$stub_dir:/usr/bin:/bin" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$cfg'" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "stubuser1,stubuser2" "empty accounts array must fall through to gh discovery"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_github_accounts_malformed_triggers_discovery() {
  # Pins the auditor's "fall-through is the contract, not return-empty" finding.
  local cfg="$TEST_HOME/pr-sources.json" stub_dir got
  printf '%s\n' '{not valid json' > "$cfg"
  stub_dir=$(_setup_stub_gh "$TEST_HOME" auth-multi)
  got=$(env -i HOME="$TEST_HOME" PATH="$stub_dir:/usr/bin:/bin" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$cfg'" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "stubuser1,stubuser2" "malformed JSON must trigger gh discovery (not silently return empty)"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_github_accounts_gh_auth_failure_returns_empty() {
  local stub_dir got rc=0
  stub_dir=$(_setup_stub_gh "$TEST_HOME" auth-fail)
  got=$(env -i HOME="$TEST_HOME" PATH="$stub_dir:/usr/bin:/bin" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_accounts '$TEST_HOME/missing.json'" 2>/dev/null) || rc=$?
  assert_eq "$got" "" "gh auth status failure → empty stdout, no crash"
  assert_eq "$rc" "0" "gh auth failure must not propagate non-zero rc"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_gitlab_usernames_reads_config() {
  local cfg="$TEST_HOME/pr-sources.json" got
  printf '%s\n' '{"gitlab":{"usernames":["nhangen","alt-user"]}}' > "$cfg"
  got=$(env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_gitlab_usernames '$cfg'" | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "nhangen,alt-user" "gitlab usernames must round-trip from config"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_exclude_orgs_rejects_garbage() {
  # Validator must drop entries that aren't valid GitHub-org-shape. A newline
  # or whitespace in an exclude_orgs entry would otherwise silently collapse
  # the entire exclude filter at the gather call site (jq -R . | jq -s .
  # produces [""] for a single bad entry → still gets `index($o)` evaluated
  # downstream and either crashes or misfires).
  local cfg="$TEST_HOME/pr-sources.json" got
  printf '%s\n' '{"github":{"exclude_orgs":["dependabot","valid-org","bad org with space","invalid!chars"]}}' > "$cfg"
  got=$(env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_github_exclude_orgs '$cfg'" | tr '\n' ',' | sed 's/,$//')
  assert_eq "$got" "dependabot,valid-org" "exclude_orgs validator must drop garbage entries"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_setup_skips_non_tty() {
  # HIGH finding F1: non-tty stdin must NOT silently opt user into accounts.
  # Without the [ -t 0 ] guard, the `case *)` branch fires on empty $ans and
  # the function writes every discovered account into the config.
  local stub_dir
  stub_dir=$(_setup_stub_gh "$TEST_HOME" auth-multi)
  # Pipe empty stdin to force non-tty.
  env -i HOME="$TEST_HOME" PATH="$stub_dir:/usr/bin:/bin" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_setup </dev/null" >/dev/null 2>&1
  # Either the file wasn't written, or it was written with empty accounts.
  local accounts
  if [ -f "$TEST_HOME/.ceo/pr-sources.json" ]; then
    accounts=$(jq -r '.github.accounts | length' "$TEST_HOME/.ceo/pr-sources.json" 2>/dev/null)
  else
    accounts=0
  fi
  assert_eq "${accounts:-0}" "0" "non-tty stdin must not silently select any accounts"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_pr_sources_setup_writes_valid_json_when_no_sources() {
  # Even with neither gh nor glab on PATH, the function should emit a
  # structurally valid (empty) config — not crash, not leave a partial write.
  env -i HOME="$TEST_HOME" PATH="$PATH" bash -c "set -uo pipefail; source '$LIB'; ceo_pr_sources_setup </dev/null" >/dev/null 2>&1
  local rc=0
  if [ -f "$TEST_HOME/.ceo/pr-sources.json" ]; then
    jq empty "$TEST_HOME/.ceo/pr-sources.json" 2>/dev/null || rc=$?
  fi
  assert_eq "$rc" "0" "setup must either skip cleanly or write valid JSON"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_artifact_expand_substitutes_today_and_host() {
  local today out
  today=$(date +%Y-%m-%d)
  out=$(bash -c "source '$LIB'; ceo_artifact_expand 'CEO/reports/token/{TODAY}-{HOST}.md' 'testhost'")
  assert_eq "$out" "CEO/reports/token/${today}-testhost.md" "ceo_artifact_expand must substitute {TODAY} and {HOST}"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_artifact_expand_uses_env_host_default() {
  local today out
  today=$(date +%Y-%m-%d)
  out=$(CEO_HOSTNAME=envhost bash -c "source '$LIB'; ceo_artifact_expand 'CEO/reports/x/{TODAY}-{HOST}.md'")
  assert_eq "$out" "CEO/reports/x/${today}-envhost.md" "ceo_artifact_expand must fall back to \$CEO_HOSTNAME"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_artifact_expand_rejects_unknown_token() {
  local rc=0 out
  out=$(bash -c "source '$LIB'; ceo_artifact_expand 'CEO/reports/{BOGUS}/{TODAY}.md' 'testhost'") || rc=$?
  assert_eq "$rc" "1" "ceo_artifact_expand must reject unknown tokens per enum-config-typo-fallback"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_artifact_expand_rejects_empty_template() {
  local rc=0
  bash -c "source '$LIB'; ceo_artifact_expand ''" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "ceo_artifact_expand must return 1 on empty template"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_valid_accepts_canonical_values() {
  for s in active draft disabled; do
    local rc=0
    bash -c "source '$LIB'; ceo_status_valid '$s'" || rc=$?
    assert_eq "$rc" "0" "ceo_status_valid must accept canonical status: $s"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_valid_rejects_typos_and_case_variants() {
  for s in scrpt Active ACTIVE 'active ' ' active' disable enabled drft; do
    local rc=0
    bash -c "source '$LIB'; ceo_status_valid '$s'" || rc=$?
    assert_eq "$rc" "1" "ceo_status_valid must reject non-canonical status: '$s'"
  done
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_status_valid_rejects_empty() {
  local rc=0
  bash -c "source '$LIB'; ceo_status_valid ''" || rc=$?
  assert_eq "$rc" "1" "ceo_status_valid must reject empty string"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

run_tests
