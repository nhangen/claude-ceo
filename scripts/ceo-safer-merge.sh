#!/bin/bash
# ceo-safer-merge.sh — wrap `gh pr merge` so `--admin` refuses to land a PR
# whose head-commit checks are red.
#
# Background: PR #76 was merged with `gh pr merge --admin --merge` while the
# Tests workflow reported 9 failures. `--admin` is meant as an emergency
# escape hatch, not a way for agents to silently steamroll real failures.
#
# When --admin is present this wrapper requires one of:
#   1. PR head-SHA status checks all SUCCESS / NEUTRAL / SKIPPED / PENDING.
#   2. --admin-reason "<text>" with a non-trivial (>=10 char) reason,
#      logged to ~/.local/state/ceo-admin-merges.log.
#   3. CEO_ALLOW_RED_ADMIN_MERGE=1 in the environment.
#
# Without --admin the wrapper is a transparent passthrough to `gh pr merge`.

set -euo pipefail

: "${HOME:?HOME must be set before ceo-safer-merge.sh}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG_FILE="$LOG_DIR/ceo-admin-merges.log"

GH_BIN="${GH_BIN:-gh}"

usage() {
  cat >&2 <<EOF
Usage: ceo-safer-merge.sh <pr> [--admin-reason "<text>"] [gh pr merge flags]

Wrapper for \`gh pr merge\`. With --admin, requires one of:
  - head-SHA checks all SUCCESS / NEUTRAL / SKIPPED / PENDING, or
  - --admin-reason "<text>" (>=10 chars; logged to $LOG_FILE), or
  - CEO_ALLOW_RED_ADMIN_MERGE=1.
EOF
}

admin=0
admin_reason=""
pr_ref=""
gh_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --admin)
      admin=1
      gh_args+=("$1")
      shift
      ;;
    --admin-reason)
      admin_reason="${2:-}"
      shift 2
      ;;
    --admin-reason=*)
      admin_reason="${1#--admin-reason=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -z "$pr_ref" ] && [[ "$1" != -* ]]; then
        pr_ref="$1"
      fi
      gh_args+=("$1")
      shift
      ;;
  esac
done

if [ -z "$pr_ref" ]; then
  echo "ERROR: ceo-safer-merge: no PR specified" >&2
  usage
  exit 2
fi

if [ "$admin" -eq 0 ]; then
  exec "$GH_BIN" pr merge "${gh_args[@]}"
fi

log_admin_merge() {
  local reason="$1"
  mkdir -p "$LOG_DIR"
  local sha
  sha=$("$GH_BIN" pr view "$pr_ref" --json headRefOid -q .headRefOid 2>/dev/null || echo "unknown")
  printf '%s\tPR=%s\tSHA=%s\tREASON=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_ref" "$sha" "$reason" >> "$LOG_FILE"
}

if [ "${CEO_ALLOW_RED_ADMIN_MERGE:-0}" = "1" ]; then
  log_admin_merge "env:CEO_ALLOW_RED_ADMIN_MERGE"
  exec "$GH_BIN" pr merge "${gh_args[@]}"
fi

if [ -n "$admin_reason" ]; then
  trimmed="${admin_reason#"${admin_reason%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [ "${#trimmed}" -lt 10 ]; then
    echo "ERROR: ceo-safer-merge: --admin-reason must be at least 10 non-whitespace characters" >&2
    exit 3
  fi
  log_admin_merge "$trimmed"
  exec "$GH_BIN" pr merge "${gh_args[@]}"
fi

# Gate on PR head-SHA check status. statusCheckRollup mixes CheckRun
# (`.conclusion`) and StatusContext (`.state`) entries; SUCCESS / NEUTRAL /
# SKIPPED / PENDING are non-blocking, anything else (FAILURE / CANCELLED /
# TIMED_OUT / ACTION_REQUIRED / STARTUP_FAILURE / ERROR) blocks the merge.
checks_json=$("$GH_BIN" pr view "$pr_ref" --json statusCheckRollup -q '.statusCheckRollup' 2>/dev/null || echo "[]")

failing=$(printf '%s' "$checks_json" | jq -r '
  ( . // [] )[] |
  ( .conclusion // .state // "" ) as $c |
  select($c != "" and $c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED" and $c != "PENDING") |
  "  - \(.name // .context // "check"): \($c)"' 2>/dev/null || true)

if [ -n "$failing" ]; then
  cat >&2 <<EOF
REFUSED: ceo-safer-merge blocked \`gh pr merge --admin\` on PR $pr_ref —
head-SHA checks are failing:
$failing

To proceed, either fix the failing checks, re-run with
  --admin-reason "<at least 10 chars explaining why>"
or set CEO_ALLOW_RED_ADMIN_MERGE=1.
EOF
  exit 4
fi

exec "$GH_BIN" pr merge "${gh_args[@]}"
