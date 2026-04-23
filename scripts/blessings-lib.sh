# blessings-lib.sh — shared helpers for count-blessings.sh and ceo-gather.sh.
# Source this file; do not execute directly.

require_ceo_dir() {
  : "${CEO_DIR:?CEO_DIR must be set}"
  [[ -d "$CEO_DIR" ]] || { printf 'CEO_DIR does not exist: %s\n' "$CEO_DIR" >&2; return 1; }
}

strip_frontmatter() {
  # Strip YAML frontmatter if it opens on line 1. Portable across BSD and GNU awk.
  awk 'NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm' "$1"
}

ensure_blessings_cache() {
  require_ceo_dir || return 1
  local src="$CEO_DIR/blessings.md"
  local cache="$CEO_DIR/cache/blessings-today.md"
  local today; today=$(date +%Y-%m-%d)

  mkdir -p "$CEO_DIR/cache"

  if [[ -f "$cache" ]] && head -3 "$cache" | grep -q "^date: $today\$"; then
    return 0
  fi

  if [[ ! -f "$src" ]]; then
    local tmp="$cache.tmp.$$"
    printf -- '---\ndate: %s\n---\n' "$today" > "$tmp"
    mv -f "$tmp" "$cache"
    return 0
  fi

  local picks
  picks=$(strip_frontmatter "$src" \
    | { grep '^- ' || true; } \
    | awk 'BEGIN{srand()} {print rand()"\t"$0}' \
    | sort -k1,1n \
    | cut -f2- \
    | head -3)

  local tmp="$cache.tmp.$$"
  {
    printf -- '---\ndate: %s\n---\n' "$today"
    if [[ -n "$picks" ]]; then
      printf '%s\n' "$picks"
    fi
  } > "$tmp"
  mv -f "$tmp" "$cache"
}
