#!/bin/bash
# ceo-gather.sh exports CEO_PROFILE_CONTEXT_VERSION=1 only with current Active
# Domains. The weekly-synthesis memo (llm-tools#827) reads version=1 as "this
# content is current", so a stale or missing Profile must leave it unset and let
# the memo print its unavailable warning instead of an empty "current".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TMP=$(mktemp -d)
  OLD_HOME="$HOME"
  OLD_PATH="$PATH"
  export HOME="$TMP"
  export CEO_VAULT="$TMP/vault"
  mkdir -p "$CEO_VAULT/CEO/approvals" "$CEO_VAULT/CEO/log" "$CEO_VAULT/Profile"
  mkdir -p "$TMP/.ceo"
  cat > "$TMP/.ceo/pr-sources.json" << 'JSON'
{ "github": { "accounts": [] }, "gitlab": { "usernames": [] } }
JSON
  mkdir -p "$TMP/bin"
  for _tool in gh glab; do
    printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/$_tool"
    chmod +x "$TMP/bin/$_tool"
  done
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  export HOME="$OLD_HOME"
  export PATH="$OLD_PATH"
  unset CEO_VAULT
  rm -rf "$TMP"
}

# Source the gather in a child process under production's shell options, with a
# stale version=1 already in the environment so "left unset" is observable.
_gather_profile_env() {
  CEO_PROFILE_CONTEXT_VERSION=1 bash -c '
    set -euo pipefail
    source "$1" >/dev/null 2>&1
    printf "RC=0|VERSION=%s|DEGRADED=%s\n%s\n" "${CEO_PROFILE_CONTEXT_VERSION:-unset}" \
      "${FILE_GATHER_DEGRADED:-0}" "$ACTIVE_DOMAINS_CONTENT"
  ' _ "$SCRIPT_DIR/ceo-gather.sh" 2>/dev/null || echo "RC=$?"
}

_write_goals() {
  printf -- '---\nactive_domains_as_of: %s\n---\n## Active Domains\n- Current research\n## Private\nDO NOT EXPORT\n' "$1" \
    > "$CEO_VAULT/Profile/goals.md"
}

test_current_profile_exports_version_and_content() {
  _write_goals "$(date +%F)"
  local out; out=$(_gather_profile_env)
  assert_contains "$out" "RC=0|VERSION=1|DEGRADED=0" "current Profile exports version 1"
  assert_contains "$out" "Current research" "and the Active Domains content"
  assert_contains "$out" "Source: Profile/goals.md" "with its provenance"
  assert_not_contains "$out" "DO NOT EXPORT" "other Profile sections stay out"
}

test_stale_profile_exports_no_version() {
  _write_goals "2020-01-01"
  local out; out=$(_gather_profile_env)
  assert_contains "$out" "RC=0|VERSION=unset" "a stale Profile must not claim version 1"
  assert_contains "$out" "need review" "the withheld reason is still exported for the prompt"
  assert_not_contains "$out" "Current research" "stale domains are withheld"
}

test_undated_legacy_profile_exports_no_version() {
  printf '## Active Domains\n- Old employer\n' > "$CEO_VAULT/Profile.md"
  local out; out=$(_gather_profile_env)
  assert_contains "$out" "RC=0|VERSION=unset" "an undated Profile.md must not claim version 1"
  assert_not_contains "$out" "Old employer" "undated domains are withheld"
}

test_missing_profile_exports_no_version() {
  local out; out=$(_gather_profile_env)
  assert_contains "$out" "RC=0|VERSION=unset" "no Profile at all must not claim version 1"
}

test_unreadable_profile_degrades_and_exports_no_version() {
  mkdir "$CEO_VAULT/Profile/goals.md"
  local out; out=$(_gather_profile_env)
  assert_contains "$out" "RC=0|VERSION=unset|DEGRADED=1" "a read error degrades the gather and claims nothing"
  assert_contains "$out" "unavailable" "and says so in the exported content"
}

run_tests
