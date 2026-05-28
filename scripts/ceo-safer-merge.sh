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

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: ceo-safer-merge: jq is required but not on PATH" >&2
  exit 5
}

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

# Help is allowed without a PR ref.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# `pr_ref` MUST be the first positional. Parsing `--repo OWNER/NAME 87 ...`
# instead of `87 --repo OWNER/NAME ...` previously captured the `OWNER/NAME`
# slug as the PR ref (no awareness of value-taking options); making the PR
# ref a required leading positional is the smallest fix.
if [ $# -eq 0 ] || [[ "${1:-}" == -* ]]; then
  echo "ERROR: ceo-safer-merge: first argument must be the PR ref (number, URL, or branch)" >&2
  usage
  exit 2
fi
pr_ref="$1"
shift
gh_args+=("$pr_ref")

while [ $# -gt 0 ]; do
  case "$1" in
    --admin)
      admin=1
      gh_args+=("$1")
      shift
      ;;
    --admin-reason)
      admin_reason="${2:-}"
      if [[ "$admin_reason" == --* ]]; then
        echo "ERROR: ceo-safer-merge: --admin-reason requires a value (got '$admin_reason')" >&2
        exit 3
      fi
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
      gh_args+=("$1")
      shift
      ;;
  esac
done

if [ -n "$admin_reason" ] && [ "$admin" -eq 0 ]; then
  echo "ERROR: ceo-safer-merge: --admin-reason requires --admin" >&2
  exit 2
fi

if [ "$admin" -eq 0 ]; then
  exec "$GH_BIN" pr merge "${gh_args[@]}"
fi

log_admin_merge() {
  local reason="$1"
  mkdir -p "$LOG_DIR"
  local sha sha_err
  if ! sha=$("$GH_BIN" pr view "$pr_ref" --json headRefOid -q .headRefOid 2>&1); then
    sha_err="$sha"
    echo "ERROR: ceo-safer-merge: could not resolve head SHA for PR $pr_ref; refusing override (audit log would be incomplete)" >&2
    echo "$sha_err" >&2
    exit 5
  fi
  # Sanitize: tab/newline in the reason would break the TSV log format.
  reason=$(printf '%s' "$reason" | tr '\t\n' '  ')
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

# Gate on PR head-SHA check status. Fail closed: any failure to fetch or
# parse the rollup refuses the merge — silently coercing the lookup error
# into "[]" was the very bypass channel this wrapper exists to prevent.
# statusCheckRollup mixes CheckRun (`.conclusion`) and StatusContext
# (`.state`) entries; SUCCESS / NEUTRAL / SKIPPED / PENDING are non-blocking,
# anything else (FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED /
# STARTUP_FAILURE / ERROR) blocks the merge.
if ! checks_json=$("$GH_BIN" pr view "$pr_ref" --json statusCheckRollup -q '.statusCheckRollup' 2>&1); then
  echo "ERROR: ceo-safer-merge: could not read check status for PR $pr_ref; refusing --admin merge" >&2
  echo "$checks_json" >&2
  exit 5
fi

if ! failing=$(printf '%s' "$checks_json" | jq -r '
  ( . // [] )[] |
  ( .conclusion // .state // "" ) as $c |
  select($c != "" and $c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED" and $c != "PENDING") |
  "  - \(.name // .context // "check"): \($c)"'); then
  echo "ERROR: ceo-safer-merge: failed to parse statusCheckRollup; refusing --admin merge" >&2
  exit 5
fi

if ! rollup_count=$(printf '%s' "$checks_json" | jq -r '( . // [] ) | length'); then
  echo "ERROR: ceo-safer-merge: failed to count statusCheckRollup; refusing --admin merge" >&2
  exit 5
fi
if [ "$rollup_count" = "0" ]; then
  cat >&2 <<EOF
REFUSED: ceo-safer-merge blocked \`gh pr merge --admin\` on PR $pr_ref —
no checks reported on the head SHA. The wrapper cannot distinguish "all
green" from "no signal" (broken workflow file, missing CI registration).

To proceed, re-run with --admin-reason "<at least 10 chars>" or set
CEO_ALLOW_RED_ADMIN_MERGE=1 if you've verified the absence is intentional.
EOF
  exit 4
fi

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
