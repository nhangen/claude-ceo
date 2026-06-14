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

  # Step 3: Legacy discovery loop — kept as fallback while older hosts catch up to ~/.ceo/config.
  # TODO: Re-evaluate removal once every machine has ~/.ceo/config; original 2026-05-26 target slipped.
  local _user="${USER:-$(whoami)}"
  local _candidates=()
  if [ "$(ceo_detect_os)" = "wsl" ]; then
    _candidates+=( \
      "/mnt/z/Users/$_user/Documents/Obsidian" \
      "/mnt/c/Users/$_user/Documents/Obsidian" \
    )
  fi
  _candidates+=( \
    "$HOME/Documents/Obsidian" \
    "$HOME/Obsidian" \
  )
  local _candidate
  for _candidate in "${_candidates[@]}"; do
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
#   3 — adds optional artifact field (per-playbook expected-output path) so
#       `ceo doctor` can flag completed-but-no-output runs (#88, #89)
#   2 — adds runner, script fields (PR #4)
#   1 — implicit (pre-runner-script registry; missing field treated as <2)
# ---------------------------------------------------------------------------
CEO_REGISTRY_SCHEMA_VERSION=3

# The generated registry.json lives host-local, not in the synced vault: two
# hosts scanning would otherwise both rewrite the synced file and produce
# Syncthing .sync-conflict copies. The vault keeps only the playbook .md
# definitions (which scan reads). The scheduler daemon reads the same path.
_ceo_registry_path() {
  : "${HOME:?HOME must be set to resolve the host-local registry path}"
  printf '%s\n' "$HOME/.ceo/registry.json"
}

# enabled.json is host-local like the registry: it lists the `each`-scope
# playbook names THIS machine runs. The scheduler daemon reads the same path.
# (`single`-scope playbooks are not gated here — they run on their assigned
# owner host, recorded in the synced swarm.json owners map.)
_ceo_enabled_path() {
  : "${HOME:?HOME must be set to resolve the host-local enabled path}"
  printf '%s\n' "$HOME/.ceo/enabled.json"
}

# Unlike registry.json (host-local), swarm.json IS synced: it describes the
# swarm itself (which hosts participate, who owns each single-scope playbook),
# so every host must read the same file. The scheduler daemon reads this path
# and tolerates the file being absent (treats as empty / no-op).
_swarm_path() {
  : "${CEO_VAULT:?CEO_VAULT must be set to resolve the swarm path}"
  printf '%s\n' "$CEO_VAULT/CEO/swarm.json"
}
CEO_SWARM_SCHEMA_VERSION=1

# _swarm_resolve_host
#   Prints this host's swarm id on stdout. Prefers an explicit CEO_HOSTNAME;
#   falls back to `hostname -s`. Empty result is a fatal misconfiguration
#   (shell-required-env-vars: an empty id silently corrupts the swarm).
_swarm_resolve_host() {
  local host="${CEO_HOSTNAME:-$(hostname -s 2>/dev/null)}"
  : "${host:?cannot determine this host (CEO_HOSTNAME unset and 'hostname -s' returned empty)}"
  printf '%s\n' "$host"
}

# _swarm_bootstrap
#   Create swarm.json if absent: {"schema_version":1,"hosts":[],"owners":{}}.
#   Idempotent — an existing file (with its hosts[]/owners{}) is left untouched
#   so a re-run never clobbers peer-registered hosts or assigned owners.
_swarm_bootstrap() {
  local swarm_file; swarm_file=$(_swarm_path) || return 1
  [ -f "$swarm_file" ] && return 0
  mkdir -p "$(dirname "$swarm_file")"
  local tmp
  tmp=$(mktemp "$swarm_file.XXXXXX") || {
    echo "ERROR: mktemp failed for $swarm_file" >&2
    return 1
  }
  if ! jq -n --argjson v "$CEO_SWARM_SCHEMA_VERSION" \
        '{schema_version: $v, hosts: [], owners: {}}' > "$tmp" \
     || ! mv -f "$tmp" "$swarm_file"; then
    rm -f "$tmp"
    echo "ERROR: failed to write $swarm_file" >&2
    return 1
  fi
  return 0
}

# _swarm_register_host
#   Register this host into swarm.json hosts[]. Bootstraps the file first if
#   absent. Idempotent for an explicit CEO_HOSTNAME: re-registering an
#   already-present id is a safe no-op.
#
#   Collision guard (the safety invariant): a host can't know whether an
#   existing hosts[] entry is itself or a clone. When CEO_HOSTNAME is NOT
#   explicitly set and the bare `hostname -s` value already appears in
#   hosts[], the id is ambiguous — two machines could silently share it and
#   end up with double ownership of a single-scope playbook. Refuse with a
#   non-zero exit and instruct the user to set a unique CEO_HOSTNAME. An
#   explicit CEO_HOSTNAME is trusted: the user has asserted the id is unique,
#   so re-registering it is the safe no-op above, never a refusal.
_swarm_register_host() {
  _swarm_bootstrap || return 1
  local swarm_file; swarm_file=$(_swarm_path) || return 1
  local host; host=$(_swarm_resolve_host) || return 1

  local already_present
  already_present=$(jq -r --arg h "$host" '.hosts | index($h) != null' "$swarm_file" 2>/dev/null)

  if [ "$already_present" = "true" ]; then
    if [ -z "${CEO_HOSTNAME:-}" ]; then
      echo "ERROR: host id '$host' (from 'hostname -s') is already in swarm.json hosts[]." >&2
      echo "  Cannot tell whether that entry is this machine or a different one." >&2
      echo "  Set a unique CEO_HOSTNAME for this machine and re-run, e.g.:" >&2
      echo "    echo 'CEO_HOSTNAME=$host-2' >> ~/.ceo/config" >&2
      return 1
    fi
    return 0
  fi

  local tmp
  tmp=$(mktemp "$swarm_file.XXXXXX") || {
    echo "ERROR: mktemp failed for $swarm_file" >&2
    return 1
  }
  if ! jq --arg h "$host" '.hosts += [$h]' "$swarm_file" > "$tmp" \
     || ! mv -f "$tmp" "$swarm_file"; then
    rm -f "$tmp"
    echo "ERROR: failed to register host '$host' in $swarm_file" >&2
    return 1
  fi
  return 0
}

# _swarm_set_owner <name> <host>
#   Assign single-scope playbook <name> to <host> in swarm.json owners{}.
#   <host> must already be a registered member of hosts[] — refuse otherwise
#   so ownership can't point at a machine the swarm doesn't know. The jq
#   assignment `.owners[$n] = $h` REPLACES any prior owner: ownership is
#   single-host, so re-assigning overwrites rather than accumulating. Scope
#   validation (refusing `each` playbooks) is the caller's responsibility —
#   it owns the registry; this helper only knows the swarm.
_swarm_set_owner() {
  local name="${1:?_swarm_set_owner requires a playbook name}"
  local host="${2:?_swarm_set_owner requires a host}"
  _swarm_bootstrap || return 1
  local swarm_file; swarm_file=$(_swarm_path) || return 1

  local known
  known=$(jq -r --arg h "$host" '.hosts | index($h) != null' "$swarm_file" 2>/dev/null)
  if [ "$known" != "true" ]; then
    echo "ERROR: host '$host' is not registered in swarm.json hosts[]." >&2
    echo "  Known hosts: $(jq -r '.hosts | join(", ")' "$swarm_file" 2>/dev/null)" >&2
    echo "  Register it from that machine first (ceo setup), then assign." >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp "$swarm_file.XXXXXX") || {
    echo "ERROR: mktemp failed for $swarm_file" >&2
    return 1
  }
  if ! jq --arg n "$name" --arg h "$host" '.owners[$n] = $h' "$swarm_file" > "$tmp" \
     || ! mv -f "$tmp" "$swarm_file"; then
    rm -f "$tmp"
    echo "ERROR: failed to set owner '$host' for '$name' in $swarm_file" >&2
    return 1
  fi
  return 0
}
# shellcheck disable=SC2034
CEO_VALID_RUNNERS=(claude script ollama ollama-think skill)
# shellcheck disable=SC2034
CEO_VALID_STATUSES=(active draft disabled)
# Per-playbook fan-out scope. `single` runs the playbook once; `each` fans it
# out per target (consumed by the scheduler daemon). Absent defaults to the
# safe `single` — never coerce an unknown value to `each`.
# shellcheck disable=SC2034
CEO_VALID_SCOPES=(each single)

# ceo_status_valid <value>
#   Returns 0 if <value> is one of the supported statuses, 1 otherwise.
#   Empty string is treated as "not active" by the dispatcher but is NOT
#   accepted here — callers decide whether to allow missing/empty separately
#   from typos.
ceo_status_valid() {
  local v="${1:-}"
  for s in "${CEO_VALID_STATUSES[@]}"; do
    [ "$v" = "$s" ] && return 0
  done
  return 1
}

# ceo_registry_version <registry_file>
#   Prints the integer schema_version, or nothing if missing/malformed.
ceo_registry_version() {
  local registry_file="${1:-$(_ceo_registry_path)}"
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
#   2 — schema_version is a parseable integer below current (genuine downgrade
#       by a peer on an older binary; fail fast — retrying cannot fix it)
#   3 — registry exists but has no parseable integer schema_version (missing
#       field, malformed JSON, non-integer). On a synced vault this also covers
#       a file caught mid-replace, so callers should retry once before failing.
# Codes 2 and 3 are kept distinct so a real downgrade is never retried into
# acceptance and a transient unreadable read is never misreported as a downgrade.
ceo_registry_validate() {
  local registry_file="${1:-$(_ceo_registry_path)}"
  if [ ! -f "$registry_file" ]; then
    return 1
  fi
  local v
  v=$(ceo_registry_version "$registry_file")
  if [ -z "$v" ]; then
    return 3
  fi
  if [ "$v" -lt "$CEO_REGISTRY_SCHEMA_VERSION" ]; then
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ceo_artifact_expand <template> [host]
#   Expand a playbook artifact template into a vault-relative path. Templates
#   may reference {TODAY} (YYYY-MM-DD) and {HOST} (short hostname). Optional
#   second arg overrides the host (used by tests).
#
#   Prints the expanded path on stdout. Returns 0 on success, 1 if the
#   template is empty or contains an unknown {...} token (per the
#   enum-config-typo-fallback rule: reject unknown tokens, do not silently
#   coerce them to the empty string).
# ---------------------------------------------------------------------------
ceo_artifact_expand() {
  local template="${1:-}"
  local host="${2:-${CEO_HOSTNAME:-$(hostname -s 2>/dev/null || echo unknown)}}"
  [ -z "$template" ] && return 1
  local today
  today=$(date +%Y-%m-%d)
  local expanded="$template"
  expanded="${expanded//\{TODAY\}/$today}"
  expanded="${expanded//\{HOST\}/$host}"
  # After expanding known tokens, any remaining {...} is a typo or an
  # unsupported token — reject rather than emit a broken path.
  case "$expanded" in
    *\{*\}*)
      return 1
      ;;
  esac
  printf '%s\n' "$expanded"
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
  : "${HOME:?HOME must be set before ceo_pr_sources_path}"
  echo "$HOME/.ceo/pr-sources.json"
}

# _ceo_pr_sources_discover_gh_accounts — shared awk parse of `gh auth status`.
# Extracted because the reader-fallback path and the interactive setup path
# both need it; an earlier draft duplicated the awk verbatim. Prefers the
# newer `gh auth status --json` shape when present; falls back to scraping
# the human-readable output.
_ceo_pr_sources_discover_gh_accounts() {
  command -v gh &>/dev/null || return 0
  gh auth status &>/dev/null || return 0
  local raw accounts
  if raw=$(gh auth status --json 2>/dev/null) && [ -n "$raw" ] && command -v jq &>/dev/null; then
    accounts=$(echo "$raw" | jq -r '.. | objects | select(has("user")) | .user' 2>/dev/null | sort -u)
    [ -n "$accounts" ] && { printf '%s\n' "$accounts"; return 0; }
  fi
  raw=$(gh auth status 2>&1)
  accounts=$(printf '%s\n' "$raw" | awk '/account [a-zA-Z0-9_-]+/ {for(i=1;i<=NF;i++) if($i=="account") print $(i+1)}' | sort -u)
  if [ -z "$accounts" ]; then
    echo "WARN: gh auth status succeeded but no accounts parsed; gh output format may have drifted." >&2
    return 0
  fi
  printf '%s\n' "$accounts"
}

# ceo_pr_sources_github_accounts [path]
#   Echo one account name per line. Empty file/missing field → discover via
#   `gh auth status`. Empty stdout means "skip GitHub" to callers.
ceo_pr_sources_github_accounts() {
  local path="${1:-$(ceo_pr_sources_path)}"
  if [ -f "$path" ]; then
    if ! command -v jq &>/dev/null; then
      echo "WARN: $path exists but jq is not installed; falling back to gh discovery." >&2
    elif ! jq empty "$path" 2>/dev/null; then
      echo "WARN: $path is malformed JSON; falling back to gh discovery. Re-run 'ceo pr-sources' to rewrite." >&2
    else
      local accounts
      accounts=$(jq -r '.github.accounts // [] | .[]' "$path" 2>/dev/null)
      if [ -n "$accounts" ]; then
        printf '%s\n' "$accounts"
        return 0
      fi
    fi
  fi
  _ceo_pr_sources_discover_gh_accounts
}

# ceo_pr_sources_github_exclude_orgs [path] — one org per line.
ceo_pr_sources_github_exclude_orgs() {
  local path="${1:-$(ceo_pr_sources_path)}"
  [ -f "$path" ] || return 0
  command -v jq &>/dev/null || return 0
  jq empty "$path" 2>/dev/null || return 0
  # Drop names that aren't valid GitHub-org shape (alphanum + hyphen). Catches
  # newline/garbage that would silently collapse the exclude filter later.
  jq -r '.github.exclude_orgs // [] | .[] | select(test("^[A-Za-z0-9][A-Za-z0-9-]*$"))' "$path" 2>/dev/null
}

# ceo_pr_sources_gitlab_usernames [path]
#   One username per line. Empty file/missing field → discover via glab.
ceo_pr_sources_gitlab_usernames() {
  local path="${1:-$(ceo_pr_sources_path)}"
  if [ -f "$path" ]; then
    if command -v jq &>/dev/null && jq empty "$path" 2>/dev/null; then
      local users
      users=$(jq -r '.gitlab.usernames // [] | .[]' "$path" 2>/dev/null)
      if [ -n "$users" ]; then
        printf '%s\n' "$users"
        return 0
      fi
    fi
  fi
  if command -v glab &>/dev/null && glab auth status &>/dev/null; then
    glab api user 2>/dev/null | (command -v jq &>/dev/null && jq -r '.username // empty' || true)
  fi
}

# ceo_pr_sources_dedupe [path]
#   rc=0 if dedupe on (default); rc=1 only when explicitly set to false.
ceo_pr_sources_dedupe() {
  local path="${1:-$(ceo_pr_sources_path)}"
  # Three indistinguishable fallbacks below all return 0 (dedupe ON) on
  # purpose — dedupe is a non-safety filter and the safer default when the
  # config is unreadable is to dedupe rather than risk double-counting.
  # Sibling `ceo_assert_primary_host` fails closed because it gates writes;
  # do not mirror that pattern here.
  [ -f "$path" ] || return 0  # safety default: dedupe ON when no config
  command -v jq &>/dev/null || return 0  # safety default: dedupe ON without jq
  jq empty "$path" 2>/dev/null || return 0  # safety default: dedupe ON on malformed JSON
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

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required to write $path" >&2
    return 1
  fi

  # Stdin must be a tty — otherwise EOF on `read` leaves $ans empty and the
  # `case *)` default-to-Y branch would silently opt the user into every
  # discovered account. Skip with a clear message and let the user re-run.
  if [ ! -t 0 ]; then
    echo "  WARNING: stdin is not a tty — skipping interactive pr-sources setup." >&2
    echo "  Re-run from a terminal with: ceo pr-sources" >&2
    return 0
  fi

  local -a selected_accounts=()
  local discovered
  discovered=$(_ceo_pr_sources_discover_gh_accounts)
  if [ -n "$discovered" ]; then
    echo "  GitHub accounts discovered via gh auth status:"
    local acct ans
    while IFS= read -r acct; do
      [ -z "$acct" ] && continue
      printf "    Query PRs for '%s'? [Y/n] " "$acct"
      if ! read -r ans; then
        echo "" >&2
        echo "  WARNING: read returned EOF; treating remaining accounts as skipped." >&2
        break
      fi
      case "$ans" in
        n|N|no|No) ;;
        *) selected_accounts+=("$acct") ;;
      esac
    done <<< "$discovered"
  else
    echo "  WARNING: no GitHub accounts discoverable. Run 'gh auth login' then re-run 'ceo pr-sources'."
  fi

  local -a gitlab_users=()
  if command -v glab &>/dev/null && glab auth status &>/dev/null; then
    local gluser
    gluser=$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null)
    if [ -n "$gluser" ]; then
      local ans
      printf "    Query GitLab MRs for '%s'? [Y/n] " "$gluser"
      if read -r ans; then
        case "$ans" in
          n|N|no|No) ;;
          *) gitlab_users+=("$gluser") ;;
        esac
      fi
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
