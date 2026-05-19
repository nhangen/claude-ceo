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

# The skill script reads gh auth and ~/.cursor/mcp.json from $HOME.
ceo_pin_home_or_warn || true
ceo_augment_path

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

if ! "$SKILL" --out "$TMP_OUT" >/dev/null 2>&1; then
  echo "ERROR: workload-report skill failed" >&2
  exit 1
fi

SRC="$TMP_OUT/$TODAY-team.md"
if [ ! -s "$SRC" ]; then
  echo "ERROR: skill produced no output at $SRC" >&2
  exit 1
fi

mv "$SRC" "$REPORT_FILE"
echo "Wrote $REPORT_FILE"
