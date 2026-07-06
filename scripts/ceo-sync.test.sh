#!/bin/bash
# Tests for `ceo playbook sync` (cmd_playbook_sync): reconcile the syncthing
# vault playbook copies with the git repo (repo = source of truth), closing the
# silent shadow-and-win drift that let scan read a stale playbook.
#
# Invariants pinned here:
#   - a stale vault copy of a repo playbook is overwritten to match the repo
#   - a repo-only playbook is created in the vault
#   - a vault-only (local) playbook is PRESERVED, never deleted, and reported
#   - identical copies are a no-op
#   - --check makes NO writes; exits 1 on drift, 0 when clean, 2 on missing repo
#   - syncthing .sync-conflict-*.md files are skipped, not treated as playbooks

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
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
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export CEO_VAULT="$TMP/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  VAULT_PB="$CEO_DIR/playbooks"
  REPO_PB="$TMP/repo/docs/playbooks"
  mkdir -p "$VAULT_PB" "$REPO_PB"
  export CEO_REPO_PLAYBOOK_DIR="$REPO_PB"
  export CEO_HOSTNAME="testhost"
}

teardown() {
  rm -rf "$TMP"
  unset HOME CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR CEO_HOSTNAME VAULT_PB REPO_PB
}

# Write a playbook file with a body marker so two copies of the same name can
# differ byte-for-byte (drift).
_pb() {
  local file="$1" name="$2" body="${3:-body}"
  {
    echo "---"; echo "name: $name"; echo "status: active"; echo "runner: claude"
    echo "---"; echo ""; echo "# $name"; echo "$body"
  } > "$file"
}

_run_sync() { SYNC_OUT=$(cmd_playbook_sync "$@" 2>&1); SYNC_RC=$?; }

test_sync_overwrites_stale_vault_copy() {
  _pb "$REPO_PB/foo.md" foo "NEW-repo-content"
  _pb "$VAULT_PB/foo.md" foo "OLD-stale-content"
  _run_sync
  assert_eq "$SYNC_RC" "0" "sync exits 0 on success"
  # vault copy must now be byte-identical to the repo copy
  assert_eq "$(cmp -s "$REPO_PB/foo.md" "$VAULT_PB/foo.md"; echo $?)" "0" \
    "stale vault copy must be overwritten to match the repo (fails if sync is a no-op)"
  assert_contains "$SYNC_OUT" "Synced: foo.md" "sync must report the file it updated"
}

test_sync_creates_repo_only_playbook_in_vault() {
  _pb "$REPO_PB/bar.md" bar "repo-only"
  _run_sync
  assert_file_exists "$VAULT_PB/bar.md" "a repo-only playbook must be created in the vault"
  assert_eq "$(cmp -s "$REPO_PB/bar.md" "$VAULT_PB/bar.md"; echo $?)" "0" \
    "created vault copy must match the repo"
}

test_sync_preserves_vault_only_playbook() {
  _pb "$VAULT_PB/local.md" local-only "local custom"
  _pb "$REPO_PB/foo.md" foo "repo"
  _run_sync
  assert_file_exists "$VAULT_PB/local.md" "a vault-only playbook must NOT be deleted by sync"
  assert_contains "$SYNC_OUT" "local.md" "vault-only playbook must be reported for review"
  assert_contains "$SYNC_OUT" "Vault-only" "sync must label the vault-only report"
}

test_sync_noop_when_identical() {
  _pb "$REPO_PB/foo.md" foo "same"
  _pb "$VAULT_PB/foo.md" foo "same"
  _run_sync
  assert_not_contains "$SYNC_OUT" "Synced: foo.md" "identical copy must not be re-synced"
  assert_contains "$SYNC_OUT" "up-to-date" "identical copy must count as up-to-date"
}

test_sync_check_makes_no_writes_and_exits_1_on_drift() {
  _pb "$REPO_PB/foo.md" foo "NEW"
  _pb "$VAULT_PB/foo.md" foo "OLD"
  _run_sync --check
  assert_eq "$SYNC_RC" "1" "--check must exit 1 when drift exists"
  # vault must be UNCHANGED by --check
  assert_eq "$(grep -c OLD "$VAULT_PB/foo.md")" "1" \
    "--check must not modify the vault (stale content must remain)"
}

test_sync_check_exits_0_when_clean() {
  _pb "$REPO_PB/foo.md" foo "same"
  _pb "$VAULT_PB/foo.md" foo "same"
  _run_sync --check
  assert_eq "$SYNC_RC" "0" "--check must exit 0 when vault matches repo"
}

test_sync_skips_syncthing_conflict_files() {
  _pb "$REPO_PB/foo.md" foo "repo"
  _pb "$VAULT_PB/foo.sync-conflict-20260101-120000-ABCDEFG.md" foo "conflict junk"
  _run_sync
  # The conflict file is not a repo playbook, so it must be neither synced nor
  # deleted, and must not be reported as a vault-only playbook to reconcile.
  assert_file_exists "$VAULT_PB/foo.sync-conflict-20260101-120000-ABCDEFG.md" \
    "sync must leave syncthing conflict files untouched"
  assert_not_contains "$SYNC_OUT" "sync-conflict" \
    "sync must not treat a .sync-conflict file as a playbook"
}

test_sync_missing_repo_dir_exits_2() {
  export CEO_REPO_PLAYBOOK_DIR="$TMP/no-such-repo"
  _run_sync
  assert_eq "$SYNC_RC" "2" "sync must exit 2 when the repo playbook dir is missing"
}

run_tests
