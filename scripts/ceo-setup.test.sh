#!/bin/bash
# Self-contained tests for `ceo setup` dispatch (#101 / #95) and setup-common.sh
# step-prefix invariants. Sibling to setup-scripts.test.sh, which covers
# setup-mac.sh dry-run output specifically — this file covers the dispatcher
# itself and the cross-installer common helpers.
#
# Locks the WSL stdout baseline (the AC of #95) at the function-output level
# and revert-gates cmd_setup's per-OS routing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_BIN="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/stubs" "$TEST_HOME/empty_bin"

  # Stub the per-OS installers as one-liners so dispatch tests don't actually
  # run a setup pass. Each one echoes its name and exits 0.
  for installer in setup-wsl.sh setup-mac.sh setup-linux.sh; do
    cat > "$TEST_HOME/stubs/$installer" << STUB
#!/bin/bash
echo "STUB:$installer \$*"
exit 0
STUB
    chmod +x "$TEST_HOME/stubs/$installer"
  done
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  rm -rf "$TEST_HOME"
}

# Run cmd_setup in a clean shell with ceo_detect_os shimmed to print a given
# OS, and SCRIPT_DIR pointed at the stub installers. Returns the dispatch
# output and rc.
_run_cmd_setup_with_os() {
  local os="$1"; shift
  bash -c "
    set -uo pipefail
    SCRIPT_DIR='$TEST_HOME/stubs'
    ceo_detect_os() { echo '$os'; }
    $(sed -n '/^cmd_setup()/,/^}$/p' "$CEO_BIN")
    cmd_setup $*
  " 2>&1
}

# === cmd_setup dispatch (4 branches) ===

test_cmd_setup_dispatches_to_setup_wsl_sh() {
  local out
  out=$(_run_cmd_setup_with_os wsl --dry-run)
  assert_contains "$out" "STUB:setup-wsl.sh" "wsl must dispatch to setup-wsl.sh"
  assert_contains "$out" "--dry-run" "args must be forwarded"
}

test_cmd_setup_dispatches_to_setup_mac_sh() {
  local out
  out=$(_run_cmd_setup_with_os macos --dry-run)
  assert_contains "$out" "STUB:setup-mac.sh" "macos must dispatch to setup-mac.sh"
  assert_contains "$out" "--dry-run" "args must be forwarded"
}

test_cmd_setup_dispatches_to_setup_linux_sh() {
  local out
  out=$(_run_cmd_setup_with_os linux)
  assert_contains "$out" "STUB:setup-linux.sh" "linux must dispatch to setup-linux.sh"
}

test_cmd_setup_unknown_os_exits_nonzero_with_diagnostic() {
  local out rc=0
  out=$(_run_cmd_setup_with_os unknown 2>&1) || rc=$?
  assert_eq "$rc" "1" "unknown OS must exit 1"
  assert_contains "$out" "unsupported" "diagnostic must say 'unsupported'"
  assert_contains "$out" "wsl, macos, linux" "diagnostic must name the supported set"
}

# === MISSING_CONFIG declaration contract (#101 ordering hotfix) ===

test_setup_common_refuses_to_source_without_missing_config_array() {
  local rc=0 out
  out=$(bash -c "
    set -uo pipefail
    SCRIPT_DIR='$SCRIPT_DIR'
    source '$SCRIPT_DIR/setup-common.sh'
  " 2>&1) || rc=$?
  assert_eq "$rc" "1" "sourcing without MISSING_CONFIG=() must exit 1"
  assert_contains "$out" "caller must declare MISSING_CONFIG" "diagnostic must name the missing array"
}

test_setup_common_sources_cleanly_when_missing_config_declared() {
  local rc=0
  bash -c "
    set -uo pipefail
    SCRIPT_DIR='$SCRIPT_DIR'
    MISSING_CONFIG=()
    source '$SCRIPT_DIR/setup-common.sh'
  " >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "0" "sourcing with MISSING_CONFIG declared must succeed"
}

# === TTY check at installer entrypoints (#102 item 1) ===

# Non-TTY invocation (curl-install | bash, CI, < /dev/null) must refuse to
# proceed rather than silently fall through interactive `read` prompts and
# persist a broken config. The check belongs at each installer's entry
# point per safety-invariant-scope (gate at the function, not at each
# read site).
_assert_installer_refuses_non_tty() {
  local installer="$1"
  local rc=0 out
  # </dev/null forces non-TTY stdin even when the test harness itself
  # runs under a TTY.
  out=$(bash "$SCRIPT_DIR/$installer" </dev/null 2>&1) || rc=$?
  if [ "$rc" = "0" ]; then
    printf '  FAIL [%s] %s under </dev/null must exit non-zero (got rc=0)\n' "$CURRENT_TEST" "$installer"
    FAILS=$((FAILS + 1))
  fi
  assert_contains "$out" "interactive terminal" \
    "$installer must surface the 'interactive terminal' diagnostic"
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_setup_mac_refuses_non_tty_invocation() {
  _assert_installer_refuses_non_tty setup-mac.sh
}

test_setup_linux_refuses_non_tty_invocation() {
  _assert_installer_refuses_non_tty setup-linux.sh
}

test_setup_wsl_refuses_non_tty_invocation() {
  _assert_installer_refuses_non_tty setup-wsl.sh
}

# === ceo_setup_gh_auth — distinguish authed vs not-authed vs error (#102 item 2) ===

# Helper to install a `gh` stub at $TEST_HOME/stubs/gh with given behavior.
_install_gh_stub() {
  local rc="$1" stderr="$2"
  cat > "$TEST_HOME/stubs/gh" <<STUB
#!/bin/bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
  printf '%s\n' "${stderr}" >&2
  exit ${rc}
fi
# Other gh invocations (e.g. \`gh auth login\` fall-through) are no-ops.
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/gh"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
}

test_gh_auth_helper_reports_authed_on_rc_zero() {
  _install_gh_stub 0 "Logged in to github.com account testuser"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out rc=0
  out=$(ceo_setup_gh_auth "[2/10]" 2>&1) || rc=$?
  assert_eq "$rc" "0" "authed path must return 0"
  assert_contains "$out" "[2/10] gh already authenticated" "must echo authed-line with prefix"
}

test_gh_auth_helper_invokes_auth_login_on_not_logged_message() {
  _install_gh_stub 1 "You are not logged into any GitHub hosts. To log in, run: gh auth login"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out rc=0
  out=$(ceo_setup_gh_auth "[2/10]" 2>&1) || rc=$?
  assert_eq "$rc" "0" "not-logged path must succeed (stub exits 0 on the login call)"
  assert_contains "$out" "[2/10] Authenticating gh CLI" "must transition to auth login"
}

test_is_yes_helper_accepts_y_yes_uppercase_mixedcase() {
  _source_common_with_stubs "$SCRIPT_DIR"
  local v
  for v in y Y yes YES Yes yEs; do
    if ! _ceo_is_yes "$v"; then
      printf '  FAIL [%s] _ceo_is_yes must accept %q as yes\n' "$CURRENT_TEST" "$v"
      FAILS=$((FAILS + 1))
    fi
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  done
}

test_is_yes_helper_rejects_n_no_empty_other() {
  _source_common_with_stubs "$SCRIPT_DIR"
  local v
  for v in n N no NO No "" yep ya whatever 1 0; do
    if _ceo_is_yes "$v"; then
      printf '  FAIL [%s] _ceo_is_yes must reject %q as no\n' "$CURRENT_TEST" "$v"
      FAILS=$((FAILS + 1))
    fi
    ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  done
}

# `ceo_setup_cron` interpretation: `Y` / `yes` / `YES` route to scan;
# anything else surfaces the "interpreted as no" diagnostic. The cron
# scan itself shells out to `bash $SCRIPT_DIR/ceo playbook scan` which
# would need a full environment to run; we point ceo at a stub that
# echoes a marker so the test verifies routing without invoking real
# scan logic.
_install_ceo_stub_for_cron_test() {
  cat > "$TEST_HOME/stubs/yq" << 'STUB'
#!/bin/bash
echo "yq stub 4.0.0"
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/yq"
  # Stub `ceo` next to the test sandbox; SCRIPT_DIR is reset to TEST_HOME
  # so the function picks up THIS ceo, not the real one.
  cat > "$TEST_HOME/ceo" << 'STUB'
#!/bin/bash
echo "STUB_CEO_RAN:$*"
STUB
  chmod +x "$TEST_HOME/ceo"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
  _source_common_with_stubs "$SCRIPT_DIR"
  # Override SCRIPT_DIR in the sourced function's view by re-pointing it
  # after the source. The function reads $SCRIPT_DIR at call time.
  SCRIPT_DIR="$TEST_HOME"
}

test_cron_setup_runs_scan_on_uppercase_Y() {
  _install_ceo_stub_for_cron_test
  local out
  out=$(echo "Y" | ceo_setup_cron 2>&1)
  assert_contains "$out" "STUB_CEO_RAN:playbook scan" "uppercase Y must run playbook scan"
  assert_not_contains "$out" "interpreted as no" "Y must NOT route to the skipped branch"
}

test_cron_setup_runs_scan_on_yes_word() {
  _install_ceo_stub_for_cron_test
  local out
  out=$(echo "yes" | ceo_setup_cron 2>&1)
  assert_contains "$out" "STUB_CEO_RAN:playbook scan" "literal 'yes' must run playbook scan"
}

test_cron_setup_skips_with_diagnostic_on_typo() {
  _install_ceo_stub_for_cron_test
  local out
  out=$(echo "ya" | ceo_setup_cron 2>&1)
  assert_not_contains "$out" "STUB_CEO_RAN" "typo must NOT run scan"
  assert_contains "$out" "interpreted as no" "typo must surface the interpretation in the skip line"
}

# === ceo_setup_vault — empty vault is a missing-config event (#102 item 4) ===

# Drive ceo_setup_vault with an empty stdin (simulating Enter pressed with
# no detected vault). The function must:
#   - NOT write ~/.ceo/config
#   - push "CEO_VAULT" onto MISSING_CONFIG
#   - return 0 (the missing-config sweep is the canonical exit-1 site;
#     vault is just one input)
test_setup_vault_pushes_to_missing_config_on_empty_input() {
  _source_common_with_stubs "$SCRIPT_DIR"
  # No CEO directory anywhere — auto-detect candidate list is empty,
  # function falls into the "no vault auto-detected" prompt.
  rm -rf "$TEST_HOME/Documents" "$TEST_HOME/Obsidian"
  : > "$TEST_HOME/.ceo-pretest-marker"  # ensure HOME points at TEST_HOME
  local out
  out=$(printf '\n' | ceo_setup_vault 2>&1)
  local cfg="$TEST_HOME/.ceo/config"
  if [ -f "$cfg" ] && grep -q 'CEO_VAULT=""' "$cfg"; then
    printf '  FAIL [%s] ~/.ceo/config must NOT be written with CEO_VAULT="" (got: %s)\n' \
      "$CURRENT_TEST" "$(cat "$cfg")"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  assert_contains "$out" "empty vault path" "must surface the empty-vault diagnostic"
  # MISSING_CONFIG was mutated inside the subshell — assert via a re-source
  # in-process so we can read the array.
  MISSING_CONFIG=()
  # Use heredoc (not a pipe) so ceo_setup_vault runs in the current shell
  # and MISSING_CONFIG mutations are visible here.
  ceo_setup_vault >/dev/null 2>&1 <<< ""
  local joined="${MISSING_CONFIG[*]:-}"
  assert_contains "$joined" "CEO_VAULT" \
    "MISSING_CONFIG must contain CEO_VAULT after empty-vault input"
}

# Counter-control: a real vault path written into config exits the empty-vault
# branch and lands a config file.
test_setup_vault_writes_config_on_non_empty_input() {
  _source_common_with_stubs "$SCRIPT_DIR"
  mkdir -p "$TEST_HOME/myvault/CEO"
  : > "$TEST_HOME/myvault/CEO/inbox.md"
  rm -f "$TEST_HOME/.ceo/config"
  MISSING_CONFIG=()
  ceo_setup_vault <<< "$TEST_HOME/myvault" >/dev/null 2>&1
  assert_file_exists "$TEST_HOME/.ceo/config" "config must be written on valid vault input"
  local cfg
  cfg=$(cat "$TEST_HOME/.ceo/config")
  assert_contains "$cfg" "CEO_VAULT=\"$TEST_HOME/myvault\"" "config must persist the typed path"
  local joined="${MISSING_CONFIG[*]:-}"
  if [[ "$joined" == *"CEO_VAULT"* ]]; then
    printf '  FAIL [%s] MISSING_CONFIG must NOT contain CEO_VAULT on valid input\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  fi
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
}

test_gh_auth_helper_refuses_on_network_failure() {
  _install_gh_stub 1 "Get \"https://api.github.com\": dial tcp: lookup api.github.com: no such host"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out rc=0
  out=$(ceo_setup_gh_auth "[2/10]" 2>&1) || rc=$?
  assert_eq "$rc" "1" "transient/network failure must NOT fall through to auth login"
  assert_contains "$out" "transient network" "must surface the network/transient classification"
  assert_contains "$out" "no such host" "must include the captured stderr context"
}

# Mac/Linux tools-check exit-1 path is deferred — running setup-mac.sh
# end-to-end past step 1 requires either reaching the interactive ssh-key
# prompt (which hangs CI) or a portable PATH that excludes git/jq but
# includes shell utilities (which /usr/bin can't provide on either macOS
# or Ubuntu since dirname/sed live there). Filed as a separate follow-up.
# setup-scripts.test.sh already exercises the dry-run happy path.

# === setup-common.sh step-prefix invariants (WSL baseline lock) ===

# Sourcing setup-common.sh in isolation lets us call individual ceo_setup_*
# helpers without running a full installer. We pin the step-prefix strings
# the WSL baseline doc captured (`[3/10]`, `[5/10]`, `[8/10]`, etc.) so a
# rename of any step number is loud at test time.
_source_common_with_stubs() {
  # shellcheck disable=SC2034  # set up for the sourced lib
  MISSING_CONFIG=()
  SCRIPT_DIR="$1"
  # ceo_detect_os is sourced from ceo-config.sh by the installers; tests
  # source it directly.
  # shellcheck source=ceo-config.sh
  source "$1/ceo-config.sh"
  # shellcheck source=setup-common.sh
  source "$1/setup-common.sh"
}

test_setup_check_syncthing_prefixes_step_5_of_10_when_present() {
  cat > "$TEST_HOME/stubs/syncthing" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/syncthing"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out
  out=$(ceo_setup_check_syncthing 2>&1)
  assert_contains "$out" "[5/10] Syncthing found" "syncthing-present must hit step 5/10"
}

test_setup_check_syncthing_warns_when_missing() {
  # Empty PATH — syncthing not present.
  export PATH="$TEST_HOME/empty_bin"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out
  out=$(ceo_setup_check_syncthing 2>&1)
  assert_contains "$out" "[5/10] WARNING: Syncthing not found" "syncthing-missing must hit step 5/10 WARNING"
  assert_contains "$out" "Install Syncthing" "WARNING must include install hint"
}

test_setup_check_yq_prefixes_step_6_of_10_when_present() {
  cat > "$TEST_HOME/stubs/yq" << 'STUB'
#!/bin/bash
echo "yq (test stub) 4.0.0"
STUB
  chmod +x "$TEST_HOME/stubs/yq"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out
  out=$(ceo_setup_check_yq 2>&1)
  assert_contains "$out" "[6/10] yq found" "yq-present must hit step 6/10"
}

test_setup_check_yq_uses_caller_supplied_install_hint_when_missing() {
  export PATH="$TEST_HOME/empty_bin"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out
  out=$(ceo_setup_check_yq "brew install yq" 2>&1)
  assert_contains "$out" "[6/10] WARNING: yq not found" "yq-missing must hit step 6/10 WARNING"
  assert_contains "$out" "brew install yq" "install hint arg must be propagated"
}

test_setup_check_claude_prefixes_step_8_of_10_when_present() {
  cat > "$TEST_HOME/stubs/claude" << 'STUB'
#!/bin/bash
echo "1.0.0"
STUB
  chmod +x "$TEST_HOME/stubs/claude"
  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
  _source_common_with_stubs "$SCRIPT_DIR"
  local out
  out=$(ceo_setup_check_claude 2>&1)
  assert_contains "$out" "[8/10] Claude Code already installed" "claude-present must hit step 8/10"
}

test_setup_exit_if_missing_is_silent_no_op_when_array_empty() {
  _source_common_with_stubs "$SCRIPT_DIR"
  local out rc=0
  out=$(ceo_setup_exit_if_missing 2>&1) || rc=$?
  assert_eq "$rc" "0" "empty MISSING_CONFIG must not exit non-zero"
  assert_eq "$out" "" "empty MISSING_CONFIG must produce no output"
}

test_setup_exit_if_missing_surfaces_array_entries_and_exits_one() {
  _source_common_with_stubs "$SCRIPT_DIR"
  # shellcheck disable=SC2034  # read by ceo_setup_exit_if_missing (sourced)
  MISSING_CONFIG=("git user.name" "plugin INSTALL_DIR")
  local out rc=0
  out=$(ceo_setup_exit_if_missing 2>&1) || rc=$?
  assert_eq "$rc" "1" "non-empty MISSING_CONFIG must exit 1"
  assert_contains "$out" "MISSING REQUIRED CONFIG" "must print the section header"
  assert_contains "$out" "git user.name" "must echo each missing entry"
  assert_contains "$out" "plugin INSTALL_DIR" "must echo each missing entry"
}

run_tests
