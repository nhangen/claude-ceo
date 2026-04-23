#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=blessings-lib.sh
source "$SCRIPT_DIR/blessings-lib.sh"

: "${CEO_VAULT:=$HOME/Documents/Obsidian}"
: "${CEO_DIR:=$CEO_VAULT/CEO}"
export CEO_VAULT CEO_DIR

BLESSINGS_FILE="$CEO_DIR/blessings.md"
CACHE_FILE="$CEO_DIR/cache/blessings-today.md"

usage() {
  cat <<EOF
usage: count-blessings <subcommand> [args]

subcommands:
  add "text"   append a blessing to the list
  list         show all blessings, numbered
  show         show today's three picks
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

ensure_blessings_file_exists() {
  if [[ ! -f "$BLESSINGS_FILE" ]]; then
    mkdir -p "$(dirname "$BLESSINGS_FILE")"
    printf -- '---\ntype: ea-blessings\n---\n\n' > "$BLESSINGS_FILE"
  fi
}

ensure_trailing_newline() {
  local f="$1"
  if [[ -s "$f" ]]; then
    local last
    last=$(tail -c1 "$f" | od -An -c | tr -d ' ')
    if [[ "$last" != "\\n" ]]; then
      printf '\n' >> "$f"
    fi
  fi
}

with_blessings_lock() {
  local lock="$BLESSINGS_FILE.lock.d"
  local tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries > 50 )); then
      die "could not acquire lock on $BLESSINGS_FILE"
    fi
    sleep 0.1
  done
  trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT
  "$@"
  rmdir "$lock" 2>/dev/null
  trap - EXIT
}

cmd_add() {
  local text="${1:-}"
  [[ -n "$text" ]]              || die "usage: count-blessings add \"text\""
  [[ "$text" != *$'\n'* ]]      || die "no newlines allowed in blessing text"
  [[ ${#text} -le 500 ]]        || die "entry too long (max 500 chars)"
  require_ceo_dir

  ensure_blessings_file_exists

  _do_add() {
    ensure_trailing_newline "$BLESSINGS_FILE"
    printf -- '- %s\n' "$text" >> "$BLESSINGS_FILE"
  }
  with_blessings_lock _do_add
}

cmd_list() {
  require_ceo_dir
  [[ -f "$BLESSINGS_FILE" ]] || return 0
  strip_frontmatter "$BLESSINGS_FILE" | grep '^- ' | nl -ba
}

cmd="${1:-}"
shift || true

case "$cmd" in
  add)    cmd_add "${1:-}" ;;
  list)   cmd_list ;;
  show)   die "not implemented" ;;
  repick) die "not implemented" ;;
  ""|-h|--help) usage; exit 0 ;;
  *)      usage >&2; exit 2 ;;
esac
