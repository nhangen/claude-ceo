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

cmd="${1:-}"
shift || true

case "$cmd" in
  add)    die "not implemented" ;;
  list)   die "not implemented" ;;
  show)   die "not implemented" ;;
  repick) die "not implemented" ;;
  ""|-h|--help) usage; exit 0 ;;
  *)      usage >&2; exit 2 ;;
esac
