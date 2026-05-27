#!/bin/bash
# ceo-git-monitor.sh — Checks git repositories for dirty worktrees and out-of-date branches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
ALERTS_DIR="$CEO_DIR/alerts"
INBOX_DIR="$CEO_DIR/inbox"
STATE_FILE="$ALERTS_DIR/git-monitor.md"
INBOX_FILE="$INBOX_DIR/git-monitor.md"

mkdir -p "$ALERTS_DIR" "$INBOX_DIR"

# Configurable search directories
if [ -n "${CEO_GIT_DIRS:-}" ]; then
  read -ra SEARCH_DIRS <<< "$CEO_GIT_DIRS"
else
  SEARCH_DIRS=(
    "$HOME/Code"
    "$HOME/ML-AI"
    "$HOME/Documents/Obsidian/Projects/Development"
    "$HOME/Documents/Obsidian/Awesome Motive"
  )
fi

NOW=$(date +%Y-%m-%dT%H:%M:%S%z)

DIRTY_REPOS=()
BEHIND_REPOS=()

for dir in "${SEARCH_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    continue
  fi
  
  # Find git repositories up to 3 levels deep
  while IFS= read -r -d '' gitdir; do
    repo=$(dirname "$gitdir")
    cd "$repo" || continue
    
    # 1. Check for dirty worktree
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      DIRTY_REPOS+=("$repo")
    fi
    
    # 2. Check if behind origin
    if git config --get remote.origin.url >/dev/null 2>&1; then
      # Timeout fetch so it doesn't hang on auth prompts
      if command -v timeout >/dev/null 2>&1; then
        timeout 10 git fetch origin -q 2>/dev/null || true
      elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 10 git fetch origin -q 2>/dev/null || true
      else
        git fetch origin -q 2>/dev/null || true
      fi

      branch=$(git branch --show-current 2>/dev/null || true)
      if [ -n "$branch" ]; then
        behind=$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
        if [ "$behind" -gt 0 ]; then
          BEHIND_REPOS+=("$repo ($behind commits behind)")
        fi
      fi
    fi
  done < <(find "$dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null || true)
done

if [ ${#DIRTY_REPOS[@]} -eq 0 ] && [ ${#BEHIND_REPOS[@]} -eq 0 ]; then
  CURRENT_STATUS="clear"
else
  CURRENT_STATUS="firing"
fi

# Render state file atomically
STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
  echo "ERROR: ceo-git-monitor: mktemp failed" >&2
  exit 1
}
trap 'rm -f "$STATE_TMP"' EXIT

if ! {
  ceo_write_alert_frontmatter \
    --status="$CURRENT_STATUS" \
    --since="$NOW" \
    --last-check="$NOW" \
    --host="$(hostname -s)"
  printf '\n# Git Monitor\n\n'
  printf '<!-- alert: [[CEO/alerts/git-monitor]] -->\n\n'
  
  if [ "$CURRENT_STATUS" = "firing" ]; then
    if [ ${#DIRTY_REPOS[@]} -gt 0 ]; then
      printf '## Dirty Worktrees\n\n'
      for r in "${DIRTY_REPOS[@]}"; do
        printf -- '- `%s`\n' "$r"
      done
      printf '\n'
    fi
    
    if [ ${#BEHIND_REPOS[@]} -gt 0 ]; then
      printf '## Out of Date Branches\n\n'
      for r in "${BEHIND_REPOS[@]}"; do
        printf -- '- `%s`\n' "$r"
      done
      printf '\n'
    fi
  else
    printf 'All tracked repositories are clean and up to date.\n'
  fi
} > "$STATE_TMP"; then
  echo "ERROR: ceo-git-monitor: failed to render state" >&2
  exit 1
fi

mv "$STATE_TMP" "$STATE_FILE"
trap - EXIT

# Inbox escalation logic
TASK_MARKER="<!-- git-monitor -->"
TASK_LINE="- [ ] Clean up dirty or outdated git repositories — see [[CEO/alerts/git-monitor]] $TASK_MARKER"
DONE_NOTE="- [done] Git repositories cleaned $(date +%Y-%m-%d) $TASK_MARKER"

touch "$INBOX_FILE"
active_task_present() {
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

if [ "$CURRENT_STATUS" = "firing" ]; then
  if ! active_task_present; then
    printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
  fi
elif [ "$CURRENT_STATUS" = "clear" ]; then
  if active_task_present; then
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT
    _done_replacement="- [done] Git repositories cleaned $(date +%Y-%m-%d) $TASK_MARKER"
    awk -v m="$TASK_MARKER" -v r="$_done_replacement" \
      '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$tmpfile"
    mv "$tmpfile" "$INBOX_FILE"
    trap - EXIT
    printf '%s\n' "$DONE_NOTE" >> "$INBOX_FILE"
  fi
fi

exit 0
