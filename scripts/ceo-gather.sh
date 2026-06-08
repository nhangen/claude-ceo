#!/bin/bash
# ceo-gather.sh — Pre-gather deterministic data for CEO agent.
# Source this file to export variables. Do not run standalone.
#
# Usage: source "$(dirname "$0")/ceo-gather.sh"
#
# Exports:
#   VAULT, CEO_DIR, LOG_DIR, TODAY, NOW
#   PENDING_COUNT, APPROVED_COUNT
#   PR_REVIEW_REQUESTED, PR_AUTHORED (JSON from gh)
#   PR_REVIEW_COUNT, PR_AUTHORED_COUNT
#   TODAY_LOG_EXISTS, TODAY_LOG_SUMMARY
#   YESTERDAY_LOG_EXISTS, YESTERDAY_LOG_SUMMARY
#   DELEGATION_COMPLETED, DELEGATION_IN_PROGRESS, DELEGATION_FAILED
#   SYNC_CONFLICT_COUNT
#   DAILY_NOTE_TOP3, DAILY_NOTE_TASKS
#   BLESSINGS_TODAY

# Load shared config library
GATHER_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$GATHER_DIR/ceo-config.sh"

# --- Base paths ---
ceo_require_vault
export VAULT="$CEO_VAULT"
export CEO_DIR="$VAULT/CEO"
export LOG_DIR="$CEO_DIR/log"
export TODAY
TODAY=$(date +%Y-%m-%d)
export NOW
NOW=$(date +%H:%M)

# --- Pending approvals ---
PENDING_FILE="$CEO_DIR/approvals/pending.md"
if [ -f "$PENDING_FILE" ]; then
export PENDING_COUNT
PENDING_COUNT=$(grep -c "^- \[ \]" "$PENDING_FILE" 2>/dev/null; true)
export APPROVED_COUNT
APPROVED_COUNT=$(grep -c "^- \[x\]" "$PENDING_FILE" 2>/dev/null; true)
else
  export PENDING_COUNT=0
  export APPROVED_COUNT=0
fi

# Portable timeout shim — reuse the library helper instead of duplicating it.
# CEO_TIMEOUT_BIN is set to "timeout" / "gtimeout" / "" by ceo_resolve_timeout_bin.
ceo_resolve_timeout_bin
if [ -n "$CEO_TIMEOUT_BIN" ]; then
  _CEO_TIMEOUT() { "$CEO_TIMEOUT_BIN" "$@"; }
else
  _CEO_TIMEOUT() { shift; "$@"; }
fi

# --- GitHub PRs (global search per configured account) ---
# Account list, exclude-orgs, GitLab usernames, dedupe come from
# ~/.ceo/pr-sources.json (written by `ceo pr-sources` / setup-wsl.sh).
# Missing config falls back to discovery so fresh hosts still produce data.
# See nhangen/claude-ceo#61.
_REVIEW_PARTS="[]"
_AUTHORED_PARTS="[]"
# Recently-merged authored PRs (#163) — reconcile's close-evidence. Bounded to a
# ~30-day window so the search stays small; reconcile still matches by explicit
# org/repo#N, so the window only caps how stale a closeable to-do can be.
_MERGED_PARTS="[]"
_MERGED_SINCE=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "")
# Track gh failures so the morning brief can render a "PR counts may be incomplete"
# marker instead of silently reporting 0 on rate limits / 5xx / token expiry.
export PR_GATHER_DEGRADED=0
export PR_GATHER_DEGRADED_REASONS=""
_pr_gather_mark_degraded() {
  PR_GATHER_DEGRADED=1
  PR_GATHER_DEGRADED_REASONS="$PR_GATHER_DEGRADED_REASONS
$1"
}

if command -v gh &>/dev/null; then
  while IFS= read -r ACCT; do
    [ -z "$ACCT" ] && continue
    if ! TOKEN=$(gh auth token -u "$ACCT" 2>/dev/null); then
      echo "WARN: gh auth token failed for '$ACCT' — run 'gh auth refresh -h github.com -u $ACCT'" >&2
      _pr_gather_mark_degraded "token-fetch-failed:$ACCT"
      continue
    fi
    [ -z "$TOKEN" ] && { _pr_gather_mark_degraded "token-empty:$ACCT"; continue; }

    _err=$(mktemp)
    if ! _R=$(GH_TOKEN="$TOKEN" _CEO_TIMEOUT 30 gh search prs \
          --state open --review-requested "@me" \
          --json number,title,createdAt,repository --limit 50 2>"$_err"); then
      echo "WARN: gh search prs (review) for '$ACCT' failed: $(head -c 200 "$_err")" >&2
      _pr_gather_mark_degraded "gh-review-failed:$ACCT"
      _R="[]"
    fi
    rm -f "$_err"
    _REVIEW_PARTS=$(printf '%s\n%s' "$_REVIEW_PARTS" "$_R" | jq -s 'add' 2>/dev/null || echo "$_REVIEW_PARTS")

    _err=$(mktemp)
    if ! _A=$(GH_TOKEN="$TOKEN" _CEO_TIMEOUT 30 gh search prs \
          --state open --author "@me" \
          --json number,title,createdAt,repository --limit 50 2>"$_err"); then
      echo "WARN: gh search prs (authored) for '$ACCT' failed: $(head -c 200 "$_err")" >&2
      _pr_gather_mark_degraded "gh-authored-failed:$ACCT"
      _A="[]"
    fi
    rm -f "$_err"
    _AUTHORED_PARTS=$(printf '%s\n%s' "$_AUTHORED_PARTS" "$_A" | jq -s 'add' 2>/dev/null || echo "$_AUTHORED_PARTS")

    _err=$(mktemp)
    _MQ=(--author "@me" --merged --json "number,title,closedAt,repository,url" --limit 50)
    [ -n "$_MERGED_SINCE" ] && _MQ+=(--merged-at ">=$_MERGED_SINCE")
    if ! _M=$(GH_TOKEN="$TOKEN" _CEO_TIMEOUT 30 gh search prs "${_MQ[@]}" 2>"$_err"); then
      echo "WARN: gh search prs (merged) for '$ACCT' failed: $(head -c 200 "$_err")" >&2
      _pr_gather_mark_degraded "gh-merged-failed:$ACCT"
      _M="[]"
    fi
    rm -f "$_err"
    _MERGED_PARTS=$(printf '%s\n%s' "$_MERGED_PARTS" "$_M" | jq -s 'add' 2>/dev/null || echo "$_MERGED_PARTS")
  done < <(ceo_pr_sources_github_accounts)

  # Drop excluded orgs (case-insensitive match on the owner segment).
  # Warn loudly if the user configured exclude_orgs but everything got dropped
  # by the validator in ceo_pr_sources_github_exclude_orgs — silent collapse
  # would let PRs from explicitly-excluded orgs leak into the brief.
  _RAW_EX=$(ceo_pr_sources_github_exclude_orgs)
  EXCLUDE_ORGS=$(printf '%s\n' "$_RAW_EX" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  if [ -n "$_RAW_EX" ] && [ "$EXCLUDE_ORGS" = "[]" ]; then
    echo "WARN: exclude_orgs configured but parsed to empty list — check $(ceo_pr_sources_path)" >&2
  fi
  if [ "$EXCLUDE_ORGS" != "[]" ]; then
    _REVIEW_PARTS=$(echo "$_REVIEW_PARTS" | jq --argjson ex "$EXCLUDE_ORGS" \
      '[.[] | select(.repository.nameWithOwner != null) | select((.repository.nameWithOwner | split("/")[0] | ascii_downcase) as $o | ($ex | map(ascii_downcase) | index($o)) | not)]' 2>/dev/null || echo "$_REVIEW_PARTS")
    _AUTHORED_PARTS=$(echo "$_AUTHORED_PARTS" | jq --argjson ex "$EXCLUDE_ORGS" \
      '[.[] | select(.repository.nameWithOwner != null) | select((.repository.nameWithOwner | split("/")[0] | ascii_downcase) as $o | ($ex | map(ascii_downcase) | index($o)) | not)]' 2>/dev/null || echo "$_AUTHORED_PARTS")
    _MERGED_PARTS=$(echo "$_MERGED_PARTS" | jq --argjson ex "$EXCLUDE_ORGS" \
      '[.[] | select(.repository.nameWithOwner != null) | select((.repository.nameWithOwner | split("/")[0] | ascii_downcase) as $o | ($ex | map(ascii_downcase) | index($o)) | not)]' 2>/dev/null || echo "$_MERGED_PARTS")
  fi

  # Dedupe by repo+number — same PR can appear under both accounts when one
  # is author and the other has org read access. Opt-out via dedupe:false.
  # `select(.repository.nameWithOwner and .number)` prevents jq's null-as-"null"
  # interpolation from collapsing distinct null-key entries into a single row.
  if ceo_pr_sources_dedupe; then
    _REVIEW_PARTS=$(echo "$_REVIEW_PARTS" | jq '[.[] | select(.repository.nameWithOwner and .number)] | unique_by("\(.repository.nameWithOwner)#\(.number)")' 2>/dev/null || echo "$_REVIEW_PARTS")
    _AUTHORED_PARTS=$(echo "$_AUTHORED_PARTS" | jq '[.[] | select(.repository.nameWithOwner and .number)] | unique_by("\(.repository.nameWithOwner)#\(.number)")' 2>/dev/null || echo "$_AUTHORED_PARTS")
    _MERGED_PARTS=$(echo "$_MERGED_PARTS" | jq '[.[] | select(.repository.nameWithOwner and .number)] | unique_by("\(.repository.nameWithOwner)#\(.number)")' 2>/dev/null || echo "$_MERGED_PARTS")
  fi
fi

# --- GitLab MRs ---
_GL_REVIEW_PARTS="[]"
_GL_AUTHORED_PARTS="[]"
if command -v glab &>/dev/null && glab auth status &>/dev/null 2>&1; then
  while IFS= read -r GL_USER; do
    [ -z "$GL_USER" ] && continue
    _err=$(mktemp)
    if ! _GLR=$(_CEO_TIMEOUT 30 glab api "merge_requests?scope=all&state=opened&reviewer_username=$GL_USER&per_page=50" 2>"$_err"); then
      echo "WARN: glab api (reviewer) for '$GL_USER' failed: $(head -c 200 "$_err")" >&2
      _pr_gather_mark_degraded "glab-review-failed:$GL_USER"
      _GLR="[]"
    fi
    rm -f "$_err"
    _err=$(mktemp)
    if ! _GLA=$(_CEO_TIMEOUT 30 glab api "merge_requests?scope=all&state=opened&author_username=$GL_USER&per_page=50" 2>"$_err"); then
      echo "WARN: glab api (author) for '$GL_USER' failed: $(head -c 200 "$_err")" >&2
      _pr_gather_mark_degraded "glab-authored-failed:$GL_USER"
      _GLA="[]"
    fi
    rm -f "$_err"
    # Guard `references.full` — null on rare MR shapes would throw inside sub()
    # and the outer `|| echo "[]"` would empty the entire batch.
    _R=$(echo "$_GLR" | jq '[.[] | select(.references.full != null) | {number: .iid, title, createdAt: .created_at, repository: {nameWithOwner: (.references.full | sub("![^!]*$"; ""))}, url: .web_url}]' 2>/dev/null || echo "[]")
    _A=$(echo "$_GLA" | jq '[.[] | select(.references.full != null) | {number: .iid, title, createdAt: .created_at, repository: {nameWithOwner: (.references.full | sub("![^!]*$"; ""))}, url: .web_url}]' 2>/dev/null || echo "[]")
    _GL_REVIEW_PARTS=$(printf '%s\n%s' "$_GL_REVIEW_PARTS" "$_R" | jq -s 'add' 2>/dev/null || echo "$_GL_REVIEW_PARTS")
    _GL_AUTHORED_PARTS=$(printf '%s\n%s' "$_GL_AUTHORED_PARTS" "$_A" | jq -s 'add' 2>/dev/null || echo "$_GL_AUTHORED_PARTS")
  done < <(ceo_pr_sources_gitlab_usernames)
fi

_REVIEW_PARTS=$(printf '%s\n%s' "$_REVIEW_PARTS" "$_GL_REVIEW_PARTS" | jq -s 'add' 2>/dev/null || echo "$_REVIEW_PARTS")
_AUTHORED_PARTS=$(printf '%s\n%s' "$_AUTHORED_PARTS" "$_GL_AUTHORED_PARTS" | jq -s 'add' 2>/dev/null || echo "$_AUTHORED_PARTS")

export PR_REVIEW_REQUESTED="$_REVIEW_PARTS"
export PR_AUTHORED="$_AUTHORED_PARTS"
export PR_REVIEW_COUNT
PR_REVIEW_COUNT=$(echo "$PR_REVIEW_REQUESTED" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
export PR_AUTHORED_COUNT
PR_AUTHORED_COUNT=$(echo "$PR_AUTHORED" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
export PR_MERGED="$_MERGED_PARTS"
export PR_MERGED_COUNT
PR_MERGED_COUNT=$(echo "$PR_MERGED" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)

# --- Today's log ---
TODAY_LOG="$LOG_DIR/$TODAY.md"
if [ -f "$TODAY_LOG" ]; then
  export TODAY_LOG_EXISTS=true
  TOTAL=$(grep -c "^\*\*Status:\*\*" "$TODAY_LOG" 2>/dev/null || echo 0)
  COMPLETED=$(grep -c "^\*\*Status:\*\* completed" "$TODAY_LOG" 2>/dev/null || echo 0)
  FAILED=$(grep -c "^\*\*Status:\*\* failed" "$TODAY_LOG" 2>/dev/null || echo 0)
  export TODAY_LOG_SUMMARY="actions:$TOTAL completed:$COMPLETED failed:$FAILED"
else
  export TODAY_LOG_EXISTS=false
  export TODAY_LOG_SUMMARY="no log"
fi

# --- Yesterday's log ---
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
YESTERDAY_LOG="$LOG_DIR/$YESTERDAY.md"
if [ -f "$YESTERDAY_LOG" ]; then
  export YESTERDAY_LOG_EXISTS=true
export YESTERDAY_LOG_SUMMARY
YESTERDAY_LOG_SUMMARY=$(sed -n '/eod-summary/,/^## /p' "$YESTERDAY_LOG" 2>/dev/null | head -20 || echo "no eod summary")
else
  export YESTERDAY_LOG_EXISTS=false
  export YESTERDAY_LOG_SUMMARY="no log"
fi

# --- Delegations (last 7 days) ---
if [ -d "$CEO_DIR/delegations" ]; then
  RECENT_DELEGATIONS=$(find "$CEO_DIR/delegations" -name "*.md" -not -name ".gitkeep" -mtime -7 2>/dev/null)
  if [ -n "$RECENT_DELEGATIONS" ]; then
export DELEGATION_COMPLETED
DELEGATION_COMPLETED=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: completed" 2>/dev/null | wc -l | xargs)
export DELEGATION_IN_PROGRESS
DELEGATION_IN_PROGRESS=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: in-progress" 2>/dev/null | wc -l | xargs)
export DELEGATION_FAILED
DELEGATION_FAILED=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: failed" 2>/dev/null | wc -l | xargs)
  else
    export DELEGATION_COMPLETED=0
    export DELEGATION_IN_PROGRESS=0
    export DELEGATION_FAILED=0
  fi
else
  export DELEGATION_COMPLETED=0
  export DELEGATION_IN_PROGRESS=0
  export DELEGATION_FAILED=0
fi

# --- Sync conflicts ---
export SYNC_CONFLICT_COUNT
SYNC_CONFLICT_COUNT=$(find "$CEO_DIR" -name "*.sync-conflict-*" -type f 2>/dev/null | wc -l | xargs)

# --- Daily note sections ---
DAILY_NOTE="$VAULT/Daily/$TODAY.md"
if [ -f "$DAILY_NOTE" ]; then
export DAILY_NOTE_TOP3
DAILY_NOTE_TOP3=$(sed -n '/^## Top 3/,/^## /p' "$DAILY_NOTE" 2>/dev/null | head -6 | tail -n +2 || echo "")
export DAILY_NOTE_TASKS
DAILY_NOTE_TASKS=$(sed -n '/^## Tasks/,/^## /p' "$DAILY_NOTE" 2>/dev/null | head -20 | tail -n +2 || echo "")
else
  export DAILY_NOTE_TOP3=""
  export DAILY_NOTE_TASKS=""
fi

# --- Blessings (EA) ---
GATHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=blessings-lib.sh
source "$GATHER_DIR/blessings-lib.sh"
ensure_blessings_cache || true

if [ -f "$CEO_DIR/cache/blessings-today.md" ]; then
export BLESSINGS_TODAY
BLESSINGS_TODAY=$(strip_frontmatter "$CEO_DIR/cache/blessings-today.md")
else
  export BLESSINGS_TODAY=""
fi

# --- Briefing-specific training (capped at 10KB) ---
# Read CEO/training/briefings.md so the read-tier morning brief can synthesize
# without an extra tool call. Falls back to empty if file is absent.
GATHER_MAX_FILE=10000
_gather_safe_read() {
  local file="$1"
  if [ -f "$file" ]; then
    head -c "$GATHER_MAX_FILE" "$file"
  fi
}

export BRIEFINGS_TRAINING
BRIEFINGS_TRAINING=$(_gather_safe_read "$CEO_DIR/training/briefings.md")

# --- Profile.md Active Domains (extract section, not whole file) ---
# Profile.md may contain personal context; we want only the priority-ordering
# section. If the section header isn't present, skip rather than dumping the
# whole file.
PROFILE_FILE="$VAULT/Profile.md"
if [ -f "$PROFILE_FILE" ]; then
export ACTIVE_DOMAINS_CONTENT
ACTIVE_DOMAINS_CONTENT=$(sed -n '/^##* *Active Domains/,/^## /p' "$PROFILE_FILE" 2>/dev/null | head -c "$GATHER_MAX_FILE")
else
  export ACTIVE_DOMAINS_CONTENT=""
fi

# --- Pending.md outstanding questions (top entries only) ---
# Pre-extract unchecked items so Claude doesn't need to read the full file.
# Matches the same pattern PENDING_COUNT uses (line 38). Cap at 20 lines to
# bound cost.
PENDING_FILE="$VAULT/Pending.md"
if [ -f "$PENDING_FILE" ]; then
export PENDING_ASK_QUESTIONS
PENDING_ASK_QUESTIONS=$(grep -n '^- \[ \]' "$PENDING_FILE" 2>/dev/null | head -20)
else
  export PENDING_ASK_QUESTIONS=""
fi

# --- Evaluate Gather Status ---
export CEO_GATHER_STATUS="ok"
export CEO_GATHER_REASONS=""

_has_data=0
[ "${PENDING_COUNT:-0}" -gt 0 ] && _has_data=1
[ "${PR_REVIEW_COUNT:-0}" -gt 0 ] && _has_data=1
[ "${PR_AUTHORED_COUNT:-0}" -gt 0 ] && _has_data=1
[ -n "${DAILY_NOTE_TOP3:-}" ] && _has_data=1
[ -n "${PENDING_ASK_QUESTIONS:-}" ] && _has_data=1

if [ "$_has_data" -eq 0 ]; then
  if [ "${PR_GATHER_DEGRADED:-0}" -eq 1 ]; then
    CEO_GATHER_STATUS="failed"
    CEO_GATHER_REASONS="All primary data sources empty, and PR gather degraded: $(echo "$PR_GATHER_DEGRADED_REASONS" | tr '\n' ' ')"
  else
    CEO_GATHER_STATUS="empty"
    CEO_GATHER_REASONS="All APIs succeeded, but zero active items found (quiet day)"
  fi
elif [ "${PR_GATHER_DEGRADED:-0}" -eq 1 ]; then
  CEO_GATHER_STATUS="partial"
  # Replace newlines with spaces for single-line logging
  CEO_GATHER_REASONS="PR gather degraded: $(echo "$PR_GATHER_DEGRADED_REASONS" | tr '\n' ' ')"
fi
