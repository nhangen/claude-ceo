#!/bin/bash
# blessings-lib.sh — shared helpers for count-blessings.sh and ceo-gather.sh.
# Source this file; do not execute directly.

require_ceo_dir() {
  : "${CEO_DIR:?CEO_DIR must be set}"
  [[ -d "$CEO_DIR" ]] || { printf 'CEO_DIR does not exist: %s\n' "$CEO_DIR" >&2; return 1; }
}

_BLESSINGS_STRIP_AWK='NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm'

strip_frontmatter() {
  # Strip YAML frontmatter if it opens on line 1. Portable across BSD and GNU awk.
  awk "$_BLESSINGS_STRIP_AWK" "$1"
}

strip_frontmatter_stdin() {
  # The same strip for a capped piped input, so a caller that bounds the file
  # read (head under gather's timeout shim, #606) can strip without a second
  # unbounded read of the file itself. `awk -` reads stdin per POSIX.
  awk "$_BLESSINGS_STRIP_AWK" -
}

# _blessings_bound <cmd...> — bound a vault-mount read with gather's timeout shim
# when one is in scope, run it unbounded where none is (`ceo blessings`
# standalone reads its own file interactively). The shim is not exported on
# purpose: only the sourcing shell sees it, and its absence legitimately means
# "no wall-clock policy applies here".
_blessings_bound() {
  if command -v _CEO_TIMEOUT >/dev/null 2>&1; then
    _CEO_TIMEOUT "${CEO_VAULT_TIMEOUT:-10}" "$@"
  else
    "$@"
  fi
}

ensure_blessings_cache() {
  require_ceo_dir || return 1
  local src="$CEO_DIR/blessings.md"
  local cache="$CEO_DIR/cache/blessings-today.md"
  local today; today=$(date +%Y-%m-%d)

  mkdir -p "$CEO_DIR/cache"

  # Both cache reads below are bounded when a timeout shim is in scope — the
  # head-of-cache freshness check and the src pool read sit directly on the vault
  # mount, so a stalled mount must degrade here rather than hang the tick (#606).
  # Where no shim is in scope (count-blessings.sh standalone) they run as usual.
  if [[ -f "$cache" ]] && _blessings_bound head -3 "$cache" 2>/dev/null | grep -q "^date: $today\$"; then
    return 0
  fi

  local tmp
  if [[ ! -f "$src" ]]; then
    tmp=$(mktemp "$cache.tmp.XXXXXX")
    printf -- '---\ndate: %s\n---\n' "$today" > "$tmp"
    mv -f "$tmp" "$cache"
    return 0
  fi

  # Shuffle fully, then take 3 from a here-string. `… | cut -f2- | head -3` SIGPIPEs
  # cut once the shuffled pool passes the pipe buffer (~400 entries), and pipefail
  # promotes 141 to this bare assignment — which aborts count-blessings.sh's
  # cmd_repick *after* it has already rm -f'd the cache, losing it with no output.
  # ceo-gather.sh's caller happens to survive only because it uses `|| true`.
  # The upstream head caps the src read at 2000 lines, which the pool never
  # reaches through `strip_frontmatter_stdin` — the cap is against a runaway or
  # stalled read, not the pool size (#606).
  # A timed-out read (124-126) returns without touching the cache: writing the
  # empty pool would stamp today's date on a blessing-less file and the freshness
  # check above would keep it for the rest of the day.
  local picks pool pool_rc=0
  pool=$(set -o pipefail; _blessings_bound head -2000 "$src" \
    | strip_frontmatter_stdin \
    | { grep '^- ' || true; } \
    | awk 'BEGIN{srand()} {print rand()"\t"$0}' \
    | sort -k1,1n \
    | cut -f2-) || pool_rc=$?
  case "$pool_rc" in
    124|125|126)
      echo "blessings: pool read failed (rc=$pool_rc); cache left unchanged" >&2
      return 1
      ;;
  esac
  picks=$(head -3 <<< "$pool")

  tmp=$(mktemp "$cache.tmp.XXXXXX")
  {
    printf -- '---\ndate: %s\n---\n' "$today"
    if [[ -n "$picks" ]]; then
      printf '%s\n' "$picks"
    fi
  } > "$tmp"
  mv -f "$tmp" "$cache"
}
