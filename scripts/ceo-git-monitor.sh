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
STATE_TMP=""
INBOX_TMP=""
DISCOVERY_TMP=""
trap 'rm -f "$STATE_TMP" "$INBOX_TMP" "$DISCOVERY_TMP"' EXIT

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

# A directory (or dangling symlink) is not an absent alert. In particular, mv
# would otherwise move the new state *inside* a directory and report success.
if { [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; } && [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: ceo-git-monitor: state is not a regular file: $STATE_FILE" >&2
  exit 1
fi

if [ -f "$STATE_FILE" ] && [ ! -r "$STATE_FILE" ]; then
  echo "ERROR: ceo-git-monitor: state is unreadable; preserving state and inbox" >&2
  exit 1
fi

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
    # awk also returns 2 on I/O failure. Only an actually absent state means
    # first run; unreadable existing state must not create a fresh incident.
    if [ -f "$STATE_FILE" ]; then
      echo "ERROR: ceo-git-monitor: failed to read existing state; preserving inbox" >&2
      exit 1
    fi
    PRIOR_STATUS="clear"
    ;;
  *)
    echo "ERROR: ceo-git-monitor: state reader failed; preserving state and inbox" >&2
    exit 1
    ;;
esac

read_optional_state_field() {
  local field="$1" default="$2" value rc=0
  value=$(ceo_read_alert_field "$STATE_FILE" "$field") || rc=$?
  case "$rc" in
    0) printf '%s' "$value" ;;
    1) printf '%s' "$default" ;;
    2)
      if [ -f "$STATE_FILE" ]; then
        echo "ERROR: ceo-git-monitor: failed to read $field from existing state" >&2
        return 1
      fi
      printf '%s' "$default"
      ;;
    *)
      echo "ERROR: ceo-git-monitor: failed to read state field $field" >&2
      return 1
      ;;
  esac
}
PRIOR_SINCE=$(read_optional_state_field since "") || exit 1

# Inbox delivery is a durable intent, not inferred solely from status changes.
# Missing fields are the pre-intent format; do not reopen acknowledged old tasks.
INBOX_PENDING=$(read_optional_state_field inbox_pending none) || exit 1
INBOX_INCIDENT=$(read_optional_state_field inbox_incident "") || exit 1
case "$INBOX_PENDING" in
  none|open|close) ;;
  *) echo "ERROR: ceo-git-monitor: invalid inbox_pending; preserving state and inbox" >&2; exit 1 ;;
esac

DIRTY_REPOS=()
BEHIND_REPOS=()
FETCH_FAILED_REPOS=()
UNCONFIGURED_REPOS=()
OBSERVATION_FAILED_REPOS=()
OBSERVATION_FAILED=0

# Prevent unattended git fetch from hanging on interactive prompts
export GIT_TERMINAL_PROMPT=0

for dir in "${SEARCH_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    # The defaults are optional locations. An explicitly configured location
    # disappearing is an incomplete scan, not proof its repositories recovered.
    if [ -n "${CEO_GIT_DIRS:-}" ]; then
      OBSERVATION_FAILED_REPOS+=("$dir (configured search directory unavailable)")
      OBSERVATION_FAILED=1
    fi
    continue
  fi

  # Process substitution discards find's exit code. Keep NUL-delimited paths in
  # a temporary file so permission/I/O errors cannot turn a partial scan clear.
  DISCOVERY_TMP=$(mktemp) || exit 1
  if ! find "$dir" -maxdepth 3 \( -type d -o -type f \) -name ".git" -print0 > "$DISCOVERY_TMP"; then
    OBSERVATION_FAILED_REPOS+=("$dir (repository discovery failed; scan incomplete)")
    OBSERVATION_FAILED=1
  fi

  # Find git repositories up to 3 levels deep (both directory .git and worktree file .git)
  while IFS= read -r -d '' gitentry; do
    repo=$(dirname "$gitentry")

    if [ "$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
      continue
    fi

    # 1. Check for dirty worktree
    if worktree_status=$(git -C "$repo" status --porcelain 2>/dev/null); then
      [ -z "$worktree_status" ] || DIRTY_REPOS+=("$repo")
    else
      OBSERVATION_FAILED_REPOS+=("$repo (unable to inspect worktree)")
      OBSERVATION_FAILED=1
    fi

    # 2. Check current branch and configured upstream
    branch=$(git -C "$repo" branch --show-current 2>/dev/null || true)
    if [ -z "$branch" ]; then
      head_desc=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      UNCONFIGURED_REPOS+=("$repo (detached or unresolved HEAD at $head_desc)")
      OBSERVATION_FAILED=1
      continue
    fi

    # Read configuration before resolving the ref: the first successful fetch
    # may create a missing tracking ref. A failed rev-parse can print '@{u}',
    # so nonempty stdout alone never proves that an upstream resolves.
    remote=$(git -C "$repo" config --get "branch.$branch.remote" 2>/dev/null || true)
    merge_ref=$(git -C "$repo" config --get "branch.$branch.merge" 2>/dev/null || true)
    if [ -z "$remote" ] || [ -z "$merge_ref" ]; then
      UNCONFIGURED_REPOS+=("$repo (branch '$branch' has no configured upstream)")
      OBSERVATION_FAILED=1
      continue
    fi

    # Fetch the configured source branch explicitly: generic fetch can succeed
    # after the remote branch was deleted while leaving a stale tracking ref.
    # Do not prune unrelated refs. Timeout keeps an unavailable remote bounded.
    fetch_ok=0
    if [ -n "${CEO_TIMEOUT_BIN:-}" ]; then
      "$CEO_TIMEOUT_BIN" 10 git -C "$repo" fetch -q -- "$remote" "$merge_ref" 2>/dev/null && fetch_ok=1 || true
    else
      git -C "$repo" fetch -q -- "$remote" "$merge_ref" 2>/dev/null && fetch_ok=1 || true
    fi

    if [ "$fetch_ok" -eq 0 ]; then
      FETCH_FAILED_REPOS+=("$repo (fetch failed for remote '$remote')")
      OBSERVATION_FAILED=1
    else
      if ! upstream_ref=$(git -C "$repo" rev-parse --symbolic-full-name --abbrev-ref '@{u}' 2>/dev/null) || [ -z "$upstream_ref" ]; then
        OBSERVATION_FAILED_REPOS+=("$repo (configured upstream could not be resolved after fetch)")
        OBSERVATION_FAILED=1
      elif ! behind=$(git -C "$repo" rev-list --count "HEAD..@{u}" 2>/dev/null); then
        OBSERVATION_FAILED_REPOS+=("$repo (unable to compare HEAD with $upstream_ref)")
        OBSERVATION_FAILED=1
      else
        case "$behind" in
          ''|*[!0-9]*)
            OBSERVATION_FAILED_REPOS+=("$repo (invalid comparison result for $upstream_ref)")
            OBSERVATION_FAILED=1
            ;;
          *)
            if [ "$behind" -gt 0 ]; then
              BEHIND_REPOS+=("$repo ($behind commits behind $upstream_ref)")
            fi
            ;;
        esac
      fi
    fi
  done < "$DISCOVERY_TMP"
  rm -f "$DISCOVERY_TMP"
  DISCOVERY_TMP=""
done

if [ ${#DIRTY_REPOS[@]} -gt 0 ] || [ ${#BEHIND_REPOS[@]} -gt 0 ] || [ "$OBSERVATION_FAILED" -eq 1 ]; then
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

if [ "$PRIOR_STATUS" != "unknown" ]; then
  if [ "$PRIOR_STATUS" = "clear" ] && [ "$CURRENT_STATUS" = "firing" ]; then
    INBOX_PENDING="open"
    INBOX_INCIDENT="$(date +%Y%m%dT%H%M%S)-$$"
  elif [ "$CURRENT_STATUS" = "clear" ] && { [ "$PRIOR_STATUS" = "firing" ] || [ "$INBOX_PENDING" = "open" ]; }; then
    # The condition recovered before an open could be delivered. Do not send a
    # stale escalation, but reconcile any task that was delivered before a crash.
    INBOX_PENDING="close"
  fi
fi

# Persist the intent before touching the inbox; acknowledge only after the inbox
# replacement succeeds. A failed write at either point is retryable next run.
write_state() {
  STATE_TMP=$(mktemp "${STATE_FILE}.XXXXXX") || {
    echo "ERROR: ceo-git-monitor: mktemp failed" >&2
    exit 1
  }

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
      --field observation_failed="$OBSERVATION_FAILED" \
      --field observation_failed_count="${#OBSERVATION_FAILED_REPOS[@]}" \
      --field inbox_pending="$INBOX_PENDING" \
      --field inbox_incident="$INBOX_INCIDENT" || {
        echo "ERROR: ceo-git-monitor: frontmatter write failed" >&2
        exit 1
      }
    printf '\n# Git Monitor\n\n'
    printf '<!-- alert: [[CEO/alerts/git-monitor]] -->\n\n'

    if [ "$CURRENT_STATUS" = "firing" ]; then
      printf 'Firing since %s.\n\n' "$SINCE"
      if [ "$OBSERVATION_FAILED" -eq 1 ]; then
        printf 'Repository freshness is unverified; this is not a confirmed recovery.\n\n'
      fi

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

    if [ ${#OBSERVATION_FAILED_REPOS[@]} -gt 0 ]; then
      printf '## Observation Failures\n\n'
      for r in "${OBSERVATION_FAILED_REPOS[@]}"; do
        printf -- '- `%s`\n' "$r"
      done
      printf '\n'
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

  if ! mv "$STATE_TMP" "$STATE_FILE"; then
    echo "ERROR: ceo-git-monitor: failed to replace $STATE_FILE" >&2
    exit 1
  fi
  STATE_TMP=""
}

write_state

TASK_MARKER="<!-- git-monitor -->"
INCIDENT_MARKER="<!-- git-monitor-incident: $INBOX_INCIDENT -->"
TASK_LINE="- [ ] Review dirty, outdated, or unverified git repositories — see [[CEO/alerts/git-monitor]] $TASK_MARKER $INCIDENT_MARKER"
DONE_NOTE="- [done] Git repositories verified clean and up to date $(date +%Y-%m-%d) $TASK_MARKER"
INBOX_CHANGED=0

# Return 0/1 only for present/absent. Read failures must abort instead of being
# interpreted as absence (which would acknowledge an undelivered intent).
inbox_task_present() {
  local mode="$1" result
  if [ ! -e "$INBOX_FILE" ] && [ ! -L "$INBOX_FILE" ]; then
    return 1
  fi
  if [ ! -f "$INBOX_FILE" ]; then
    echo "ERROR: ceo-git-monitor: inbox is not a regular file: $INBOX_FILE" >&2
    exit 1
  fi
  result=$(awk -v m="$TASK_MARKER" -v i="$INCIDENT_MARKER" -v mode="$mode" '
    mode == "close" && /^- \[ \]/ && index($0, m) { found=1 }
    mode == "open" && index($0, i) { found=1 }
    END { print found ? "present" : "absent" }
  ' "$INBOX_FILE") || {
    echo "ERROR: ceo-git-monitor: failed to read $INBOX_FILE" >&2
    exit 1
  }
  [ "$result" = "present" ]
}

if [ "$PRIOR_STATUS" != "unknown" ] && [ "$INBOX_PENDING" != "none" ]; then
  if [ "$INBOX_PENDING" = "open" ] && ! inbox_task_present open; then
    INBOX_TMP=$(mktemp "${INBOX_FILE}.XXXXXX") || exit 1
    # Copy + append + rename keeps partial appends from becoming duplicate or
    # truncated tasks. Explicit guards also cover bash 3.2 redirection failures.
    if inbox_task_present close; then
      # Adopt an already-open task into this incident before acknowledging. If
      # the ack fails and a human checks it off, the retry recognizes delivery.
      if ! awk -v m="$TASK_MARKER" -v i="$INCIDENT_MARKER" '
        !adopted && /^- \[ \]/ && index($0, m) { print $0 " " i; adopted=1; next }
        { print }
      ' "$INBOX_FILE" > "$INBOX_TMP"; then
        echo "ERROR: ceo-git-monitor: failed to adopt existing inbox task" >&2
        exit 1
      fi
    else
      if [ -e "$INBOX_FILE" ]; then
        cat "$INBOX_FILE" > "$INBOX_TMP" || exit 1
        # A human-edited final line may have no newline. Keep the new task on
        # its own line so recovery and task consumers can still recognize it.
        if [ -s "$INBOX_TMP" ]; then
          last_byte=$(tail -c 1 "$INBOX_TMP") || exit 1
          if [ -n "$last_byte" ]; then
            printf '\n' >> "$INBOX_TMP" || exit 1
          fi
        fi
      fi
      if ! printf '%s\n' "$TASK_LINE" >> "$INBOX_TMP"; then
        echo "ERROR: ceo-git-monitor: failed to append inbox task" >&2
        exit 1
      fi
    fi
    mv "$INBOX_TMP" "$INBOX_FILE" || exit 1
    INBOX_TMP=""
    INBOX_CHANGED=1
  elif [ "$INBOX_PENDING" = "close" ] && [ "$OBSERVATION_FAILED" -eq 0 ] && inbox_task_present close; then
    INBOX_TMP=$(mktemp "${INBOX_FILE}.XXXXXX") || exit 1
    if ! awk -v m="$TASK_MARKER" -v r="$DONE_NOTE" \
      '/^- \[ \]/ && index($0, m) { print r; next } { print }' "$INBOX_FILE" > "$INBOX_TMP"; then
      echo "ERROR: ceo-git-monitor: failed to rewrite $INBOX_FILE" >&2
      exit 1
    fi
    mv "$INBOX_TMP" "$INBOX_FILE" || exit 1
    INBOX_TMP=""
    INBOX_CHANGED=1
  fi

  INBOX_PENDING="none"
  write_state
fi

if [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  if [ "$INBOX_CHANGED" -eq 1 ]; then
    printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
  else
    printf 'noop' > "$CEO_RUNNER_OUTCOME_FILE"
  fi
fi

exit 0
