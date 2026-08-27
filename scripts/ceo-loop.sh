#!/usr/bin/env bash
# ceo-loop.sh — risk-routed worker/review/ticket/requeue loop (#329).
#
# Runs one work item through the real workflow: an isolated git branch in a
# dedicated worktree cut from the target's current revision, a worker command
# routed from the route table executing inside that worktree, the changed-file
# list derived from the actual diff (never trusted from the caller), reviewer
# commands that execute and produce findings, a premium gate whose approval is
# cryptographically bound to this change set, promotion as a pushed branch/PR
# or a parked integration ref, and bounded requeue that dispatches further
# worker attempts before recording exhaustion.
#
# Usage:
#   ceo-loop.sh run --spec <spec.json> --routes <routes.json> [--target <branch>]
#                   [--current-base <sha>] [--dry-run]
#   ceo-loop.sh status --repo <repo-slug>
#
# Spec JSON fields:
#   repo        state-namespacing slug
#   repo_dir    path to the target git repository (required)
#   branch      isolated worker branch name; must satisfy
#               `git check-ref-format` and must not begin with '-'
#   base        base revision (default: current sha of the target branch)
#   verify_cmd  REQUIRED command run inside the worktree; must exit 0
#   files       optional declared file intents for early overlap checks —
#               the authoritative list always comes from the diff
#
# Route table per task shape:
#   "candidates": [ {provider, model, command} ... ]   # first live one wins
#   "reviewers":  [ {provider, model, command} ... ]   # ALL run; each prints
#                                                      # findings as JSONL
# Worker/reviewer commands receive WT (worktree), SPEC, BASE in their env.
#
# Exit codes: 0 ok · 2 bad usage / invalid spec · 3 retries exhausted ·
# 4 routing failure · 5 review gate failure ·
# 6 overlap, branch not owned, uncommittable worker output, or corrupt state ·
# 7 premium-gate block · 8 lock contention · 9 stale base

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ceo-loop-lib.sh
source "$LIB_DIR/ceo-loop-lib.sh"
# shellcheck source=ceo-model-ledger.sh
source "$LIB_DIR/ceo-model-ledger.sh"

DRY_RUN=0
usage() {
  echo "usage: ceo-loop.sh run --spec <spec.json> --routes <routes.json> [--target <branch>] [--current-base <sha>] [--dry-run]" >&2
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
    --dry-run) echo "ceo-loop: --dry-run was removed; the loop runs against a real git repository — point --spec at a fixture repo instead" >&2; exit 2 ;;
    *) usage ;;
  esac
done

state_dir_for() { ceo_loop_state_dir "$1"; }

if [ "$cmd" = "status" ]; then
  [ -n "$REPO_SLUG" ] || usage
  dir="$(state_dir_for "$REPO_SLUG")"
  echo "state: $dir"
  for f in queue workers repair-tickets exhausted telemetry; do
    if [ -f "$dir/$f.jsonl" ]; then
      echo "--- $f ($(wc -l < "$dir/$f.jsonl" | tr -d ' '))"
      cat "$dir/$f.jsonl"
    fi
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
valid_ref_name() { # <ref-name>
  local r="$1"
  # The branch name becomes both a git ref and a filesystem path, so it is
  # validated before either is built from it. `check-ref-format` is the authority
  # and covers the case that mattered: ".." reached the slash collapse below, WT
  # resolved to $REPO_DIR, and the reclaim's `rm -rf` aimed at the repository root
  # (#332). The one thing it accepts and should not is a leading dash — today only
  # `checkout -b` happens to refuse that, and every other interpolation of the ref
  # would read it as an option, so it is rejected here rather than left to luck.
  if ! git check-ref-format "refs/heads/$r" 2>/dev/null \
     || case "$r" in -*) true ;; *) false ;; esac; then
    echo "ceo-loop: '$r' is not a valid git branch name — refusing to build a ref or a worktree path from it" >&2
    exit 2
  fi
}
valid_ref_name "$TARGET"
valid_ref_name "$DEFAULT_BRANCH"

REPO="$(require_field '.repo' 'repo' | tr '/' '-')" # keep state paths one level deep
BRANCH="$(require_field '.branch' 'branch')"
valid_ref_name "$BRANCH"
SHAPE="$(jget '.shape // "bug-fix"')"
VERIFY_CMD="$(require_field '.verify_cmd' 'verify_cmd')"

# Real git mechanics need a real repository (#329 audit: nothing was created).
if [ "$DRY_RUN" != "1" ]; then
  REPO_DIR="$(require_field '.repo_dir' 'repo_dir')"
  [ -d "$REPO_DIR/.git" ] || [ "$(git -C "$REPO_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ] \
    || { echo "ceo-loop: repo_dir is not a git repository: $REPO_DIR" >&2; exit 2; }
else
  REPO_DIR="$(jget '.repo_dir // ""')"
fi

DIR="$(state_dir_for "$REPO")"
mkdir -p "$DIR"
touch "$DIR/queue.jsonl" "$DIR/workers.jsonl" "$DIR/findings.jsonl" \
      "$DIR/repair-tickets.jsonl" "$DIR/exhausted.jsonl" "$DIR/telemetry.jsonl"

FINGERPRINTS_FILE=""
FINDINGS_TMP=""
WT=""
ceo_loop_cleanup() {
  [ -n "$FINGERPRINTS_FILE" ] && rm -f "$FINGERPRINTS_FILE" 2>/dev/null || true
  [ -n "$FINDINGS_TMP" ] && rm -f "$FINDINGS_TMP" 2>/dev/null || true
  # A dead or blocked run frees its serialization slot but LEAVES the worktree
  # and branch for inspection — deleting evidence of what a worker did would
  # hide the very state a repair ticket needs.
  [ -n "$WT" ] && ceo_worker_release "$DIR" "$BRANCH" 2>/dev/null || true
}
trap ceo_loop_cleanup EXIT
START_TS="$(date +%s)"

# ── 1. queue + base resolution ────────────────────────────────────────────────
jq -c '{ts: (now | todate), repo: .repo, branch: .branch, shape: (.shape // "bug-fix"), status: "queued"}' \
  "$SPEC" >> "$DIR/queue.jsonl"
echo "loop: queued $REPO/$BRANCH ($SHAPE)"

if [ "$DRY_RUN" = "1" ]; then
  BASE="$(jget '.base // "main"')"
  if [ -n "$CURRENT_BASE" ] && ! ceo_base_stale "$BASE" "$CURRENT_BASE"; then
    echo "loop: STALE BASE — spec was cut from $BASE but the target is at $CURRENT_BASE. Rebase and resubmit." >&2
    exit 9
  fi
else
  if [ -z "$CURRENT_BASE" ]; then
    CURRENT_BASE="$(git -C "$REPO_DIR" rev-parse --verify "$TARGET" 2>/dev/null || \
                    git -C "$REPO_DIR" rev-parse --verify "origin/$TARGET" 2>/dev/null || true)"
    [ -n "$CURRENT_BASE" ] || { echo "ceo-loop: cannot resolve target '$TARGET' in $REPO_DIR" >&2; exit 9; }
  fi
  BASE="$(jget '.base // ""')"
  [ -n "$BASE" ] || BASE="$CURRENT_BASE"
  if ! ceo_base_stale "$BASE" "$CURRENT_BASE"; then
    echo "loop: STALE BASE — spec was cut from $BASE but $TARGET is at $CURRENT_BASE. Rebase and resubmit." >&2
    exit 9
  fi
fi

# ── 2. routing with full-candidate failover ───────────────────────────────────
mapfile -t CANDIDATES < <(jq -c '.candidates[]' "$ROUTES" 2>/dev/null | grep -v '^$' || true)
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  # Flat fallback: legacy shape where candidates sit under .routes.<shape>.
  mapfile -t CANDIDATES < <(jq -c --arg s "$SHAPE" '.routes[$s][]' "$ROUTES" 2>/dev/null | grep -v '^$' || true)
fi
[ "${#CANDIDATES[@]}" -gt 0 ] || {
  echo "ceo-route: no candidate configured for task shape '$SHAPE' in $ROUTES" >&2
  exit 4
}

run_worker_attempt() { # <candidate-json> — echoes "provider/model" on success
  local cand="$1"
  local provider model wcmd
  provider="$(jq -r .provider <<<"$cand")"
  model="$(jq -r .model <<<"$cand")"
  wcmd="$(jq -r '.command // ""' <<<"$cand")"
  if [ -n "$wcmd" ] && [ "$wcmd" != "null" ]; then
    if ! WT="$WT" SPEC="$SPEC" BASE="$BASE" REPO_DIR="$REPO_DIR" bash -c "$wcmd"; then
      return 1
    fi
  fi
  echo "$provider/$model"
}

# ── 3. isolated worktree + worker with bounded requeue across candidates ─────
MAX_RETRIES="${CEO_LOOP_MAX_RETRIES:-2}"
ATTEMPT=0
WORKER_IDENTITY=""
TEST_RC=1
VERIFY_LOG=""
# One key per branch name, used for both the ownership ref and the worktree
# directory. Keying either on the name itself is what produced two bugs: a ref
# namespace cannot hold "topic" and "topic/sub" at once, and collapsing "/" to
# "_" made nh/loop-x and the literal nh_loop-x share one worktree, so the second
# run evicted the first run's checkout.
BRANCH_KEY="$(branch_key "$BRANCH")"

if [ "$DRY_RUN" != "1" ]; then
  WT="$REPO_DIR/.ceo-loop/${BRANCH//\//_}-${BRANCH_KEY:0:12}"
  OWNED_REF="refs/ceo-loop/owned/$BRANCH_KEY"
  # The marker records the tip it vouches for, and is re-pointed every time the
  # loop advances the branch. Existence alone is not ownership: a name freed by
  # a merge and later reused by a person left the old marker standing, and the
  # loop deleted their work on the strength of it. A tip that does not match is
  # somebody else's commit, whoever made it.
  ceo_claim_branch() {
    git -C "$REPO_DIR" update-ref "$OWNED_REF" "$(git -C "$WT" rev-parse HEAD)" \
      || { echo "ceo-loop: could not record ownership of $BRANCH" >&2; exit 6; }
  }
  BRANCH_TIP="$(git -C "$REPO_DIR" rev-parse --verify -q "refs/heads/$BRANCH" 2>/dev/null || true)"
  OWNED_TIP="$(git -C "$REPO_DIR" rev-parse --verify -q "$OWNED_REF" 2>/dev/null || true)"
  if [ -z "$BRANCH_TIP" ]; then
    # No branch: a marker left behind by an earlier run vouches for nothing, and
    # keeping it is what let the next holder of the name be deleted.
    [ -z "$OWNED_TIP" ] || git -C "$REPO_DIR" update-ref -d "$OWNED_REF" 2>/dev/null || true
  elif [ "$BRANCH_TIP" != "$OWNED_TIP" ]; then
    if [ -z "$OWNED_TIP" ]; then
      echo "ceo-loop: branch $BRANCH already exists and was not created by ceo-loop — refusing to delete it." >&2
    else
      echo "ceo-loop: branch $BRANCH has moved since ceo-loop last wrote it ($OWNED_TIP -> $BRANCH_TIP) — refusing to delete it." >&2
    fi
    echo "  Choose a different .branch in the spec, or delete the branch yourself if it is disposable." >&2
    exit 6
  fi
  # Reclaim leftovers from prior attempts: deregister the worktree first
  # (a branch checked out in a registered worktree cannot be deleted), prune,
  # then drop the loop-owned branch.
  git -C "$REPO_DIR" worktree remove --force --force "$WT" 2>/dev/null || true
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT"
  git -C "$REPO_DIR" branch -D "$BRANCH" 2>/dev/null || true
  git -C "$REPO_DIR" worktree add --detach "$WT" "$CURRENT_BASE" >/dev/null 2>&1 \
    || { echo "ceo-loop: could not create isolated worktree at $WT" >&2; exit 6; }
  git -C "$WT" checkout -b "$BRANCH" "$CURRENT_BASE" >/dev/null 2>&1 \
    || { echo "ceo-loop: could not create branch $BRANCH" >&2; exit 6; }
  # Claim it in the same step that creates it, so a run killed later still
  # leaves a branch the next run is allowed to reclaim.
  ceo_claim_branch
fi

# Early registration with declared intent (if any) so concurrent loops on the
# same repo serialize before doing work; replaced by diff-derived files below.
mapfile -t DECLARED_FILES < <(jq -r '.files[]?' "$SPEC" 2>/dev/null || true)
if [ "${#DECLARED_FILES[@]}" -gt 0 ] && [ -n "${DECLARED_FILES[0]}" ]; then
  ceo_worker_register "$DIR" "$BRANCH" "$CURRENT_BASE" "${DECLARED_FILES[@]}" || exit $?
fi

while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
  CAND_IDX=0
  WORKER_IDENTITY=""
  TEST_RC=1
  while [ "$CAND_IDX" -lt "${#CANDIDATES[@]}" ]; do
    CAND="${CANDIDATES[$CAND_IDX]}"
    PROVIDER="$(jq -r .provider <<<"$CAND")"
    MODEL="$(jq -r .model <<<"$CAND")"
    echo "loop: attempt $((ATTEMPT + 1)): worker $PROVIDER/$MODEL on isolated branch $BRANCH"
    if IDENT="$(run_worker_attempt "$CAND")"; then
      WORKER_IDENTITY="$IDENT"
      break
    fi
    echo "loop: worker $PROVIDER/$MODEL failed — trying next candidate" >&2
    CAND_IDX=$((CAND_IDX + 1))
  done
  if [ -z "$WORKER_IDENTITY" ]; then
    echo "loop: every routed candidate failed — actionable state left in $DIR and ${WT:-<dry-run>}" >&2
    exit 4
  fi

  if [ "$DRY_RUN" != "1" ]; then
    # The loop owns committing whatever the worker left behind, so the diff
    # (and therefore the file list) is fully observable.
    # Neither of these is optional, and the reason is one invariant rather than
    # two commands: FILES below comes from `git diff --name-only` against the
    # WORKING TREE, so any path that leaves the worker's output uncommitted has
    # risk classification, the reviewers, and the promotion summary all reading
    # a change the branch does not hold — and the run then reports "holds
    # accepted work" over an empty branch.
    #
    # A failed `add` is the subtler half: nothing is staged, so the commit block
    # below is skipped entirely and takes its own refusal with it. A wedged
    # index.lock does it, which is exactly what a concurrent git in the same
    # worktree leaves behind.
    git -C "$WT" add -A >/dev/null 2>&1 \
      || { echo "ceo-loop: could not stage the worker's output in $WT — refusing to report work the branch does not hold" >&2; exit 6; }
    if ! git -C "$WT" diff --cached --quiet 2>/dev/null; then
      # A rejected commit is the other half — a repo-level pre-commit hook
      # reaches here, since worktrees share $REPO_DIR/.git/hooks.
      git -C "$WT" commit -q -m "ceo-loop: worker output ($WORKER_IDENTITY)" \
        || { echo "ceo-loop: could not commit the worker's output on $BRANCH — it is uncommitted in $WT and the next reclaim would discard it" >&2; exit 6; }
      # The marker tracks the tip, so it has to follow every commit the loop
      # makes or the next run reads its own work as a stranger's.
      ceo_claim_branch
    fi
  fi

  # Verification runs INSIDE the worktree via bash -c so multiword commands
  # ("npm test", "make check") are shell input, not one executable name.
  VERIFY_LOG="$([ "$DRY_RUN" = "1" ] && echo "" ; cd "$WT" 2>/dev/null || cd "$REPO_DIR"; bash -c "$VERIFY_CMD" 2>&1)" && TEST_RC=0 || TEST_RC=1
  if [ "$TEST_RC" -ne 0 ]; then
    echo "loop: verification failed:" >&2
    printf '  %s\n' "$(printf '%s' "$VERIFY_LOG" | tail -3)" >&2
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -le "$MAX_RETRIES" ] && continue
    break
  fi
  break
done

FILES=()
HIGH_FINDINGS=0
if [ "$DRY_RUN" != "1" ]; then
  # Authoritative file list: the actual diff against the base revision.
  mapfile -t FILES < <(git -C "$WT" diff --name-only "$CURRENT_BASE" 2>/dev/null | grep -v '^$' || true)
fi
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "ceo-loop: no changed files after the worker ran — cannot classify risk" >&2
  exit 2
fi
ceo_worker_register "$DIR" "$BRANCH" "$CURRENT_BASE" "${FILES[@]}" || exit $?

# ── 4. reviewers EXECUTE and produce the findings (#329 audit) ────────────────
mapfile -t REVIEWER_ENTRIES < <(jq -c '.reviewers[]' "$ROUTES" 2>/dev/null | grep -v '^$' || true)
AUTHOR_PROVIDER="${WORKER_IDENTITY%%/*}"
PASSING_REVIEWER=""
FINDINGS_TMP="$(mktemp "${TMPDIR:-/tmp}/ceo-loop-findings.XXXXXX")"
FINGERPRINTS_FILE="$(mktemp "${TMPDIR:-/tmp}/ceo-loop-fingerprints.XXXXXX")"
: > "$FINDINGS_TMP"
: > "$FINGERPRINTS_FILE"
for rentry in "${REVIEWER_ENTRIES[@]}"; do
  rprov="$(jq -r .provider <<<"$rentry")"
  rmodel="$(jq -r .model <<<"$rentry")"
  rcmd="$(jq -r '.command // ""' <<<"$rentry")"
  [ -n "$rcmd" ] && [ "$rcmd" != "null" ] || continue
  if ROUT="$(WT="$WT" SPEC="$SPEC" BASE="$BASE" DIFF="$(git -C "$WT" diff "$CURRENT_BASE" 2>/dev/null || true)" bash -c "$rcmd" 2>&1)"; then
    # A review that ran must have SAID something parseable: findings, or an
    # explicit {"status":"clean"} acknowledgement (which is not itself a
    # finding and never reaches the ticket pipeline). Empty or unparseable
    # output is a broken review, not a clean one.
    if printf '%s\n' "$ROUT" | jq -e '.status == "clean"' >/dev/null 2>&1; then
      if [ -z "$PASSING_REVIEWER" ] && [ "$rprov" != "$AUTHOR_PROVIDER" ]; then
        PASSING_REVIEWER="$rprov/$rmodel"
      fi
    elif printf '%s\n' "$ROUT" | jq -e '.invariant or .summary' >/dev/null 2>&1; then
      printf '%s\n' "$ROUT" >> "$FINDINGS_TMP"
      if [ -z "$PASSING_REVIEWER" ] && [ "$rprov" != "$AUTHOR_PROVIDER" ]; then
        PASSING_REVIEWER="$rprov/$rmodel"
      fi
    else
      echo "loop: reviewer $rprov/$rmodel produced no parseable review — treating as failed" >&2
    fi
  else
    echo "loop: reviewer $rprov/$rmodel failed to run" >&2
  fi
done
if [ -z "$PASSING_REVIEWER" ]; then
  # No cross-provider reviewer both exists AND ran successfully.
  if [ "${#REVIEWER_ENTRIES[@]}" -eq 0 ]; then
    echo "loop: review gate failed — no reviewer configured for shape '$SHAPE'" >&2
  else
    echo "loop: review gate failed — every configured reviewer shares the author's provider or failed to run" >&2
  fi
  exit 5
fi
echo "loop: review passed via cross-provider reviewer $PASSING_REVIEWER"

# ── 5. findings -> fingerprints -> deduplicated tickets ───────────────────────
CYCLE_FINDINGS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  jq -e '.status == "clean"' <<<"$f" >/dev/null 2>&1 && continue
  INVARIANT="$(jq -r '.invariant // .summary // empty' <<<"$f" 2>/dev/null)" || INVARIANT=""
  LOCATION="$(jq -r '.location // ""' <<<"$f" 2>/dev/null)" || LOCATION=""
  # A finding without a stated severity is treated as high — fail closed.
  SEVERITY="$(jq -r '.severity // "high"' <<<"$f" 2>/dev/null)" || SEVERITY="high"
  [ -n "$SEVERITY" ] || SEVERITY="high"
  [ -n "$INVARIANT" ] || continue
  FP="$(ceo_finding_fingerprint "$REPO" "$CURRENT_BASE" "$INVARIANT" "$LOCATION" "$SEVERITY")"
  jq -cn --arg fp "$FP" --arg inv "$INVARIANT" --arg loc "$LOCATION" \
    --arg sev "$SEVERITY" --arg repo "$REPO" --arg base "$CURRENT_BASE" \
    '{fingerprint: $fp, invariant: $inv, location: $loc, severity: $sev,
      repo: $repo, base: $base}' >> "$DIR/findings.jsonl"
  TICKET_ID="$(ceo_filing_ticket "$DIR" "$FP" \
    "$INVARIANT at $LOCATION [$SEVERITY]" \
    "${CEO_LOOP_TICKET_OWNER:-unassigned}" \
    "${INVARIANT}" \
    "Finding no longer reproduces on a fresh verification run of ${BRANCH}" \
    "$SEVERITY" "$REPO" "$CURRENT_BASE")"
  CYCLE_FINDINGS=$((CYCLE_FINDINGS + 1))
  # The requeue pass iterates TICKET ids, not raw finding JSON.
  echo "$TICKET_ID" >> "$FINGERPRINTS_FILE"
  if [ "$(printf '%s' "$SEVERITY" | tr '[:upper:]' '[:lower:]')" = "high" ]; then
    HIGH_FINDINGS=$((HIGH_FINDINGS + 1))
  fi
done < <(jq -c '.' "$FINDINGS_TMP" 2>/dev/null | grep -v '^$' || true)

# ── 6. risk classification + promotion gate (bound approval) ──────────────────
RISK_MAP="$LIB_DIR/ceo-risk-map.json"
RISK="$(ceo_risk_classify "$RISK_MAP" "${FILES[@]}")"
CHANGE_DIGEST="$(ceo_change_digest "$REPO" "$CURRENT_BASE" "${FILES[@]}")"
[ "${CEO_LOOP_DEBUG:-0}" = "1" ] && echo "debug: repo=$REPO base=$CURRENT_BASE files=${FILES[*]} digest=$CHANGE_DIGEST" >&2
PREMIUM_APPROVAL="${CEO_LOOP_PREMIUM_APPROVAL:-}"
ACTION=""
set +e
ACTION="$(CEO_LOOP_ALLOW_MAIN="${CEO_LOOP_ALLOW_MAIN:-0}" \
  ceo_promotion_gate "$RISK" "$TARGET" "$DEFAULT_BRANCH" "$PREMIUM_APPROVAL" "$CHANGE_DIGEST")"
GATE_RC=$?
set -e
if [ "$GATE_RC" -eq 7 ]; then
  echo "loop: BLOCKED — $RISK-risk change targeting production main '$TARGET' without premium approval bound to digest ${CHANGE_DIGEST:0:12}…" >&2
  echo "  Approval JSON needs approved_by, ticket, and change_digest=$CHANGE_DIGEST" >&2
  exit 7
fi

# ── 7. acceptance: failing tests and HIGH findings block promotion ────────────
FINAL_RC=0
ACCEPTED=false
if [ "$TEST_RC" -ne 0 ]; then
  # A failed verification is itself a finding — otherwise a run whose review
  # was clean would fail quietly and still exit 0 (#329 audit P1).
  VFP="$(ceo_finding_fingerprint "$REPO" "$CURRENT_BASE" "verify_cmd passes" "spec:$SPEC" "HIGH")"
  VTID="$(ceo_filing_ticket "$DIR" "$VFP" \
    "verification failed: $VERIFY_CMD" \
    "${CEO_LOOP_TICKET_OWNER:-unassigned}" \
    "$VERIFY_CMD" \
    "verify_cmd exits 0 inside the worktree" "HIGH" "$REPO" "$CURRENT_BASE")"
  echo "$VTID" >> "$FINGERPRINTS_FILE"
fi
if [ "$TEST_RC" -ne 0 ] || [ "$HIGH_FINDINGS" -gt 0 ]; then
  # Bounded requeue already spent its attempts above; record exhaustion.
  while IFS= read -r tid; do
    OUT="$(ceo_requeue_decide "$DIR" "$tid" "$MAX_RETRIES")" || RC_HERE=$?
    RC_HERE="${RC_HERE:-0}"
    case "$OUT" in
      retry:*) echo "loop: ticket ${tid:0:19}... requeued ($OUT)" ;;
      exhausted) echo "loop: retries EXHAUSTED for ${tid:0:19}... — recorded in $DIR/exhausted.jsonl" ;;
    esac
    [ "$RC_HERE" -gt "$FINAL_RC" ] && FINAL_RC=$RC_HERE
    RC_HERE=0
  done < "$FINGERPRINTS_FILE"
  # Unaccepted work exits nonzero whether or not retries remain: a clean exit
  # here would read as success to any caller (#329 audit P1).
  if [ "$HIGH_FINDINGS" -gt 0 ]; then
    FINAL_RC=5
    echo "loop: $HIGH_FINDINGS HIGH finding(s) block promotion — repair tickets filed" >&2
  elif [ "$FINAL_RC" -eq 0 ]; then
    FINAL_RC=3
  fi
else
  ACCEPTED=true
fi

PROMOTED=false
PARKED=false
if [ "$ACCEPTED" = "true" ] && [ "$GATE_RC" -eq 0 ] && [ -n "$ACTION" ]; then
  if [ "$ACTION" = "park-integration" ]; then
    # Parking IS keeping the isolated branch: unmerged, inspectable, not lost.
    PARKED=true
    echo "loop: parked — branch $BRANCH holds accepted work below ${TARGET} policy threshold"
  elif [ "$DRY_RUN" != "1" ]; then
    PROMOTED=true
    if git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
      if git -C "$WT" push origin "$BRANCH" >/dev/null 2>&1; then
        if (cd "$WT" && gh pr create --head "$BRANCH" --base "$TARGET" \
          --title "ceo-loop: $REPO/$BRANCH" \
          --body "Autonomous loop PR (#329). risk=$RISK worker=$WORKER_IDENTITY reviewer=$PASSING_REVIEWER") \
          >/dev/null 2>&1; then
          echo "loop: PR opened against $TARGET"
        else
          echo "loop: pushed $BRANCH (gh pr create failed — open one manually)" >&2
        fi
      else
        echo "loop: push failed — branch $BRANCH kept locally" >&2
      fi
    else
      # No remote: promote is a fast-forward-only ref update of the target.
      if git -C "$REPO_DIR" merge-base --is-ancestor "$TARGET" "$BRANCH" 2>/dev/null \
         && git -C "$REPO_DIR" update-ref "refs/heads/$TARGET" "$(git -C "$REPO_DIR" rev-parse "$BRANCH")"; then
        echo "loop: promoted $BRANCH into local $TARGET (fast-forward)"
      else
        echo "loop: could not fast-forward $TARGET — branch $BRANCH holds the work" >&2
        PROMOTED=false
      fi
    fi
  fi
fi

ceo_worker_release "$DIR" "$BRANCH"

# ── 8. telemetry (token-scope ingestion contract) ─────────────────────────────
NOW_TS="$(date +%s)"
jq -nc \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg repo "$REPO" --arg branch "$BRANCH" --arg model "$WORKER_IDENTITY" \
  --arg reviewer "$PASSING_REVIEWER" \
  --arg target "$TARGET" --arg risk "$RISK" --arg action "$ACTION" \
  --argjson promoted "${PROMOTED:-false}" --argjson parked "${PARKED:-false}" \
  --argjson accepted "$ACCEPTED" \
  --argjson seconds_to_passing "$((NOW_TS - START_TS))" \
  --argjson retries_used "$((ATTEMPT > MAX_RETRIES ? MAX_RETRIES : ATTEMPT))" \
  --argjson findings "$CYCLE_FINDINGS" \
  --argjson high_findings "$HIGH_FINDINGS" \
  '{ts: $ts, writer: "ceo-loop", repo: $repo, branch: $branch, model: $model,
    reviewer: $reviewer, target: $target, risk: $risk, action: $action,
    promoted: $promoted, parked: $parked,
    accepted: $accepted, seconds_to_passing: $seconds_to_passing,
    retries_used: $retries_used, findings: $findings,
    high_findings: $high_findings,
    reviewer_disagreement: (if $high_findings > 0 then 1 else 0 end),
    rework: (if $retries_used > 0 then 1 else 0 end)}' >> "$DIR/telemetry.jsonl"

ceo_ledger_write_entry "ceo-loop" "$WORKER_IDENTITY" "loop:$REPO/$BRANCH" "$PWD" null "$ACCEPTED" >/dev/null || true

if [ "$PROMOTED" = "true" ]; then SUMMARY_ACTION="promoted";
elif [ "$PARKED" = "true" ]; then SUMMARY_ACTION="parked";
else SUMMARY_ACTION="${ACTION:-blocked}"; fi
echo "loop: done ($REPO/$BRANCH risk=$RISK action=$SUMMARY_ACTION attempts=$((ATTEMPT + 1)))"
exit $FINAL_RC
