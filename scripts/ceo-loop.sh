#!/usr/bin/env bash
# ceo-loop.sh — risk-routed worker/review/ticket/requeue loop (#329).
#
# Drives one work item end to end over a spec file:
#   queue -> overlap-serialized isolated worker -> tests -> heterogeneous
#   review panel -> finding fingerprint/dedup -> risk-gated promotion
#   (premium approval required for high-risk production-main) ->
#   deduplicated repair tickets with bounded requeue -> telemetry row.
#
# The worker/review commands come from the route table and spec, so a full
# dry-run exercises every gate with fixture commands and no providers.
#
# Usage: ceo-loop.sh run --spec <spec.json> --routes <routes.json>
#        ceo-loop.sh status --repo <repo-slug>
#
# Spec JSON fields:
#   repo          repo slug used for state namespacing
#   branch        isolated worker branch name
#   base          base revision the work was cut from
#   files         array of repo-relative paths the change touches
#   shape         task shape keyed in the routes table
#   verify_cmd    command that must exit 0 for the work to pass
#   author        provider/model of the worker that authored the change
#   reviewers     array of provider/model review panel entries
#   findings      array of {invariant, location, severity} from review
#
# Exit codes: 0 ok · 2 bad usage · 3 retries exhausted · 4 routing failure ·
# 5 review gate failure · 6 overlap conflict · 7 premium-gate block

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ceo-loop-lib.sh
source "$LIB_DIR/ceo-loop-lib.sh"
# shellcheck source=ceo-model-ledger.sh
source "$LIB_DIR/ceo-model-ledger.sh"

usage() {
  echo "usage: ceo-loop.sh run --spec <spec.json> --routes <routes.json> [--target <branch>] [--default-branch main]" >&2
  echo "       ceo-loop.sh status --repo <repo-slug>" >&2
  exit 2
}

cmd="${1:-}"; shift || true
case "$cmd" in
  run|status) ;;
  *) usage ;;
esac

SPEC="" ROUTES="" TARGET="main" DEFAULT_BRANCH="main" REPO_SLUG="" CURRENT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="$2"; shift 2 ;;
    --routes) ROUTES="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --current-base) CURRENT_BASE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

state_dir_for() {
  local slug="$1"
  ceo_loop_state_dir "$slug"
}

if [ "$cmd" = "status" ]; then
  [ -n "$REPO_SLUG" ] || usage
  dir="$(state_dir_for "$REPO_SLUG")"
  echo "state: $dir"
  for f in queue workers repair-tickets exhausted telemetry; do
    [ -f "$dir/$f.jsonl" ] && echo "--- $f ($(wc -l < "$dir/$f.jsonl" | tr -d ' '))" && cat "$dir/$f.jsonl"
  done
  exit 0
fi

[ -n "$SPEC" ] && [ -n "$ROUTES" ] || usage
[ -f "$SPEC" ] || { echo "ceo-loop: spec not found: $SPEC" >&2; exit 2; }
[ -f "$ROUTES" ] || { echo "ceo-loop: routes not found: $ROUTES" >&2; exit 2; }

jget() { jq -r "$1" "$SPEC"; }

require_field() { # <jq-path> <name>
  local v
  v="$(jget "$1")"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    echo "ceo-loop: spec is missing required field '$2' — refusing to guess" >&2
    exit 2
  fi
  printf '%s' "$v"
}
REPO="$(require_field '.repo' 'repo')"
BRANCH="$(require_field '.branch' 'branch')"
BASE="$(require_field '.base' 'base')"
SHAPE="$(jget '.shape // "bug-fix"')"
AUTHOR="$(require_field '.author' 'author')"
VERIFY_CMD="$(require_field '.verify_cmd' 'verify_cmd')"

mapfile -t SPEC_FILES < <(jq -r '.files[]?' "$SPEC")
if [ "${#SPEC_FILES[@]}" -eq 0 ] || [ -z "${SPEC_FILES[0]}" ]; then
  # An unserialized file list would fall through every risk rule to default —
  # exactly the degenerate input the map's fail-closed contract forbids.
  echo "ceo-loop: spec has no changed files — cannot classify risk" >&2
  exit 2
fi
DIR="$(state_dir_for "$REPO")"
mkdir -p "$DIR"
touch "$DIR/queue.jsonl" "$DIR/workers.jsonl" "$DIR/findings.jsonl" \
      "$DIR/repair-tickets.jsonl" "$DIR/telemetry.jsonl"

FINGERPRINTS_FILE=""
ceo_loop_cleanup() {
  # A dead or blocked run still frees its serialization slot: the work failed
  # but nobody else is writing those files through this loop anymore.
  [ -n "$FINGERPRINTS_FILE" ] && rm -f "$FINGERPRINTS_FILE" 2>/dev/null || true
  ceo_worker_release "$DIR" "$BRANCH" 2>/dev/null || true
}
# Installed BEFORE any registration so every early exit frees the slot.
trap ceo_loop_cleanup EXIT
START_TS="$(date +%s)"

# ── 1. queue ──────────────────────────────────────────────────────────────────
jq -c '{ts: (now | todate), repo: .repo, branch: .branch, base: .base, shape: (.shape // "bug-fix"), status: "queued"}' \
  "$SPEC" >> "$DIR/queue.jsonl"
echo "loop: queued $REPO/$BRANCH ($SHAPE)"

# ── 1b. stale base (#329 AC: conflicts stop promotion at the door) ────────────
if [ -n "$CURRENT_BASE" ] && ! ceo_base_stale "$BASE" "$CURRENT_BASE"; then
  echo "loop: STALE BASE — spec was cut from $BASE but the target is at $CURRENT_BASE. Rebase and resubmit." >&2
  exit 9
fi

# ── 2. route + isolated worker (overlap-serialized) ───────────────────────────
ROUTE="$(ceo_route_select "$ROUTES" "$SHAPE")"
PROVIDER="$(jq -r .provider <<<"$ROUTE")"
MODEL="$(jq -r .model <<<"$ROUTE")"
FILES=("${SPEC_FILES[@]}")
ceo_worker_register "$DIR" "$BRANCH" "$BASE" "${FILES[@]}" || exit $?
echo "loop: worker $PROVIDER/$MODEL on isolated branch $BRANCH (${#FILES[@]} files)"

WORKER_CMD="$(jq -r .command <<<"$ROUTE")"
if [ -n "$WORKER_CMD" ] && [ "$WORKER_CMD" != "null" ]; then
  # Worker commands receive the spec path; they own their own sandboxing.
  if ! SPEC="$SPEC" BRANCH="$BRANCH" BASE="$BASE" bash -c "$WORKER_CMD"; then
    echo "loop: worker failed — rerouting per policy" >&2
    NEXT_ROUTE="$(ceo_route_failover "$ROUTES" "$SHAPE" "$PROVIDER" "$MODEL")" || exit 4
    PROVIDER="$(jq -r .provider <<<"$NEXT_ROUTE")"
    MODEL="$(jq -r .model <<<"$NEXT_ROUTE")"
    WORKER_CMD="$(jq -r .command <<<"$NEXT_ROUTE")"
    echo "loop: rerouted to $PROVIDER/$MODEL"
    SPEC="$SPEC" BRANCH="$BRANCH" BASE="$BASE" bash -c "$WORKER_CMD" || {
      echo "loop: rerouted worker also failed — leaving actionable state in $DIR" >&2
      exit 4
    }
  fi
fi

# ── 3. tests / verification ───────────────────────────────────────────────────
TEST_RC=0
if [ -n "$VERIFY_CMD" ]; then
  if ! VERIFY_LOG="$("$VERIFY_CMD" 2>&1)"; then
    TEST_RC=1
    echo "loop: verification failed:" >&2
    printf '  %s\n' "$(printf '%s' "$VERIFY_LOG" | tail -3)" >&2
  fi
fi

# ── 4. heterogeneous review panel ─────────────────────────────────────────────
REVIEWERS_JSON="$(jq -r '(.reviewers // []) | join(" ")' "$SPEC")"
# shellcheck disable=SC2086
PASSING_REVIEWER="$(ceo_review_gate "$AUTHOR" $REVIEWERS_JSON)" \
  || { echo "loop: review gate failed" >&2; exit 5; }
echo "loop: review passed via cross-provider reviewer $PASSING_REVIEWER"

# ── 5. findings -> fingerprints -> deduplicated tickets ───────────────────────
FINGERPRINTS_FILE="$(mktemp "${TMPDIR:-/tmp}/ceo-loop-findings.XXXXXX")"
: > "$FINGERPRINTS_FILE"
CYCLE_FINDINGS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  INVARIANT="$(jq -r .invariant <<<"$f")"
  LOCATION="$(jq -r .location <<<"$f")"
  SEVERITY="$(jq -r .severity <<<"$f")"
  FP="$(ceo_finding_fingerprint "$REPO" "$BASE" "$INVARIANT" "$LOCATION" "$SEVERITY")"
  # Built by jq, never string-interpolated: reviewer strings may contain quotes.
  jq -cn --arg fp "$FP" --arg inv "$INVARIANT" --arg loc "$LOCATION" \
    --arg sev "$SEVERITY" --arg repo "$REPO" --arg base "$BASE" \
    '{fingerprint: $fp, invariant: $inv, location: $loc, severity: $sev,
      repo: $repo, base: $base}' >> "$DIR/findings.jsonl"
  TICKET_ID="$(ceo_ticket_dedup "$DIR" "$FP" "$INVARIANT at $LOCATION [$SEVERITY]")"
  CYCLE_FINDINGS=$((CYCLE_FINDINGS + 1))
  if grep -qxF "$TICKET_ID" "$FINGERPRINTS_FILE"; then
    echo "loop: duplicate finding collapsed onto existing ticket ${TICKET_ID:0:19}..."
  else
    echo "$TICKET_ID" >> "$FINGERPRINTS_FILE"
  fi
done < <(jq -c '.findings[]?' "$SPEC")

# ── 6. risk classification + promotion gate ───────────────────────────────────
RISK_MAP="$LIB_DIR/ceo-risk-map.json"
RISK="$(ceo_risk_classify "$RISK_MAP" "${FILES[@]}")"
PREMIUM_APPROVAL="${CEO_LOOP_PREMIUM_APPROVAL:-}"
if [ -n "$PREMIUM_APPROVAL" ]; then
  # Evidence, not existence: an empty or schema-less file must NOT unlock the
  # gate — a stray env var pointing at a log would otherwise promote HIGH risk.
  if ! jq -e '.approved_by and .ticket' "$PREMIUM_APPROVAL" >/dev/null 2>&1; then
    echo "loop: premium approval file lacks evidence (needs .approved_by and .ticket): $PREMIUM_APPROVAL" >&2
    exit 7
  fi
fi
ACTION=""
set +e
ACTION="$(CEO_LOOP_ALLOW_MAIN="${CEO_LOOP_ALLOW_MAIN:-0}" \
  ceo_promotion_gate "$RISK" "$TARGET" "$DEFAULT_BRANCH" "$PREMIUM_APPROVAL")"
GATE_RC=$?
set -e
if [ "$GATE_RC" -eq 7 ]; then
  echo "loop: BLOCKED — $RISK-risk change targeting production main '$TARGET' without premium approval." >&2
  echo "  Provide CEO_LOOP_PREMIUM_APPROVAL=<file> or retarget an integration branch." >&2
  exit 7
fi
if [ "$ACTION" = "park-integration" ]; then
  echo "loop: parking on integration branch (risk=$RISK, policy default until main promotion is enabled)"
fi

# ── 7. requeue on failing verification (bounded) ─────────────────────────────
FINAL_RC=0
if [ "$TEST_RC" -ne 0 ]; then
  while IFS= read -r tid; do
    OUT="$(ceo_requeue_decide "$DIR" "$tid" "${CEO_LOOP_MAX_RETRIES:-2}")" || RC_HERE=$?
    RC_HERE="${RC_HERE:-0}"
    case "$OUT" in
      retry:*) echo "loop: requeued as ticket ${tid:0:19}... ($OUT)" ;;
      exhausted) echo "loop: retries EXHAUSTED for ${tid:0:19}... — recorded in $DIR/exhausted.jsonl" ;;
    esac
    [ "$RC_HERE" -gt "$FINAL_RC" ] && FINAL_RC=$RC_HERE
    RC_HERE=0
  done < "$FINGERPRINTS_FILE"
fi

# ── 8. telemetry (token-scope ingestion contract) ─────────────────────────────
NOW_TS="$(date +%s)"
ACCEPTED=$([ "$TEST_RC" -eq 0 ] && [ "$GATE_RC" -eq 0 ] && echo true || echo false)
jq -nc \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO" --arg branch "$BRANCH" --arg model "$PROVIDER/$MODEL" \
  --arg target "$TARGET" --arg risk "$RISK" --arg action "$ACTION" \
  --argjson accepted "$ACCEPTED" \
  --argjson seconds_to_passing "$((NOW_TS - START_TS))" \
  --argjson findings "$CYCLE_FINDINGS" \
  --argjson reviewer_disagreement 0 \
  '{ts: $ts, writer: "ceo-loop", repo: $repo, branch: $branch, model: $model,
    target: $target, risk: $risk, action: $action, accepted: $accepted,
    seconds_to_passing: $seconds_to_passing, findings: $findings,
    reviewer_disagreement: $reviewer_disagreement}' >> "$DIR/telemetry.jsonl"

ceo_ledger_write_entry "ceo-loop" "$PROVIDER/$MODEL" "loop:$REPO/$BRANCH" "$PWD" null "$ACCEPTED" >/dev/null || true

echo "loop: done ($REPO/$BRANCH risk=$RISK action=$ACTION)"
exit $FINAL_RC
