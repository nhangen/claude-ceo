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
  : # filled in Task 4
}
