#!/bin/bash
# ceo-config.sh — Shared vault config library for the CEO agent system.
# Source this file; do not execute it directly.
#
# Provides:
#   ceo_detect_os()         — prints: wsl | linux | macos | unknown
#   ceo_config_path()       — prints path to ~/.ceo/config
#   ceo_load_config()       — resolves CEO_VAULT; returns 0 on success, 1 if empty
#   ceo_require_vault()     — load config; exit 1 with operator guidance if unresolved
#   ceo_validate_vault()    — verifies CEO/inbox.md exists; returns 0 on pass, 1 on fail
#   ceo_augment_path()      — prepend bun/Homebrew/.local prefixes to PATH (idempotent)
#   ceo_resolve_real_home() — print passwd-canonical $HOME for running user; rc=0/1
#   ceo_pin_home_or_warn()  — resolve+export $HOME from passwd; warn-and-rc=1 on fail
#   ceo_inbox_has_unchecked() — scan inbox sources for an unchecked todo; rc=0/1
#   ceo_assert_primary_host() — gate Syncthing-shared writes; rc=0 allowed/1 deny
#   ceo_registry_validate() — verifies registry.json schema_version; returns 0/1/2
#   ceo_write_alert_frontmatter() — emit alert frontmatter to stdout; validates enum
#   ceo_read_alert_field()  — read a single frontmatter field; handles colons in values
#
# Resolution order in ceo_load_config():
#   1. CEO_VAULT already set in environment → use it as-is, return 0 (bypass mode)
#   2. ~/.ceo/config exists → source it, CEO_VAULT from that file
#   3. Legacy discovery loop (fallback — remove after 2026-05-26)
# Returns 1 if none of the above resolved CEO_VAULT.
#
# Idempotency guard — safe to source multiple times.
[ -n "${_CEO_CONFIG_LOADED:-}" ] && return 0
_CEO_CONFIG_LOADED=1

# ---------------------------------------------------------------------------
# ceo_detect_os — detect the runtime environment
# ---------------------------------------------------------------------------
ceo_detect_os() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
  elif [ "$(uname)" = "Darwin" ]; then
    echo "macos"
  elif [ "$(uname)" = "Linux" ]; then
    echo "linux"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# ceo_config_path — canonical path for the persisted config file
# ---------------------------------------------------------------------------
ceo_config_path() {
  echo "$HOME/.ceo/config"
}

# ---------------------------------------------------------------------------
# ceo_load_config — resolve CEO_VAULT and export it.
#
# Returns:
#   0  CEO_VAULT is set (env bypass, config file, or legacy discovery)
#   1  CEO_VAULT is still empty after all resolution steps
# ---------------------------------------------------------------------------
ceo_load_config() {
  # Step 1: CEO_VAULT already set in environment → bypass mode.
  if [ -n "${CEO_VAULT:-}" ]; then
    export CEO_VAULT
    return 0
  fi

  # Step 2: Persisted config file → source it.
  local _cfg
  _cfg="$(ceo_config_path)"
  if [ -f "$_cfg" ]; then
    # shellcheck source=/dev/null
    source "$_cfg"
    if [ -n "${CEO_VAULT:-}" ]; then
      export CEO_VAULT
      return 0
    fi
  fi

  # Step 3: Legacy discovery loop — kept as fallback until 2026-05-26.
  # TODO: Remove this block after 2026-05-26 once all machines have ~/.ceo/config.
  local _user="${USER:-$(whoami)}"
  local _candidate
  for _candidate in \
    "/mnt/z/Users/$_user/Documents/Obsidian" \
    "/mnt/c/Users/$_user/Documents/Obsidian" \
    "$HOME/Documents/Obsidian" \
    "$HOME/Obsidian"
  do
    if [ -d "$_candidate/CEO" ]; then
      export CEO_VAULT="$_candidate"
      return 0
    fi
  done

  # Postcondition: CEO_VAULT remains unset on rc=1; ceo_require_vault() turns this into exit 1.
  return 1
}

# ---------------------------------------------------------------------------
# ceo_resolve_timeout_bin — sets CEO_TIMEOUT_BIN to "timeout" / "gtimeout" / "".
# Empty value means no portable timeout available; callers must handle that.
# Mirrors the resolver in ceo-cron.sh:85-107; promoted here so non-cron scripts
# (e.g. `ceo playbook scan`'s ollama probe) can share the same shim.
# ---------------------------------------------------------------------------
ceo_resolve_timeout_bin() {
  if command -v timeout &>/dev/null; then
    CEO_TIMEOUT_BIN="timeout"
  elif command -v gtimeout &>/dev/null; then
    CEO_TIMEOUT_BIN="gtimeout"
  else
    CEO_TIMEOUT_BIN=""
  fi
  export CEO_TIMEOUT_BIN
}

# ---------------------------------------------------------------------------
# ceo_require_vault — load config; exit 1 with operator guidance if unresolved.
# For executed scripts only. Sourced scripts must call ceo_load_config and
# `return 1` on failure (exit would kill the caller's shell).
# ---------------------------------------------------------------------------
ceo_require_vault() {
  : "${HOME:?HOME must be set before ceo_require_vault}"
  local fail_file="$HOME/.claude/ceo-cron-config-fails"
  if ceo_load_config; then
    rm -f "$fail_file" 2>/dev/null || true
    return 0
  fi
  echo "FATAL — CEO_VAULT unresolved. Run 'ceo setup' to initialize." >&2

  mkdir -p "$HOME/.claude" 2>/dev/null || true
  local lock_file="${fail_file}.lock"
  local lock_dir="${fail_file}.lock.d"
  local locked=false

  # Atomic increment: prefer flock (Linux), fall back to mkdir directory-lock
  # (macOS where flock isn't installed). Bounded wait so a stale lock doesn't
  # block the cron tick indefinitely; on timeout we log and skip the increment
  # rather than race on the read-modify-write.
  if command -v flock &>/dev/null && [ -z "${CEO_TEST_FORCE_MKDIR_LOCK:-}" ]; then
    if exec 202>"$lock_file" && flock -w 5 -x 202; then
      locked=true
    else
      echo "WARN — could not acquire flock on $lock_file; skipping fail-counter increment" >&2
      exec 202>&- 2>/dev/null || true
    fi
  else
    local _i
    for _i in $(seq 1 5); do
      if mkdir "$lock_dir" 2>/dev/null; then
        locked=true
        break
      fi
      sleep 1
    done
    if ! $locked; then
      echo "WARN — could not acquire mkdir lock on $lock_dir; skipping fail-counter increment" >&2
    fi
  fi

  local fails=0
  if $locked; then
    fails=$(cat "$fail_file" 2>/dev/null || echo 0)
    case "$fails" in (''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails + 1))
    echo "$fails" > "$fail_file"
    if command -v flock &>/dev/null && [ -z "${CEO_TEST_FORCE_MKDIR_LOCK:-}" ]; then
      flock -u 202 2>/dev/null || true
      exec 202>&- 2>/dev/null || true
    else
      rmdir "$lock_dir" 2>/dev/null || true
    fi
  fi

  if [ "$fails" -ge 3 ]; then
    # Sentinel file alongside the notification channels so observability sees
    # the escalation even if osascript (locked session) and logger both fail.
    : > "$HOME/.claude/ceo-fatal-alerted" 2>/dev/null || true
    if command -v osascript &>/dev/null; then
      osascript -e 'display notification "CEO_VAULT unresolved for 3+ cron ticks. Run ceo setup." with title "Claude CEO FATAL"' &>/dev/null || true
    else
      logger "Claude CEO FATAL: CEO_VAULT unresolved for 3+ cron ticks. Run ceo setup." 2>/dev/null || true
    fi
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# ceo_augment_path — prepend common user-tool prefixes to PATH so cron-invoked
# scripts can find Homebrew binaries, bun-installed CLIs, and ~/.local/bin
# symlinks. Cron starts with PATH=/usr/bin:/bin.
# ---------------------------------------------------------------------------
ceo_augment_path() {
  [ -n "${_CEO_PATH_AUGMENTED:-}" ] && return 0
  : "${HOME:?HOME must be set before ceo_augment_path}"
  case "$(ceo_detect_os)" in
    macos)
      export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
      ;;
    wsl|linux)
      export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
      ;;
    *)
      # Minimal trusted set when OS detection fails — do not normalize-merge with the branches above.
      export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
      ;;
  esac
  export _CEO_PATH_AUGMENTED=1
}

# ---------------------------------------------------------------------------
# ceo_resolve_plugin_cli — resolve a Claude Code plugin-provided CLI entrypoint
# from the local plugin cache, returning the runtime command and absolute entry
# path on stdout (one per line).
#
# Plugins land at ~/.claude/plugins/cache/<owner>/<plugin>/<version>/ and do
# not install anything on PATH. Consumers that need to invoke a plugin-provided
# CLI from cron/scripts should resolve via the cache rather than rely on stale
# PATH symlinks from prior standalone installs. See nhangen/claude-ceo#37.
#
# Usage (bash 3.2 compatible — macOS default lacks mapfile/readarray):
#   if out=$(ceo_resolve_plugin_cli "nhangen-tools/token-scope" "src/cli.ts"); then
#     runtime=$(printf '%s\n' "$out" | sed -n '1p')
#     entry=$(printf '%s\n' "$out" | sed -n '2p')
#     "$runtime" "$entry" --since 1d
#   fi
#
# Args:
#   $1  owner/plugin slug (e.g. nhangen-tools/token-scope)
#   $2  entry path relative to the version directory (e.g. src/cli.ts)
#   $3  runtime to prepend (optional, default: bun)
#
# Returns:
#   0  prints "<runtime>\n<abs-entry-path>" on stdout
#   1  plugin not installed; entry missing; HOME unset
# ---------------------------------------------------------------------------
ceo_resolve_plugin_cli() {
  : "${HOME:?HOME must be set before ceo_resolve_plugin_cli}"
  local slug="${1:?slug required (owner/plugin)}"
  local entry="${2:?entry path required (relative to version dir)}"
  local runtime="${3:-bun}"
  local cache_root="$HOME/.claude/plugins/cache/$slug"
  local latest
  latest=$(ls -1d "$cache_root"/*/ 2>/dev/null | sort -V | tail -1) || true
  if [ -z "$latest" ] || [ ! -d "$latest" ]; then
    return 1
  fi
  local abs="${latest%/}/$entry"
  [ -f "$abs" ] || return 1
  printf '%s\n%s\n' "$runtime" "$abs"
}

# ---------------------------------------------------------------------------
# ceo_resolve_real_home — print the running user's canonical home from passwd,
# ignoring $HOME. Use when a script needs access to real-user state (rtk DB,
# ccusage data, keyring tokens) and may be invoked from contexts that scrubbed
# or sandboxed $HOME (env -i, sudo without -E, test harness with HOME=mktemp).
# Prints the resolved path on stdout.
#
# Returns:
#   0  resolved path printed
#   1  one of: id -un failed (no usable user identity); both getent and dscl
#      unavailable; resolver returned an empty string (e.g. Homebrew gnu-getent
#      which is host-only); resolved path failed [ -d ] check (stale passwd
#      entry, mobile-account home migration, etc.).
# ---------------------------------------------------------------------------
ceo_resolve_real_home() {
  local user resolved=""
  user=$(id -un 2>/dev/null) || return 1
  if command -v getent >/dev/null 2>&1; then
    resolved=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
  fi
  if [ -z "$resolved" ] && [ "$(uname)" = "Darwin" ] && command -v dscl >/dev/null 2>&1; then
    resolved=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  fi
  if [ -n "$resolved" ] && [ -d "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# ceo_pin_home_or_warn — resolve passwd-canonical $HOME and export it; warn on
# failure. Use when a script needs access to real-user state (rtk DB, ccusage)
# and may be invoked from contexts that scrubbed or sandboxed $HOME (env -i,
# sudo without -E, test harness with HOME=mktemp).
#
# Returns 0 on success (HOME re-exported); 1 if ceo_resolve_real_home failed.
# On failure $HOME is left as the caller passed it and a WARN line goes to
# stderr with diagnostic context. Folds resolve+export+warn into one call so
# future callers can't copy a silent if-block.
# ---------------------------------------------------------------------------
ceo_pin_home_or_warn() {
  local real_home
  if real_home=$(ceo_resolve_real_home); then
    export HOME="$real_home"
    return 0
  fi
  printf 'WARN: ceo_pin_home_or_warn: passwd resolution failed; HOME=%q (id=%s, uname=%s)\n' \
    "${HOME:-<unset>}" "$(id -un 2>/dev/null || echo \?)" "$(uname)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Registry schema. Bump CEO_REGISTRY_SCHEMA_VERSION whenever the on-disk
# shape of registry.json changes — a peer host running an older binary will
# then refuse to dispatch instead of silently downgrading the registry on
# the next `ceo playbook scan`.
#
# Version history:
#   2 — adds runner, script fields (PR #4)
#   1 — implicit (pre-runner-script registry; missing field treated as <2)
# ---------------------------------------------------------------------------
CEO_REGISTRY_SCHEMA_VERSION=2
# shellcheck disable=SC2034
CEO_VALID_RUNNERS=(claude script ollama ollama-think)

# ceo_registry_version <registry_file>
#   Prints the integer schema_version, or nothing if missing/malformed.
ceo_registry_version() {
  local registry_file="${1:-${CEO_DIR:-}/registry.json}"
  jq -r '
    if has("schema_version")
      and (.schema_version | type) == "number"
      and (.schema_version | floor == .)
    then .schema_version
    else empty
    end
  ' "$registry_file" 2>/dev/null
}

# ceo_registry_validate <registry_file>
#   0 — schema_version is an integer >= CEO_REGISTRY_SCHEMA_VERSION
#   1 — registry file does not exist
#   2 — schema_version missing, malformed, or below current
ceo_registry_validate() {
  local registry_file="${1:-${CEO_DIR:-}/registry.json}"
  if [ ! -f "$registry_file" ]; then
    return 1
  fi
  local v
  v=$(ceo_registry_version "$registry_file")
  if ! [ "$v" -ge "$CEO_REGISTRY_SCHEMA_VERSION" ] 2>/dev/null; then
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ceo_pr_sources_path — canonical path for the persisted PR-sources config.
#
# Schema (JSON):
#   {
#     "github": { "accounts":  [<str>...], "exclude_orgs": [<str>...] },
#     "gitlab": { "usernames": [<str>...], "hosts": [<str>...] },
#     "dedupe": true
#   }
#
# Missing/empty fields fall back to runtime discovery so the gather path stays
# useful on a fresh host without explicit config. See nhangen/claude-ceo#61.
# ---------------------------------------------------------------------------
ceo_pr_sources_path() {
  echo "$HOME/.ceo/pr-sources.json"
}

# ceo_pr_sources_github_accounts [path]
#   Echo one account name per line. Empty file/missing field → discover via
#   `gh auth status`. Empty stdout means "skip GitHub" to callers.
ceo_pr_sources_github_accounts() {
  local path="${1:-$(ceo_pr_sources_path)}"
  if [ -f "$path" ] && command -v jq >/dev/null 2>&1 && jq empty "$path" 2>/dev/null; then
    local accounts
    accounts=$(jq -r '.github.accounts // [] | .[]' "$path" 2>/dev/null)
    if [ -n "$accounts" ]; then
      printf '%s\n' "$accounts"
      return 0
    fi
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh auth status 2>&1 | awk '/account [a-zA-Z0-9_-]+/ {for(i=1;i<=NF;i++) if($i=="account") print $(i+1)}' | sort -u
  fi
}

# ceo_pr_sources_github_exclude_orgs [path] — one org per line.
ceo_pr_sources_github_exclude_orgs() {
  local path="${1:-$(ceo_pr_sources_path)}"
  [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq empty "$path" 2>/dev/null || return 0
  jq -r '.github.exclude_orgs // [] | .[]' "$path" 2>/dev/null
}

# ceo_pr_sources_gitlab_usernames [path]
#   One username per line. Empty file/missing field → discover via glab.
ceo_pr_sources_gitlab_usernames() {
  local path="${1:-$(ceo_pr_sources_path)}"
  if [ -f "$path" ] && command -v jq >/dev/null 2>&1 && jq empty "$path" 2>/dev/null; then
    local users
    users=$(jq -r '.gitlab.usernames // [] | .[]' "$path" 2>/dev/null)
    if [ -n "$users" ]; then
      printf '%s\n' "$users"
      return 0
    fi
  fi
  if command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
    glab api user 2>/dev/null | (command -v jq >/dev/null 2>&1 && jq -r '.username // empty' || true)
  fi
}

# ceo_pr_sources_dedupe [path]
#   rc=0 if dedupe on (default); rc=1 only when explicitly set to false.
ceo_pr_sources_dedupe() {
  local path="${1:-$(ceo_pr_sources_path)}"
  [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq empty "$path" 2>/dev/null || return 0
  local v
  # `.dedupe // true` is wrong — jq's // returns the right operand on
  # null OR false, so an explicit `false` becomes `true`. Use has() instead.
  v=$(jq -r 'if has("dedupe") then .dedupe else true end' "$path" 2>/dev/null)
  [ "$v" = "false" ] && return 1
  return 0
}

# ceo_pr_sources_setup — interactive prompt; writes JSON to ceo_pr_sources_path.
# Re-running overwrites the file. Returns 0 on write, 1 only if jq is missing
# (cannot construct the JSON safely).
ceo_pr_sources_setup() {
  : "${HOME:?HOME must be set before ceo_pr_sources_setup}"
  local path
  path=$(ceo_pr_sources_path)
  mkdir -p "$(dirname "$path")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required to write $path" >&2
    return 1
  fi

  local -a selected_accounts=()
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local discovered
    discovered=$(gh auth status 2>&1 | awk '/account [a-zA-Z0-9_-]+/ {for(i=1;i<=NF;i++) if($i=="account") print $(i+1)}' | sort -u)
    if [ -n "$discovered" ]; then
      echo "  GitHub accounts discovered via gh auth status:"
      local acct ans
      while IFS= read -r acct; do
        [ -z "$acct" ] && continue
        printf "    Query PRs for '%s'? [Y/n] " "$acct"
        read -r ans
        case "$ans" in
          n|N|no|No) ;;
          *) selected_accounts+=("$acct") ;;
        esac
      done <<< "$discovered"
    else
      echo "  WARNING: gh is installed but no accounts were discoverable from 'gh auth status'."
    fi
  else
    echo "  WARNING: gh CLI not authenticated. Run 'gh auth login' then re-run 'ceo pr-sources'."
  fi

  local -a gitlab_users=()
  if command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
    local gluser
    gluser=$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null)
    if [ -n "$gluser" ]; then
      local ans
      printf "    Query GitLab MRs for '%s'? [Y/n] " "$gluser"
      read -r ans
      case "$ans" in
        n|N|no|No) ;;
        *) gitlab_users+=("$gluser") ;;
      esac
    fi
  else
    echo "  glab not authenticated. Skipping GitLab username selection."
  fi

  if [ ${#selected_accounts[@]} -eq 0 ] && [ ${#gitlab_users[@]} -eq 0 ]; then
    echo "  WARNING: no GitHub or GitLab sources selected. PR counts in the morning brief will be empty."
  fi

  local accounts_json="[]" usernames_json="[]"
  if [ ${#selected_accounts[@]} -gt 0 ]; then
    accounts_json=$(printf '%s\n' "${selected_accounts[@]}" | jq -R . | jq -s .)
  fi
  if [ ${#gitlab_users[@]} -gt 0 ]; then
    usernames_json=$(printf '%s\n' "${gitlab_users[@]}" | jq -R . | jq -s .)
  fi

  local tmp="$path.tmp"
  jq -n \
    --argjson accounts "$accounts_json" \
    --argjson usernames "$usernames_json" \
    '{
      github: { accounts: $accounts, exclude_orgs: [] },
      gitlab: { usernames: $usernames, hosts: ["gitlab.com"] },
      dedupe: true
    }' > "$tmp"
  mv "$tmp" "$path"
  echo "  Wrote $path"
}

# ---------------------------------------------------------------------------
# ceo_validate_vault — verify the vault is ready (CEO/inbox.md must exist).
# Call after ceo_load_config.
#
# Returns:
#   0  CEO/inbox.md exists — vault is synced and structurally valid
#   1  missing — vault not synced, CEO_VAULT wrong, or Syncthing not running
# ---------------------------------------------------------------------------
ceo_validate_vault() {
  if [ -z "${CEO_VAULT:-}" ]; then
    echo "ERROR: CEO_VAULT is not set. Run ceo_load_config first." >&2
    return 1
  fi
  if [ ! -f "$CEO_VAULT/CEO/inbox.md" ]; then
    echo "ERROR: CEO vault not ready — $CEO_VAULT/CEO/inbox.md not found." >&2
    echo "  Is Syncthing running? Is CEO_VAULT set correctly? (current: $CEO_VAULT)" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ceo_inbox_has_unchecked — scan legacy CEO/inbox.md and per-host
# CEO/inbox/<host>.md shadow files for any unchecked todo line.
#
# Per-host shadow files exist because Syncthing peers cannot safely share a
# single inbox.md writer; see issue #5. The legacy inbox.md remains supported
# for user-curated entries.
#
# Reads CEO_DIR from the environment (callers already have it set).
#
# Returns:
#   0  at least one "- [ ]" line exists in any inbox source
#   1  no unchecked items, or no inbox sources present
# ---------------------------------------------------------------------------
ceo_inbox_has_unchecked() {
  local dir="${CEO_DIR:?CEO_DIR must be set before ceo_inbox_has_unchecked}"
  if [ -f "$dir/inbox.md" ] && grep -q "^- \[ \]" "$dir/inbox.md" 2>/dev/null; then
    return 0
  fi
  if [ -d "$dir/inbox" ]; then
    local f
    for f in "$dir/inbox/"*.md; do
      [ -f "$f" ] || continue
      if grep -q "^- \[ \]" "$f" 2>/dev/null; then
        return 0
      fi
    done
  fi
  return 1
}

# ---------------------------------------------------------------------------
# ceo_assert_primary_host — gate writes to Syncthing-shared state behind the
# host configured as primary in CEO/settings.json.
#
# The invariant: only the primary host overwrites Syncthing-shared registry
# state. The gate is opt-in — settings.json absent means no gate.
#
# Returns 0 (host is allowed to proceed) when:
#   - CEO/settings.json is absent (backward-compatible, no gate configured)
#   - settings.json is present, parseable, and primary_host is empty
#   - settings.json is present, parseable, and primary_host == this host
#
# Returns 1 (host MUST NOT proceed) when:
#   - settings.json is present but jq is not installed (cannot evaluate gate)
#   - settings.json is present but malformed JSON
#   - this host cannot be resolved (CEO_HOSTNAME unset and `hostname -s` empty)
#   - primary_host is set and does not match this host
#
# Unknown top-level keys in settings.json emit a warning to stderr (typo
# defense — see ~/.claude/rules/enum-config-typo-fallback.md). Failing-open
# on a typo is the silent-regression shape this helper exists to prevent.
# ---------------------------------------------------------------------------
ceo_assert_primary_host() {
  : "${CEO_DIR:?CEO_DIR must be set before ceo_assert_primary_host}"
  local settings_file="$CEO_DIR/settings.json"
  local jq_bin="${CEO_JQ_BIN:-jq}"

  [ -f "$settings_file" ] || return 0

  if ! command -v "$jq_bin" &>/dev/null; then
    echo "ERROR: $settings_file exists but jq is not installed; cannot evaluate primary_host gate." >&2
    echo "  Install jq (brew install jq | sudo apt install jq) or remove $settings_file." >&2
    return 1
  fi

  if ! "$jq_bin" empty "$settings_file" 2>/dev/null; then
    echo "ERROR: $settings_file is not valid JSON; refusing to evaluate primary_host gate." >&2
    return 1
  fi

  local known_keys=" primary_host cooldown_seconds branch_prefix notify_events discord_report_triggers "
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$known_keys" in
      *" $k "*) ;;
      *) echo "WARNING: $settings_file contains unknown key '$k' — ignored. Known keys:$known_keys" >&2 ;;
    esac
  done < <("$jq_bin" -r 'keys[]' "$settings_file" 2>/dev/null || true)

  local primary_host
  primary_host=$("$jq_bin" -r '.primary_host // ""' "$settings_file" 2>/dev/null || echo "")
  [ -n "$primary_host" ] || return 0

  local this_host="${CEO_HOSTNAME:-$(hostname -s)}"
  if [ -z "$this_host" ]; then
    echo "ERROR: cannot determine this host (CEO_HOSTNAME unset and 'hostname -s' returned empty)." >&2
    return 1
  fi

  if [ "$this_host" != "$primary_host" ]; then
    echo "ERROR: this operation must run on the primary host ($primary_host); this host is '$this_host'." >&2
    echo "  Either run on $primary_host, or unset 'primary_host' in $settings_file." >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# ceo_write_alert_frontmatter — emit a CEO/alerts/*.md frontmatter block.
#
# Centralizes the alert schema so a second alert producer cannot drift on
# field names, status enum values, or timestamp parsing semantics.
#
# Required:
#   --status=<clear|firing>           validated; other values return 1.
#                                     `unknown` is reserved as a consumer-side
#                                     corruption sentinel and is not accepted
#                                     here — no legitimate producer should
#                                     write a frontmatter with status: unknown.
#   --since=<timestamp>               first time current status was observed
#   --host=<hostname>                 originating host
#   --last-check=<timestamp>          time of this write (caller-supplied for
#                                     determinism in tests)
#
# Optional:
#   --field key=value                 additional frontmatter fields
#                                     (repeatable). Values must not contain newlines.
#
# Writes the `---`-delimited YAML frontmatter block to stdout. Caller is
# responsible for the body (`{ ceo_write_alert_frontmatter ...; printf '...'; } > file`).
# ---------------------------------------------------------------------------
ceo_write_alert_frontmatter() {
  local status="" since="" host="" last_check=""
  local -a extra_fields=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --status=*)     status="${1#--status=}" ;;
      --since=*)      since="${1#--since=}" ;;
      --host=*)       host="${1#--host=}" ;;
      --last-check=*) last_check="${1#--last-check=}" ;;
      --field)        shift; extra_fields+=("${1:-}") ;;
      --field=*)      extra_fields+=("${1#--field=}") ;;
      *)
        printf 'ERROR: ceo_write_alert_frontmatter: unknown argument %q\n' "$1" >&2
        return 1
        ;;
    esac
    shift
  done

  case "$status" in
    clear|firing) ;;
    *)
      printf 'ERROR: ceo_write_alert_frontmatter: invalid --status=%q (want clear|firing)\n' \
        "$status" >&2
      return 1
      ;;
  esac
  [ -z "$since" ]      && { echo "ERROR: ceo_write_alert_frontmatter: --since= required" >&2; return 1; }
  [ -z "$host" ]       && { echo "ERROR: ceo_write_alert_frontmatter: --host= required" >&2; return 1; }
  [ -z "$last_check" ] && { echo "ERROR: ceo_write_alert_frontmatter: --last-check= required" >&2; return 1; }

  printf -- '---\n'
  printf 'status: %s\n' "$status"
  printf 'since: %s\n' "$since"
  printf 'last_check: %s\n' "$last_check"
  printf 'host: %s\n' "$host"

  local kv k v
  for kv in ${extra_fields[@]+"${extra_fields[@]}"}; do
    [ -z "$kv" ] && continue
    if [[ "$kv" != *=* ]]; then
      printf 'ERROR: ceo_write_alert_frontmatter: --field value %q is not key=value\n' "$kv" >&2
      return 1
    fi
    k="${kv%%=*}"
    v="${kv#*=}"
    printf '%s: %s\n' "$k" "$v"
  done

  printf -- '---\n'
}

# ---------------------------------------------------------------------------
# ceo_read_alert_field <path> <field>
#
# Read a single frontmatter field from an alert file. Uses awk sub() to strip
# the "field:" prefix so values containing colons (timestamps with offsets,
# wikilinks, urls) round-trip correctly — the prior `-F': *'` parser truncated
# `since: 2026-01-01T00:00:00-0500` to `2026-01-01T00`.
#
# Exit codes (callers must distinguish corruption from absence):
#   0  field found; value (possibly empty) printed to stdout
#   1  file exists but field absent — caller should treat as corruption
#   2  file does not exist — legitimate "no prior state" for first-run paths
#
# Field-name match is anchored: `host` does not match `hostname`.
# ---------------------------------------------------------------------------
ceo_read_alert_field() {
  local path="$1" field="$2"
  [ -f "$path" ] || return 2
  awk -v f="$field" '
    substr($0, 1, length(f)+1) == f ":" {
      sub("^" f ":[[:space:]]*", "")
      sub(/[[:space:]]+$/, "")
      print
      found=1
      exit
    }
    END { exit !found }
  ' "$path"
}
