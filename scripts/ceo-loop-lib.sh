#!/usr/bin/env bash
# ceo-loop-lib.sh — pure decision functions for the #329 risk-routed
# worker/review/ticket/requeue loop. No side effects except where a function's
# contract says it owns a state file; everything testable is testable without
# providers, worktrees, or the network.
#
# State layout (per repo slug) under ${XDG_STATE_HOME:-~/.local/state}/ceo-loop/:
#   workers.jsonl        in-flight worker rows: branch, base sha, files
#   repair-tickets.jsonl deduplicated findings: fingerprint, ticket, retries
#   exhausted.jsonl      tickets whose retry budget ran out — never deleted

set -euo pipefail

CEO_LOOP_STATE_ROOT="${CEO_LOOP_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/ceo-loop}"

# ceo_loop_state_dir <repo-slug>
ceo_loop_state_dir() {
  printf '%s/%s' "$CEO_LOOP_STATE_ROOT" "$1"
}

# ── portable mutual exclusion (no flock on macOS/BSD) ────────────────────────
# State mutations that read-modify-write run inside an inner bash whose body is
# a single-quoted heredoc (no nested-quote hell), guarded by an atomic mkdir
# lock with a bounded wait: concurrent loops queue up or fail loudly at
# CEO_LOCK_TIMEOUT_SECS — they never race.
CEO_LOCK_TIMEOUT_SECS="${CEO_LOCK_TIMEOUT_SECS:-10}"

# ── risk classification (#329: premium gate scope) ──────────────────────────

# ceo_risk_classify <map.json> <repo-relative-path>...
# Highest matching rule wins; a path class nothing matches defaults to the
# map's default_risk. Fails CLOSED to "high": an unreadable map or broken
# lookup must not let high-risk work reach production main by accident.
ceo_risk_classify() {
  local map="$1"; shift
  if [ ! -r "$map" ]; then
    echo "high"; return 0
  fi
  local out
  out="$(jq -rn --slurpfile m "$map" --argjson paths "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '
    [ $paths[] as $p
      | $m[0].rules[] as $r
      | select($p | test($r.match_pattern; "i"))
      | $r.risk ]
    | if index("high") then "high"
      elif index("medium") then "medium"
      elif length > 0 then "low"
      else $m[0].default_risk // "high"
      end
  ' 2>/dev/null)" || { echo "high"; return 0; }
  [ -n "$out" ] || { echo "high"; return 0; }
  echo "$out"
}

# ── finding fingerprints → repair-ticket dedup (#329 AC: equivalents collapse) ─

# ceo_finding_fingerprint <repo> <base-sha> <invariant-or-test> <location> <severity>
# Location is normalized (line numbers stripped) so "the same finding at a
# shifted line" collapses; severity is case-folded so HIGH/high agree. Base sha
# binds the fingerprint to what the finding was found against — a rebase that
# changes the code legitimately re-opens.
ceo_finding_fingerprint() {
  local repo="$1" base="$2" invariant="$3" location="$4" severity="$5"
  local normalized
  normalized="$(printf '%s' "$location" | sed -E 's/:[0-9]+(:[0-9]+)?$//')"
  severity="$(printf '%s' "$severity" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$repo|$base|$invariant|$normalized|$severity" | shasum -a 256 | cut -d' ' -f1
}

# ceo_ticket_dedup <state-dir> <fingerprint> <summary>
# Echoes the existing ticket id when this fingerprint was already filed;
# otherwise appends the row under the state lock (retries start at 0) and
# echoes the new id. The full fingerprint is the ticket id — no truncation,
# so requeue updates can never touch a sibling row.
ceo_ticket_dedup() {
  local dir="$1" fp="$2" summary="$3"
  mkdir -p "$dir"
  touch "$dir/repair-tickets.jsonl"
  CEO_LOCK_DIR="$dir" CEO_FP="$fp" CEO_SUMMARY="$summary" CEO_LOCK_WAIT="$CEO_LOCK_TIMEOUT_SECS" bash <<'DEDUP_INNER'
set -euo pipefail
lock="$CEO_LOCK_DIR/.lock"; waited=0
until mkdir "$lock" 2>/dev/null; do
  sleep 0.2; waited=$((waited + 1))
  if [ "$waited" -ge $((CEO_LOCK_WAIT * 5)) ]; then
    echo "ceo-lock: state lock at $lock held too long — refusing to race" >&2
    exit 8
  fi
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
file="$CEO_LOCK_DIR/repair-tickets.jsonl"
existing="$(jq -r --arg fp "$CEO_FP" 'select(.fingerprint == $fp) | .ticket_id' "$file" | head -1)"
if [ -n "$existing" ]; then
  echo "$existing"
  exit 0
fi
jq -nc --arg fp "$CEO_FP" --arg s "$CEO_SUMMARY"   '{fingerprint: $fp, ticket_id: ("repair-" + $fp), retries: 0, summary: $s}' >> "$file"
echo "repair-$CEO_FP"
DEDUP_INNER
}

# ── bounded requeue (#329 AC: exhaustion stays visible) ──────────────────────

# ceo_requeue_decide <state-dir> <ticket-id> <max-retries>
# Increments the retry counter and prints "retry:<n>", or on reaching the cap
# prints "exhausted", records the ticket in exhausted.jsonl exactly once (the
# row is marked so later cycles short-circuit), and exits 3 — loud, but
# distinguishable from a generic failure. Unknown tickets are an internal
# error, not CLI misuse: exit 8.
ceo_requeue_decide() {
  local dir="$1" ticket_id="$2" max_retries="$3"
  mkdir -p "$dir"
  touch "$dir/repair-tickets.jsonl"
  CEO_LOCK_DIR="$dir" CEO_T="$ticket_id" CEO_MAX="$max_retries" \
    CEO_LOCK_WAIT="$CEO_LOCK_TIMEOUT_SECS" bash <<'REQUEUE_INNER'
set -euo pipefail
lock="$CEO_LOCK_DIR/.lock"; waited=0
until mkdir "$lock" 2>/dev/null; do
  sleep 0.2; waited=$((waited + 1))
  if [ "$waited" -ge $((CEO_LOCK_WAIT * 5)) ]; then
    echo "ceo-lock: state lock at $lock held too long — refusing to race" >&2
    exit 8
  fi
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
file="$CEO_LOCK_DIR/repair-tickets.jsonl"
if ! jq -e --arg t "$CEO_T" 'select(.ticket_id == $t)' "$file" >/dev/null; then
  echo "ceo-requeue: unknown ticket $CEO_T" >&2
  exit 8
fi
status="$(jq -r --arg t "$CEO_T" 'select(.ticket_id == $t) | .status // ""' "$file" | head -1)"
if [ "$status" = "exhausted" ]; then
  echo "exhausted"; exit 3
fi
current="$(jq -r --arg t "$CEO_T" 'select(.ticket_id == $t) | .retries' "$file" | head -1)"
next=$((current + 1))
if [ "$next" -gt "$CEO_MAX" ]; then
  jq -c --arg t "$CEO_T" 'select(.ticket_id == $t) | .status = "exhausted"' "$file" \
    | head -1 >> "$CEO_LOCK_DIR/exhausted.jsonl"
  jq -c --arg t "$CEO_T" 'select(.ticket_id == $t) |= (.status = "exhausted")' "$file" \
    > "$file.tmp" && mv "$file.tmp" "$file"
  echo "exhausted"; exit 3
fi
jq -c --arg t "$CEO_T" --argjson n "$next" \
  'select(.ticket_id == $t) |= (.retries = $n)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
echo "retry:$next"
REQUEUE_INNER
}

# ── provider-neutral routing with policy failover (#329) ─────────────────────

# Routes file shape:
# {"routes": {"<shape>": [
#   {"provider":"ollama","model":"qwen2.5-coder:7b","command":"..."},
#   {"provider":"opencode","model":"kimi-k3","command":"..."} ]}}
# First candidate is primary; the rest are fallbacks in order.

# ceo_route_select <routes.json> <shape> — prints the primary route JSON,
# or exits 4 with an actionable message when no route exists at all.
ceo_route_select() {
  local routes="$1" shape="$2"
  local primary
  primary="$(jq -c --arg s "$shape" '.routes[$s][0] // empty' "$routes" 2>/dev/null)"
  if [ -z "$primary" ]; then
    echo "ceo-route: no route configured for task shape '$shape' in $routes" >&2
    return 4
  fi
  echo "$primary"
}

# ceo_route_failover <routes.json> <shape> <failed-provider> [<failed-model>]
# Prints the next candidate after every entry matching the failed provider
# (+ model when given). Exits 4 loudly when no fallback remains — reroute or
# die visibly, never silently drop (#329 AC).
ceo_route_failover() {
  local routes="$1" shape="$2" failed_provider="$3" failed_model="${4:-}"
  local last_idx rest first
  last_idx="$(jq -r --arg s "$shape" --arg p "$failed_provider" --arg m "$failed_model" '
    [ .routes[$s] | to_entries[]
      | select(.value.provider == $p and ($m == "" or .value.model == $m))
      | .key ] | max // -1
  ' "$routes" 2>/dev/null)" || { echo "ceo-route: unreadable route table $routes" >&2; return 4; }
  if [ "$last_idx" = "-1" ]; then
    echo "ceo-route: ${failed_provider}${failed_model:+/$failed_model} is not a configured route for '$shape' — check the route table" >&2
    return 4
  fi
  first="$(jq -c --arg s "$shape" --argjson skip "$((last_idx + 1))" \
    '.routes[$s][$skip:] | .[0] // empty' "$routes" 2>/dev/null)"
  if [ -z "$first" ]; then
    echo "ceo-route: no fallback left for '$shape' after ${failed_provider}${failed_model:+/$failed_model} — fix the route table or run the task yourself" >&2
    return 4
  fi
  echo "$first"
}

# ── heterogeneous review gate (#329: author cannot be its own only reviewer) ──

# ceo_review_gate <author-provider/model> <reviewer-provider/model>...
# Passes only when at least one reviewer exists AND one of them runs a
# different provider than the author. Prints the passing reviewer, else exit 5.
ceo_review_gate() {
  local author="$1"; shift
  local reviewers="$*"
  if [ -z "${reviewers// /}" ]; then
    echo "ceo-review: no reviewer assigned — at least one, from a different provider than $author, is required" >&2
    return 5
  fi
  local author_provider="${author%%/*}"
  local r rp
  for r in "$@"; do
    rp="${r%%/*}"
    if [ "$rp" != "$author_provider" ]; then
      echo "$r"
      return 0
    fi
  done
  echo "ceo-review: every reviewer runs '$author_provider', same as the author — cross-provider review required" >&2
  return 5
}

# ── overlap serialization + stale base (#329 AC) ─────────────────────────────

# ceo_worker_register <state-dir> <branch> <base-sha> <file>... — records an
# in-flight worker. Exits 6 on overlap with a registered worker sharing any
# file, migration path, or declared dependency, naming the conflict.
ceo_worker_register() {
  local dir="$1" branch="$2" base="$3"; shift 3
  mkdir -p "$dir"
  touch "$dir/workers.jsonl"
  CEO_LOCK_DIR="$dir" CEO_BRANCH="$branch" CEO_BASE="$base" \
    CEO_LOCK_WAIT="$CEO_LOCK_TIMEOUT_SECS" bash -s "$@" <<'REGISTER_INNER'
set -euo pipefail
lock="$CEO_LOCK_DIR/.lock"; waited=0
until mkdir "$lock" 2>/dev/null; do
  sleep 0.2; waited=$((waited + 1))
  if [ "$waited" -ge $((CEO_LOCK_WAIT * 5)) ]; then
    echo "ceo-lock: state lock at $lock held too long — refusing to race" >&2
    exit 8
  fi
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
file="$CEO_LOCK_DIR/workers.jsonl"
lineno=0
while IFS= read -r row; do
  lineno=$((lineno + 1))
  [ -n "$row" ] || continue
  # A row that fails validation is a corrupt state file, not "no conflict":
  # the gate must not silently pass exactly when its state is least trustworthy.
  if ! echo "$row" | jq -e '(.branch | type == "string") and (.files | type == "array")' >/dev/null 2>&1; then
    echo "ceo-workers: corrupt row at line $lineno of $file — fix or remove it before registering" >&2
    exit 6
  fi
  for f in "$@"; do
    if echo "$row" | jq -e --arg f "$f" --arg b "$CEO_BRANCH" \
      'select(.branch != $b) | (.files | index($f))' >/dev/null 2>&1; then
      conflict="$(echo "$row" | jq -r .branch)"
      echo "ceo-workers: '$CEO_BRANCH' overlaps in-flight worker '$conflict' on file $f — serialize or rebase" >&2
      exit 6
    fi
  done
done < "$file"
jq -nc --arg b "$CEO_BRANCH" --arg base "$CEO_BASE" \
  --argjson files "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
  '{branch: $b, base: $base, files: $files}' >> "$file"
REGISTER_INNER
}

# ceo_worker_release <state-dir> <branch> — removes the branch's row under the
# state lock so a concurrent registration between read and rename survives.
ceo_worker_release() {
  local dir="$1" branch="$2"
  local file="$dir/workers.jsonl"
  [ -f "$file" ] || return 0
  CEO_LOCK_DIR="$dir" CEO_BRANCH="$branch" CEO_LOCK_WAIT="$CEO_LOCK_TIMEOUT_SECS" bash <<'RELEASE_INNER'
set -euo pipefail
lock="$CEO_LOCK_DIR/.lock"; waited=0
until mkdir "$lock" 2>/dev/null; do
  sleep 0.2; waited=$((waited + 1))
  if [ "$waited" -ge $((CEO_LOCK_WAIT * 5)) ]; then
    # Release is best-effort cleanup; losing it here leaves a visible stale
    # row rather than corrupting state. Say so instead of failing the caller.
    echo "ceo-workers: release skipped — state lock busy ($CEO_LOCK_DIR)" >&2
    exit 0
  fi
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
file="$CEO_LOCK_DIR/workers.jsonl"
jq -c --arg b "$CEO_BRANCH" 'select(.branch != $b)' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
RELEASE_INNER
}

# ceo_base_stale <recorded-base> <current-base> — 0 when equal, 1 when stale.
ceo_base_stale() {
  [ "$1" = "$2" ]
}

# ── promotion gate (#329: premium pre-merge before production main) ──────────

# ceo_promotion_gate <risk> <target-branch> <default-branch> <premium-approval-file|[]>
# Returns the action on stdout:
#   promote            safe to merge into <target>
#   park-integration   fine work, but target is production main and the risk
#                      or policy says integration branch first
#   blocked-premium    HIGH risk aimed at production main with no premium
#                      approval evidence — hard stop, exit 7
ceo_promotion_gate() {
  local risk="$1" target="$2" default_branch="$3" approval="${4:-}"
  if [ "$target" != "$default_branch" ]; then
    echo "promote"; return 0
  fi
  if [ "$risk" = "high" ]; then
    if [ -n "$approval" ] && [ -f "$approval" ]; then
      echo "promote"; return 0
    fi
    echo "blocked-premium"
    return 7
  fi
  if [ "${CEO_LOOP_ALLOW_MAIN:-0}" = "1" ] && [ "$risk" != "high" ]; then
    echo "promote"; return 0
  fi
  echo "park-integration"
}
