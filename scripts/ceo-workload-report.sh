#!/bin/bash
# ceo-workload-report.sh — Twice-weekly Zenhub team workload report.
# Writes a dated snapshot to CEO/reports/workload/<TODAY>-<host>.md.
# Per-host filenames keep two Syncthing peers from racing on the same path.
# No inbox line — workload is reference, not an actionable task.
#
# Invoked by ceo-cron.sh when the workload-report playbook (runner:script) fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }

# `set -u` does not catch HOME="" (set-but-empty); guard before any helper
# that reads $HOME. Same shape as ceo-value-tracker.sh (PR #11 fix).
: "${HOME:?HOME must be set}"

# The skill script reads gh auth and ~/.cursor/mcp.json from $HOME.
ceo_pin_home_or_warn || true
ceo_augment_path

# Verify $HOME actually resolves to a directory holding the MCP config the
# skill will need. Catches launchd's $HOME=/var/root and cron-stripped env.
if [ ! -f "$HOME/.cursor/mcp.json" ]; then
  echo "ERROR: $HOME/.cursor/mcp.json not found — \$HOME may be wrong" >&2
  exit 1
fi

: "${CEO_VAULT:?CEO_VAULT must be set}"
VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"
WORKLOAD_DIR="$CEO_DIR/reports/workload"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$WORKLOAD_DIR/$TODAY-$HOST.md"

mkdir -p "$WORKLOAD_DIR"

SKILL="$HOME/.claude/skills/workload-report/scripts/run-report.sh"
if [ ! -x "$SKILL" ]; then
  echo "ERROR: workload-report skill not found at $SKILL" >&2
  exit 1
fi

# Skill writes <date>-team.md into --out. Rename to include host so two
# peers (Mac + ML-1) can run independently without clobbering each other.
TMP_OUT=$(mktemp -d)
trap 'rm -rf "$TMP_OUT"' EXIT

if ! "$SKILL" --out "$TMP_OUT" >/dev/null; then
  echo "ERROR: workload-report skill failed" >&2
  exit 1
fi

# Don't hardcode the skill's filename — across-midnight TZ skew between
# wrapper $TODAY and the skill's own `date` call would leave the file under
# yesterday's name and make us bail as if no output existed. Glob instead.
shopt -s nullglob
MD_FILES=("$TMP_OUT"/*.md)
shopt -u nullglob
if [ "${#MD_FILES[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one .md in $TMP_OUT, got ${#MD_FILES[@]}" >&2
  exit 1
fi
SRC="${MD_FILES[0]}"
if [ ! -s "$SRC" ]; then
  echo "ERROR: skill produced empty output at $SRC" >&2
  exit 1
fi

# The skill emits frontmatter + headers unconditionally, so -s passes even
# when Zenhub returned zero items (wrong workspace ID, auth-OK-no-data, etc).
# Bullet rows start with "- **" — absence means a header-only report.
if ! grep -q '^- \*\*' "$SRC"; then
  echo "WARN: skill produced report with no assignee rows — auth/workspace misconfig?" >&2
fi

mv "$SRC" "$REPORT_FILE"
echo "Wrote $REPORT_FILE"
