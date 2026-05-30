#!/bin/bash
# Tests for setup-mac.sh that lock in the package-driver / --dry-run contract
# (#96) and the MISSING_CONFIG ordering hotfix (#101 regression bundled into
# PR #104). Reverting setup-mac.sh:13 or setup-common.sh:27-28 must fail at
# least one test here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/stubs"

  for tool in brew gh git sudo curl dd tee dpkg snap apt-get apt; do
    cat > "$TEST_HOME/stubs/$tool" << 'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TEST_HOME/stubs/$tool"
  done

  cat > "$TEST_HOME/stubs/hostname" << 'STUB'
#!/bin/bash
echo "testhost"
STUB
  chmod +x "$TEST_HOME/stubs/hostname"

  cat > "$TEST_HOME/stubs/ssh-keygen" << STUB
#!/bin/bash
echo "\$@" > "$TEST_HOME/ssh-keygen-args.log"
_key_path=""
while [ \$# -gt 0 ]; do
  case "\$1" in -f) shift; _key_path="\$1" ;; esac
  shift
done
if [ -n "\$_key_path" ]; then
  echo "stub-priv" > "\$_key_path"
  echo "ssh-ed25519 stub-pub stub-comment" > "\${_key_path}.pub"
fi
STUB
  chmod +x "$TEST_HOME/stubs/ssh-keygen"

  export PATH="$TEST_HOME/stubs:$PATH_BACKUP"
}

teardown() {
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  rm -rf "$TEST_HOME"
}

test_setup_mac_source_time_guard_does_not_trip() {
  local out
  out=$(bash "$SCRIPT_DIR/setup-mac.sh" --dry-run </dev/null 2>&1 || true)
  assert_contains "$out" "CEO Agent" "setup-mac.sh must reach its header echo (hotfix: MISSING_CONFIG declared before source)"
  assert_not_contains "$out" "caller must declare MISSING_CONFIG" "setup-common.sh guard must not trip"
}

test_setup_mac_dry_run_prints_brew_install_line() {
  local out
  out=$(bash "$SCRIPT_DIR/setup-mac.sh" --dry-run </dev/null 2>&1 || true)
  assert_contains "$out" "[dry-run] brew install git gh jq yq"
}

test_setup_mac_rejects_unknown_arg_with_exit_2() {
  local rc=0
  bash "$SCRIPT_DIR/setup-mac.sh" --bogus </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "2" "unknown arg must exit 2"
}

test_empty_hostname_falls_back_to_host_in_ssh_comment() {
  cat > "$TEST_HOME/stubs/hostname" << 'STUB'
#!/bin/bash
exit 0
STUB
  bash "$SCRIPT_DIR/setup-mac.sh" --dry-run </dev/null >/dev/null 2>&1 || true
  local args
  args=$(cat "$TEST_HOME/ssh-keygen-args.log" 2>/dev/null || echo "")
  assert_contains "$args" "ceo-agent@host" "empty hostname must fall back to 'host', not produce naked 'ceo-agent@'"
}

run_tests
