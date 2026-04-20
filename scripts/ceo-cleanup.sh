#!/bin/bash
set -euo pipefail

# ceo-cleanup.sh — Deterministic cleanup steps for the CEO agent.
# Handles: merged branch cleanup, sync conflict detection, old log counting.
# Returns structured data for the AI to use for orphan judgment and log writing.
#
# Usage: ceo-cleanup.sh
# Requires: CEO_VAULT env var or defaults to ~/Documents/Obsidian

VAULT="${CEO_VAULT:-$HOME/Documents/Obsidian}"
CEO_DIR="$VAULT/CEO"
LOG_DIR="$CEO_DIR/log"
REPOS_FILE="$CEO_DIR/repos.md"
TODAY=$(date +%Y-%m-%d)

# Read branch prefix from settings
SETTINGS_FILE="$CEO_DIR/settings.json"
if command -v jq &>/dev/null && [ -f "$SETTINGS_FILE" ]; then
  BRANCH_PREFIX=$(jq -r '.branch_prefix // "ceo/"' "$SETTINGS_FILE" 2>/dev/null || echo "ceo/")
else
  BRANCH_PREFIX="ceo/"
fi

echo "CLEANUP_DATE: $TODAY"
echo ""

# --- Process each cloned repo ---
MERGED_COUNT=0
ORPHAN_BRANCHES=""
HAS_REPOS=false

if [ -f "$REPOS_FILE" ]; then
  if ! head -1 "$REPOS_FILE" | grep -q "Local Path"; then
    echo "WARNING: repos.md header doesn't contain 'Local Path' column — column parsing may be wrong"
  fi
  while IFS= read -r REPO_PATH; do
    REPO_PATH=$(echo "$REPO_PATH" | xargs)
    [ -z "$REPO_PATH" ] && continue
    HAS_REPOS=true
    if [ ! -d "$REPO_PATH" ]; then
      echo "REPO_MISSING: $REPO_PATH"
      continue
    fi

    echo "REPO: $REPO_PATH"

    # List CEO worktrees
    WORKTREES=$(git -C "$REPO_PATH" worktree list --porcelain 2>/dev/null | grep "^worktree" | grep -v "$REPO_PATH$" || true)

    # List CEO branches
    CEO_BRANCHES=$(git -C "$REPO_PATH" branch --list "${BRANCH_PREFIX}*" 2>/dev/null | sed 's/^[* ]*//' || true)

    if [ -z "$CEO_BRANCHES" ]; then
      echo "  BRANCHES: none"
      continue
    fi

    for BRANCH in $CEO_BRANCHES; do
      # Check if branch is merged into origin/master
      git -C "$REPO_PATH" fetch origin master --quiet 2>/dev/null || true
      if git -C "$REPO_PATH" merge-base --is-ancestor "$BRANCH" origin/master 2>/dev/null; then
        echo "  MERGED: $BRANCH"

        # Find and remove worktree for this branch
        WT_PATH=$(git -C "$REPO_PATH" worktree list --porcelain 2>/dev/null | grep -B1 "branch refs/heads/$BRANCH" | grep "^worktree" | sed 's/worktree //' || true)
        if [ -n "$WT_PATH" ] && [ -d "$WT_PATH" ]; then
          git -C "$REPO_PATH" worktree remove "$WT_PATH" 2>/dev/null && echo "  WORKTREE_REMOVED: $WT_PATH" || echo "  WORKTREE_REMOVE_FAILED: $WT_PATH"
        fi

        # Delete local branch
        git -C "$REPO_PATH" branch -d "$BRANCH" 2>/dev/null && echo "  BRANCH_DELETED: $BRANCH" || echo "  BRANCH_DELETE_FAILED: $BRANCH"
        MERGED_COUNT=$((MERGED_COUNT + 1))
      else
        # Check if branch has an open PR
        REPO_NAME=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/' || echo "unknown")
        HAS_PR=$(gh pr list --repo "$REPO_NAME" --head "$BRANCH" --state open --limit 1 --json number 2>/dev/null || echo "[]")

        # Check last commit date
        LAST_COMMIT=$(git -C "$REPO_PATH" log -1 --format="%ci" "$BRANCH" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        LAST_COMMIT_EPOCH=$(git -C "$REPO_PATH" log -1 --format="%ct" "$BRANCH" 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        AGE_DAYS=$(( (NOW_EPOCH - LAST_COMMIT_EPOCH) / 86400 ))

        if [ "$HAS_PR" = "[]" ] && [ "$AGE_DAYS" -gt 7 ]; then
          echo "  ORPHAN: $BRANCH (no PR, $AGE_DAYS days old, last commit: $LAST_COMMIT)"
          ORPHAN_BRANCHES="$ORPHAN_BRANCHES\n  - $REPO_NAME: $BRANCH ($AGE_DAYS days, no PR)"
        else
          PR_NUM=$(echo "$HAS_PR" | jq '.[0].number // empty' 2>/dev/null || echo "")
          echo "  ACTIVE: $BRANCH (PR: ${PR_NUM:-none}, age: ${AGE_DAYS}d)"
        fi
      fi
    done
    echo ""
  done < <(grep "^|" "$REPOS_FILE" | grep -v "^| Repo\|^|---\|No repos" | awk -F'|' '{print $3}')
fi

if [ "$HAS_REPOS" = false ]; then
  echo "NO_REPOS: repos.md is empty or has no data rows"
fi

echo "MERGED_TOTAL: $MERGED_COUNT"

# --- Sync conflicts ---
CONFLICTS=$(find "$CEO_DIR" -name "*.sync-conflict-*" -type f 2>/dev/null || true)
CONFLICT_COUNT=$(echo "$CONFLICTS" | grep -c "." 2>/dev/null || echo 0)
echo ""
echo "SYNC_CONFLICTS: $CONFLICT_COUNT"
if [ -n "$CONFLICTS" ] && [ "$CONFLICT_COUNT" -gt 0 ]; then
  echo "$CONFLICTS" | while read -r f; do echo "  CONFLICT_FILE: $f"; done
fi

# --- Old log files ---
OLD_LOGS=$(find "$LOG_DIR" -name "*.md" -not -name ".gitkeep" -mtime +30 2>/dev/null | wc -l | xargs)
echo ""
echo "OLD_LOGS: $OLD_LOGS (>30 days)"

# --- Orphan summary for AI judgment ---
if [ -n "$ORPHAN_BRANCHES" ]; then
  echo ""
  echo "ORPHAN_SUMMARY:"
  printf '%b\n' "$ORPHAN_BRANCHES"
  echo ""
  echo "AI_NEEDED: yes — review orphaned branches and decide whether to propose deletion"
else
  echo ""
  echo "AI_NEEDED: no — all branches are merged or active"
fi
