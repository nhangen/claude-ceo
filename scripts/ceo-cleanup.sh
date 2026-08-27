#!/bin/bash
set -euo pipefail

# ceo-cleanup.sh — Deterministic cleanup steps for the CEO agent.
# Handles: merged branch cleanup, sync conflict detection, old log counting.
# Returns structured data for the AI to use for orphan judgment and log writing.
#
# Usage: ceo-cleanup.sh
# Requires: CEO_VAULT env var or defaults to ~/Documents/Obsidian

_CLEANUP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$_CLEANUP_DIR/ceo-config.sh"
# shellcheck source=ceo-loop-lib.sh
source "$_CLEANUP_DIR/ceo-loop-lib.sh"
ceo_require_vault

# A branch name is usable as an ancestry target only if it resolves to a commit
# on this host — as a remote-tracking ref or as a local branch. Used to reject a
# stale origin/HEAD before it is trusted as the default branch.
ceo_branch_resolves() { # <repo-path> <branch-name>
  git -C "$1" rev-parse --verify -q "refs/remotes/origin/$2" >/dev/null 2>&1 \
    || git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1
}

VAULT="$CEO_VAULT"
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
REAP_FAILED_COUNT=0
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

    # Resolve default branch: origin/HEAD -> main -> master.
    #
    # `symbolic-ref` does not verify its target, and a remote that renames its
    # default branch leaves the symref pointing at a ref that no longer exists.
    # Accepting that name unchecked reproduces the bug this reaper exists to fix:
    # both ancestry probes below reference a dead ref, both exit 128 into
    # /dev/null, and nothing is ever reaped or reported (#341).
    DEFAULT_BRANCH="$(git -C "$REPO_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
    if [ -n "$DEFAULT_BRANCH" ] \
       && ! ceo_branch_resolves "$REPO_PATH" "$DEFAULT_BRANCH"; then
      DEFAULT_BRANCH=""
    fi
    if [ -z "$DEFAULT_BRANCH" ]; then
      if ceo_branch_resolves "$REPO_PATH" main; then
        DEFAULT_BRANCH="main"
      elif ceo_branch_resolves "$REPO_PATH" master; then
        DEFAULT_BRANCH="master"
      else
        # Inventing a name here would hand both ancestry probes a ref that
        # resolves nowhere, so every branch reads as unmerged and the repo is
        # silently skipped anyway — as an "all branches active" report rather
        # than as the failure it is.
        echo "  DEFAULT_BRANCH_UNRESOLVED: no origin/HEAD, main, or master"
        continue
      fi
    fi
    echo "  DEFAULT_BRANCH: $DEFAULT_BRANCH"

    # Fetch default branch once per repo if remote exists
    git -C "$REPO_PATH" fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true

    # List CEO branches
    CEO_BRANCHES=$(git -C "$REPO_PATH" branch --list --format="%(refname:short)" "${BRANCH_PREFIX}*" 2>/dev/null || true)

    if [ -z "$CEO_BRANCHES" ]; then
      echo "  BRANCHES: none"
      continue
    fi

    for BRANCH in $CEO_BRANCHES; do
      # Check if branch is merged into default branch (origin or local)
      if git -C "$REPO_PATH" merge-base --is-ancestor "$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null \
         || git -C "$REPO_PATH" merge-base --is-ancestor "$BRANCH" "$DEFAULT_BRANCH" 2>/dev/null; then
        echo "  MERGED: $BRANCH"

        # Find and remove worktree for this branch
        WT_PATH=$(git -C "$REPO_PATH" worktree list --porcelain 2>/dev/null | awk -v target="branch refs/heads/$BRANCH" '/^worktree /{wt=substr($0, 10)} $0==target{print wt}')
        if [ -n "$WT_PATH" ] && [ -d "$WT_PATH" ]; then
          git -C "$REPO_PATH" worktree remove "$WT_PATH" 2>/dev/null && echo "  WORKTREE_REMOVED: $WT_PATH" || echo "  WORKTREE_REMOVE_FAILED: $WT_PATH"
        fi

        # Delete local branch, and only then its ownership marker (#338).
        #
        # The two judgments disagree: the ancestry probe above is answered by
        # origin/$DEFAULT_BRANCH, while `branch -d` is answered by the local
        # branch. In a clone whose local default branch lags the remote — the
        # ordinary state — the first says merged and the second refuses. Deleting
        # the marker there leaves the branch standing with no ownership record,
        # and ceo-loop then reads it as a stranger's branch and refuses it
        # forever (exit 6), recoverable only by a hand-written update-ref (#341).
        if git -C "$REPO_PATH" branch -d "$BRANCH" 2>/dev/null; then
          echo "  BRANCH_DELETED: $BRANCH"
          MERGED_COUNT=$((MERGED_COUNT + 1))
          OWNED_REF="refs/ceo-loop/owned/$(branch_key "$BRANCH")"
          if git -C "$REPO_PATH" show-ref --verify -q "$OWNED_REF" 2>/dev/null; then
            git -C "$REPO_PATH" update-ref -d "$OWNED_REF" 2>/dev/null \
              && echo "  MARKER_DELETED: $OWNED_REF" \
              || echo "  MARKER_DELETE_FAILED: $OWNED_REF"
          fi
        else
          echo "  BRANCH_DELETE_FAILED: $BRANCH"
          REAP_FAILED_COUNT=$((REAP_FAILED_COUNT + 1))
        fi
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
echo "REAP_FAILED: $REAP_FAILED_COUNT"

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
fi

echo ""
if [ -n "$ORPHAN_BRANCHES" ] && [ "$REAP_FAILED_COUNT" -gt 0 ]; then
  echo "AI_NEEDED: yes — review orphaned branches; $REAP_FAILED_COUNT merged branch(es) failed to reap (check worktree or local branch lag)"
elif [ -n "$ORPHAN_BRANCHES" ]; then
  echo "AI_NEEDED: yes — review orphaned branches and decide whether to propose deletion"
elif [ "$REAP_FAILED_COUNT" -gt 0 ]; then
  echo "AI_NEEDED: yes — $REAP_FAILED_COUNT merged branch(es) failed to reap (check worktree or local branch lag)"
else
  echo "AI_NEEDED: no — all branches are merged or active"
fi
