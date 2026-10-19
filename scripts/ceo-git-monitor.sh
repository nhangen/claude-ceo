#!/bin/bash
# ceo-git-monitor.sh — Checks git repositories for dirty worktrees and out-of-date branches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path
ceo_resolve_timeout_bin

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
ALERTS_DIR="$CEO_DIR/alerts"
INBOX_DIR="$CEO_DIR/inbox"
STATE_FILE="$ALERTS_DIR/git-monitor.md"
INBOX_FILE="$INBOX_DIR/git-monitor.md"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

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

# Read prior state from alert frontmatter
PRIOR_STATUS=""
PRIOR_SINCE=""
_status_rc=0
PRIOR_STATUS=$(ceo_read_alert_field "$STATE_FILE" status) || _status_rc=$?
case "$_status_rc" in
  0)
    case "$PRIOR_STATUS" in
      clear|firing) ;;
      *)
        printf 'WARN: ceo-git-monitor: unrecognized prior status %q in %s; refusing inbox mutation\n' \
          "$PRIOR_STATUS" "$STATE_FILE" >&2
        PRIOR_STATUS="unknown"
        ;;
    esac
    ;;
  1)
    printf 'WARN: ceo-git-monitor: state file %s present but missing status field; refusing inbox mutation\n' \
      "$STATE_FILE" >&2
    PRIOR_STATUS="unknown"
    ;;
  2)
    PRIOR_STATUS="clear"
    ;;
esac
PRIOR_SINCE=$(ceo_read_alert_field "$STATE_FILE" since 2>/dev/null) || PRIOR_SINCE=""

DIRTY_REPOS=()
BEHIND_REPOS=()
FETCH_FAILED_REPOS=()
UNCONFIGURED_REPOS=()
OBSERVATION_FAILED=0

# Prevent unattended git fetch from hanging on interactive prompts
export GIT_TERMINAL_PROMPT=0

for dir in "${SEARCH_DIRS[@]}"; do
  [ -d "$dir" ] || continue

  # Find git repositories up to 3 levels deep (both directory .git and worktree file .git)
  while IFS= read -r -d '' gitentry; do
    repo=$(dirname "$gitentry")

    if [ "$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
      continue
    fi

    # 1. Check for dirty worktree
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
      DIRTY_REPOS+=("$repo")
    fi

    # 2. Check current branch and configured upstream
    branch=$(git -C "$repo" branch --show-current 2>/dev/null || true)
    if [ -z "$branch" ]; then
      head_desc=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      UNCONFIGURED_REPOS+=("$repo (detached HEAD at $head_desc)")
      continue
    fi

    upstream_ref=$(git -C "$repo" rev-parse --symbolic-full-name --abbrev-ref '@{u}' 2>/dev/null || true)
    if [ -z "$upstream_ref" ]; then
      UNCONFIGURED_REPOS+=("$repo (branch '$branch' has no configured upstream)")
      continue
    fi

    # Resolve remote for this branch
    remote=$(git -C "$repo" config --get "branch.$branch.remote" 2>/dev/null || true)
    [ -z "$remote" ] && remote="${upstream_ref%%/*}"

    # Fetch with timeout so offline network / invalid remotes don't hang
    fetch_ok=0
    if [ -n "${CEO_TIMEOUT_BIN:-}" ] && command -v "$CEO_TIMEOUT_BIN" >/dev/null 2>&1; then
      "$CEO_TIMEOUT_BIN" 10 git -C "$repo" fetch "$remote" -q 2>/dev/null && fetch_ok=1 || true
    elif command -v timeout >/dev/null 2>&1; then
      timeout 10 git -C "$repo" fetch "$remote" -q 2>/dev/null && fetch_ok=1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout 10 git -C "$repo" fetch "$remote" -q 2>/dev/null && fetch_ok=1 || true
    else
      git -C "$repo" fetch "$remote" -q 2>/dev/null && fetch_ok=1 || true
    fi

    if [ "$fetch_ok" -eq 0 ]; then
      FETCH_FAILED_REPOS+=("$repo (fetch failed for remote '$remote')")
      OBSERVATION_FAILED=1
    else
      behind=$(git -C "$repo" rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        BEHIND_REPOS+=("$repo ($behind commits behind $upstream_ref)")
      fi
    fi
  done < <(find "$dir" -maxdepth 3 \( -type d -o -type f \) -name ".git" -print0 2>/dev/null || true)
done

if [ ${#DIRTY_REPOS[@]} -gt 0 ] || [ ${#BEHIND_REPOS[@]} -gt 0 ] || [ ${#FETCH_FAILED_REPOS[@]} -gt 0 ]; then
  CURRENT_STATUS="firing"
else
  CURRENT_STATUS="clear"
fi

# SINCE only resets on a state transition; unchanged status preserves prior timestamp
if [ "$CURRENT_STATUS" = "$PRIOR_STATUS" ] && [ -n "$PRIOR_SINCE" ]; then
  SINCE="$PRIOR_SINCE"
else
  SINCE="$NOW"
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
    --since="$SINCE" \
    --last-check="$NOW" \
    --host="$HOST" \
    --field dirty_count="${#DIRTY_REPOS[@]}" \
    --field behind_count="${#BEHIND_REPOS[@]}" \
    --field fetch_failed_count="${#FETCH_FAILED_REPOS[@]}" \
    --field unconfigured_count="${#UNCONFIGURED_REPOS[@]}" \
    --field observation_failed="$OBSERVATION_FAILED"
  printf '\n# Git Monitor\n\n'
  printf '<!-- alert: [[CEO/alerts/git-monitor]] -->\n\n'

  if [ "$CURRENT_STATUS" = "firing" ]; then
    printf 'Firing since %s.\n\n' "$SINCE"

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

    if [ ${#FETCH_FAILED_REPOS[@]} -gt 0 ]; then
      printf '## Fetch Failures\n\n'
      printf 'The following repositories could not be refreshed against their upstream remote:\n\n'
      for r in "${FETCH_FAILED_REPOS[@]}"; do
        printf -- '- `%s`\n' "$r"
      done
      printf '\n'
    fi
  else
    printf 'All tracked repositories are clean and up to date.\n\n'
  fi

  if [ ${#UNCONFIGURED_REPOS[@]} -gt 0 ]; then
    printf '## Unconfigured Upstreams\n\n'
    for r in "${UNCONFIGURED_REPOS[@]}"; do
      printf -- '- `%s`\n' "$r"
    done
    printf '\n'
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
INBOX_CHANGED=0

touch "$INBOX_FILE"
active_task_present() {
  awk -v m="$TASK_MARKER" '/^- \[ \]/ && index($0, m) { found=1; exit } END { exit !found }' "$INBOX_FILE"
}

if [ "$PRIOR_STATUS" != "unknown" ]; then
  if [ "$PRIOR_STATUS" = "clear" ] && [ "$CURRENT_STATUS" = "firing" ]; then
    if ! active_task_present; then
      printf '%s\n' "$TASK_LINE" >> "$INBOX_FILE"
      INBOX_CHANGED=1
    fi
  elif [ "$OBSERVATION_FAILED" -eq 0 ] && [ "$PRIOR_STATUS" = "firing" ] && [ "$CURRENT_STATUS" = "clear" ]; then
    if active_task_present; then
      tmpfile=$(mktemp "${INBOX_FILE}.XXXXXX") || {
        echo "ERROR: ceo-git-monitor: mktemp failed for inbox rewrite" >&2
        exit 1
      }
      trap 'rm -f "$tmpfile"' EXIT
      if ! awk -v m="$TASK_MARKER" -v r="$DONE_NOTE" \
        '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$tmpfile"; then
        echo "ERROR: ceo-git-monitor: failed to rewrite $INBOX_FILE" >&2
        exit 1
      fi
      if ! mv "$tmpfile" "$INBOX_FILE"; then
        echo "ERROR: ceo-git-monitor: failed to replace $INBOX_FILE" >&2
        exit 1
      fi
      trap - EXIT
      INBOX_CHANGED=1
    fi
  fi
fi

if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  if [ "$INBOX_CHANGED" -eq 1 ]; then
    printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
  else
    printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"
  fi
fi

exit 0
