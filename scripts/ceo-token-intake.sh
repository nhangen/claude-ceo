#!/bin/bash
# ceo-token-intake.sh — Daily RTK + token-scope spend intake.
# Captures four command outputs to CEO/reports/token/<TODAY>-<host>.md and
# idempotently appends one inbox line to CEO/inbox/<host>.md linking to it.
# Per-host filenames keep two Syncthing peers from racing on the same path.
# The chat-triggered inbox playbook surfaces the line via `ceo chat inbox`.
#
# Invoked by ceo-cron.sh when the token-intake playbook (runner:script) fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }

# rtk and ccusage discover their state via $HOME-rooted paths
# (Library/Application Support/rtk/history.db on Mac, .local/share on Linux).
# Pin $HOME BEFORE ceo_augment_path so PATH augmentation reads the real
# user's home (~/.bun/bin etc.) instead of a scrubbed/sandboxed value. The
# helper warns to stderr on resolver failure; we proceed regardless so
# cron-invoked runs aren't blocked by an unresolvable user identity.
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"
INBOX_DIR="$CEO_DIR/inbox"
INBOX_FILE="$INBOX_DIR/$HOST.md"
TOKEN_DIR="$CEO_DIR/reports/token"
TODAY=$(date +%Y-%m-%d)
REPORT_FILE="$TOKEN_DIR/$TODAY-$HOST.md"
WIKILINK="[[CEO/reports/token/$TODAY-$HOST]]"
INBOX_LINE="- [ ] Review daily token report $WIKILINK"

mkdir -p "$TOKEN_DIR" "$INBOX_DIR"

# capture <label> <cmd> [args...] — run a command and wrap its output in a fenced block.
# Writes a sentinel into the report on failure so the link resolves to readable
# content, AND returns non-zero so the script exits non-zero and ceo-cron records
# a failure (otherwise a missing/broken binary leaves cron telemetry green).
CAPTURE_FAILED=0
capture() {
  local label="$1"; shift
  local cmd="$1"
  printf '\n## %s\n\n```\n' "$label"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '%s unavailable on PATH=%s\n' "$cmd" "$PATH"
    printf '```\n'
    echo "ERROR: capture: '$cmd' not on PATH" >&2
    CAPTURE_FAILED=1
    return 0
  fi
  local rc=0
  "$@" 2>&1 || rc=$?
  printf '```\n'
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: capture: '$cmd' exited $rc" >&2
    CAPTURE_FAILED=1
  fi
  return 0
}

# check_auth_health — flag when this host's Claude runs produce nothing.
# The reliable signal is NOT "an authentication_failed turn exists" — transient
# 401s and aborted micro-sessions are ambient noise even on a healthy, logged-in
# host (a busy dev box shows hundreds). The signal is: sessions WERE attempted in
# the last 48h but NONE produced a successful, token-bearing turn. A logged-out
# host (or otherwise broken auth) writes error-only sessions with 0 output tokens,
# so its token report goes empty and the outage hides for days.
#
# Keying on success (not on the error string) also sidesteps a self-referential
# false positive: a session that merely *discusses* authentication_failed embeds
# the string in .message.content, but has real successful turns too, so it reads
# as healthy. The top-level .isApiErrorMessage/.error fields only ENRICH the
# message when we already know the host produced nothing. jq inspects the object
# root; no jq → skip (never guess). Always returns 0 — informational, not a run failure.
AUTH_ALERT=""
check_auth_health() {
  local pdir="$HOME/.claude/projects"
  if [ ! -d "$pdir" ]; then
    printf 'no Claude projects dir at %s — nothing to check\n' "$pdir"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'SKIP: jq not on PATH; cannot inspect session outcomes without false positives.\n'
    return 0
  fi
  local recent=0 has_success=0 saw_autherr=0 f
  while IFS= read -r f; do
    recent=$((recent + 1))
    if [ -n "$(jq -c 'select((.message.usage.output_tokens // 0) > 0)' "$f" 2>/dev/null | head -1)" ]; then
      has_success=1
      break
    fi
    if [ "$saw_autherr" -eq 0 ] \
       && jq -e 'select(.isApiErrorMessage == true and .error == "authentication_failed")' "$f" >/dev/null 2>&1; then
      saw_autherr=1
    fi
  done < <(find "$pdir" -type f -name '*.jsonl' -mtime -2 2>/dev/null)

  if [ "$recent" -eq 0 ]; then
    printf 'OK: no Claude sessions in the last 48h (host idle — nothing to verify).\n'
    return 0
  fi
  if [ "$has_success" -eq 1 ]; then
    printf 'OK: host produced successful Claude turns in the last 48h.\n'
    return 0
  fi

  local why="producing no successful output (check auth/network)"
  [ "$saw_autherr" -eq 1 ] && why="LOGGED OUT — recent turns report authentication_failed"
  AUTH_ALERT="Claude on $HOST ran $recent session(s) in the last 48h but produced zero successful turns: $why. Scheduled automation is failing silently. Fix: ssh to this host, run \`claude\`, then /login."
  printf 'WARN: %s\n' "$AUTH_ALERT"
  return 0
}

# Resolve token-scope from the Claude Code plugin cache rather than PATH —
# the plugin doesn't install a wrapper, and stale ~/.bun/bin symlinks from
# prior standalone installs satisfy `command -v` but dangle. See #37.
# Avoid mapfile here: macOS ships bash 3.2 by default, which lacks it.
TS_CMD=(token-scope)
_ts_resolved=""
if _ts_resolved=$(ceo_resolve_plugin_cli "nhangen-tools/token-scope" "src/cli.ts" 2>/dev/null); then
  _ts_runtime=$(printf '%s\n' "$_ts_resolved" | sed -n '1p')
  _ts_path=$(printf '%s\n' "$_ts_resolved" | sed -n '2p')
  if [ -n "$_ts_runtime" ] && [ -n "$_ts_path" ]; then
    TS_CMD=("$_ts_runtime" "$_ts_path")
  fi
fi
if [ "${TS_CMD[0]}" = "token-scope" ]; then
  echo "WARN: token-scope plugin cache not resolved; falling back to PATH (stale symlinks may dangle)" >&2
fi
unset _ts_resolved _ts_runtime _ts_path

if ! {
  printf -- '---\ndate: %s\ntype: ceo-token-intake\n---\n\n' "$TODAY"
  printf '# Token Report — %s\n' "$TODAY"
  capture "RTK — global savings" rtk gain
  capture "ccusage — Claude Code monthly" npx --yes ccusage@latest monthly
  capture "token-scope — last 24h" "${TS_CMD[@]}" --since 1d
  capture "auth health" check_auth_health
} > "$REPORT_FILE"; then
  echo "ERROR: failed to write $REPORT_FILE" >&2
  exit 1
fi
[ -s "$REPORT_FILE" ] || { echo "ERROR: empty report $REPORT_FILE" >&2; exit 1; }
if [ "$CAPTURE_FAILED" -ne 0 ]; then
  echo "ERROR: one or more capture commands failed; see report $REPORT_FILE" >&2
  exit 1
fi

# Idempotently append the inbox line. Dedupe on the wikilink target
# rather than the full line so a `[x]` checkoff doesn't re-trigger the
# append.
touch "$INBOX_FILE"
if ! grep -qF -- "$WIKILINK" "$INBOX_FILE"; then
  printf '%s\n' "$INBOX_LINE" >> "$INBOX_FILE"
fi

# Escalate a logged-out host to the inbox as a distinct actionable item.
# Dedupe on the UNCHECKED marker so a still-broken day doesn't re-append, but a
# fresh outage after a prior check-off DOES re-alert — a state transition, not
# signal spam (see ceo-automated-writers-are-playbooks).
if [ -n "$AUTH_ALERT" ]; then
  AUTH_MARKER="No successful Claude runs on $HOST"
  AUTH_LINE="- [ ] ⚠️ $AUTH_MARKER in 48h — likely logged out; ssh in and run \`claude\` then /login ($WIKILINK)"
  if ! grep -qF -- "- [ ] ⚠️ $AUTH_MARKER" "$INBOX_FILE"; then
    printf '%s\n' "$AUTH_LINE" >> "$INBOX_FILE"
  fi
fi

exit 0
