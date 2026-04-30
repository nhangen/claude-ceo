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
#   ceo_registry_validate() — verifies registry.json schema_version; returns 0/1/2
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
# ceo_require_vault — load config; exit 1 with operator guidance if unresolved.
# For executed scripts only. Sourced scripts must call ceo_load_config and
# `return 1` on failure (exit would kill the caller's shell).
# ---------------------------------------------------------------------------
ceo_require_vault() {
  ceo_load_config && return 0
  echo "FATAL — CEO_VAULT unresolved. Run 'ceo setup' to initialize." >&2
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
  export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
  export _CEO_PATH_AUGMENTED=1
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

# ceo_registry_validate <registry_file>
#   0 — schema_version >= CEO_REGISTRY_SCHEMA_VERSION
#   1 — registry file does not exist
#   2 — schema_version missing or below current
ceo_registry_validate() {
  local registry_file="${1:-${CEO_DIR:-}/registry.json}"
  if [ ! -f "$registry_file" ]; then
    return 1
  fi
  local v
  v=$(jq -r '.schema_version // 0 | tonumber? // 0' "$registry_file" 2>/dev/null)
  [ -z "$v" ] && v=0
  if [ "$v" -lt "$CEO_REGISTRY_SCHEMA_VERSION" ] 2>/dev/null; then
    return 2
  fi
  return 0
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
