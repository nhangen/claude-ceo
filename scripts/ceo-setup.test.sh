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
