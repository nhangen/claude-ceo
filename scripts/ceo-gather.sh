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

# --- Base paths ---
if [ -z "${CEO_VAULT:-}" ]; then
  for _candidate in \
    "/mnt/z/Users/$USER/Documents/Obsidian" \
    "/mnt/c/Users/$USER/Documents/Obsidian" \
    "$HOME/Documents/Obsidian" \
    "$HOME/Obsidian"
  do
    [ -d "$_candidate/CEO" ] && { export CEO_VAULT="$_candidate"; break; }
  done
fi
export VAULT="${CEO_VAULT:-$HOME/Documents/Obsidian}"
export CEO_DIR="$VAULT/CEO"
export LOG_DIR="$CEO_DIR/log"
export TODAY=$(date +%Y-%m-%d)
export NOW=$(date +%H:%M)

# --- Pending approvals ---
PENDING_FILE="$CEO_DIR/approvals/pending.md"
if [ -f "$PENDING_FILE" ]; then
  export PENDING_COUNT=$(grep -c "^- \[ \]" "$PENDING_FILE" 2>/dev/null || echo 0)
  export APPROVED_COUNT=$(grep -c "^- \[x\]" "$PENDING_FILE" 2>/dev/null || echo 0)
else
  export PENDING_COUNT=0
  export APPROVED_COUNT=0
fi

# --- GitHub PRs (if gh available) ---
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  # Build repo list from repos.md (column 2 = repo name like org/repo)
  REPOS_FILE="$CEO_DIR/repos.md"
  REPO_NAMES=()
  if [ -f "$REPOS_FILE" ]; then
    while IFS= read -r REPO_NAME; do
      REPO_NAME=$(echo "$REPO_NAME" | xargs)
      [ -n "$REPO_NAME" ] && REPO_NAMES+=("$REPO_NAME")
    done < <(grep "^|" "$REPOS_FILE" | grep -v "^| Repo\|^|---" | awk -F'|' '{print $2}')
  fi

  # Fetch PRs per-repo then merge (gh pr list only accepts one --repo)
  _REVIEW_PARTS="[]"
  _AUTHORED_PARTS="[]"
  if [ ${#REPO_NAMES[@]} -gt 0 ]; then
    for RN in "${REPO_NAMES[@]}"; do
      _R=$(timeout 30 gh pr list --state open --search "review-requested:@me" \
        --json number,title,createdAt,repository --limit 20 --repo "$RN" 2>/dev/null || echo "[]")
      _REVIEW_PARTS=$(printf '%s\n%s' "$_REVIEW_PARTS" "$_R" | jq -s 'add' 2>/dev/null || echo "$_REVIEW_PARTS")

      _A=$(timeout 30 gh pr list --state open --author @me \
        --json number,title,createdAt,repository --limit 10 --repo "$RN" 2>/dev/null || echo "[]")
      _AUTHORED_PARTS=$(printf '%s\n%s' "$_AUTHORED_PARTS" "$_A" | jq -s 'add' 2>/dev/null || echo "$_AUTHORED_PARTS")
    done
  else
    _REVIEW_PARTS=$(timeout 30 gh pr list --state open --search "review-requested:@me" \
      --json number,title,createdAt,repository --limit 20 2>/dev/null || echo "[]")
    _AUTHORED_PARTS=$(timeout 30 gh pr list --state open --author @me \
      --json number,title,createdAt,repository --limit 10 2>/dev/null || echo "[]")
  fi
  export PR_REVIEW_REQUESTED="$_REVIEW_PARTS"
  export PR_AUTHORED="$_AUTHORED_PARTS"

  export PR_REVIEW_COUNT=$(echo "$PR_REVIEW_REQUESTED" | jq 'length' 2>/dev/null || echo 0)
  export PR_AUTHORED_COUNT=$(echo "$PR_AUTHORED" | jq 'length' 2>/dev/null || echo 0)
else
  export PR_REVIEW_REQUESTED="[]"
  export PR_AUTHORED="[]"
  export PR_REVIEW_COUNT=0
  export PR_AUTHORED_COUNT=0
fi

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
  export YESTERDAY_LOG_SUMMARY=$(sed -n '/eod-summary/,/^## /p' "$YESTERDAY_LOG" 2>/dev/null | head -20 || echo "no eod summary")
else
  export YESTERDAY_LOG_EXISTS=false
  export YESTERDAY_LOG_SUMMARY="no log"
fi

# --- Delegations (last 7 days) ---
if [ -d "$CEO_DIR/delegations" ]; then
  RECENT_DELEGATIONS=$(find "$CEO_DIR/delegations" -name "*.md" -not -name ".gitkeep" -mtime -7 2>/dev/null)
  if [ -n "$RECENT_DELEGATIONS" ]; then
    export DELEGATION_COMPLETED=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: completed" 2>/dev/null | wc -l | xargs)
    export DELEGATION_IN_PROGRESS=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: in-progress" 2>/dev/null | wc -l | xargs)
    export DELEGATION_FAILED=$(echo "$RECENT_DELEGATIONS" | xargs grep -l "^status: failed" 2>/dev/null | wc -l | xargs)
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
export SYNC_CONFLICT_COUNT=$(find "$CEO_DIR" -name "*.sync-conflict-*" -type f 2>/dev/null | wc -l | xargs)

# --- Daily note sections ---
DAILY_NOTE="$VAULT/Daily/$TODAY.md"
if [ -f "$DAILY_NOTE" ]; then
  export DAILY_NOTE_TOP3=$(sed -n '/^## Top 3/,/^## /p' "$DAILY_NOTE" 2>/dev/null | head -6 | tail -n +2 || echo "")
  export DAILY_NOTE_TASKS=$(sed -n '/^## Tasks/,/^## /p' "$DAILY_NOTE" 2>/dev/null | head -20 | tail -n +2 || echo "")
else
  export DAILY_NOTE_TOP3=""
  export DAILY_NOTE_TASKS=""
fi
