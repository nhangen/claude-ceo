#!/bin/bash
# ceo-token-intake.sh — Daily RTK + token-scope spend intake.
# Captures command outputs to CEO/reports/token/<TODAY>-<host>.md and
# idempotently appends one inbox line to CEO/inbox/<host>.md linking to it.
# Also escalates a distinct inbox item when the week is tracking over the plan's
# credit cap — the one number in the report that is actionable rather than
# informational, and the reason the report exists at all.
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

# check_credit_cap — the actionable half of this report.
#
# A dollar total cannot say whether the week is over the plan allowance, because
# the plan is metered in credits. `token-scope --credits --json` reports weighted
# tokens per ISO week against that cap; this reads the week in progress and, when
# it is over (or projected over), escalates ONE inbox item.
#
# Escalation is keyed on the ISO week, deduped on the UNCHECKED marker: a week
# that is still over tomorrow does not re-append, but a NEW week going over does
# alert. That is a state transition, not a signal generator — the distinction
# ceo-automated-writers-are-playbooks exists to enforce, and the disk-monitor
# incident (64 identical hourly alerts) is what happens without it.
#
# Never fails the run: a stale plugin cache without --credits is reported as its
# own actionable item, not as red cron telemetry, because the fix is a /plugin
# update the user performs, not a broken job.
CAP_ALERT=""
CAP_ALERT_KEY=""

# Probed once, before the report is written. A build without --credits must not
# reach `capture` at all: capture treats a non-zero exit as a run failure, so an
# out-of-date plugin cache would redden cron telemetry every morning when the
# actual fix is a `/plugin update` the user performs. That belongs in the inbox
# as an actionable item, not in the failure channel.
TS_HAS_CREDITS=0
if ! command -v "${TS_CMD[0]}" >/dev/null 2>&1; then
  # A missing binary is a genuine run failure — the `--since 1d` capture below
  # will record it and exit non-zero. Telling the user to run `/plugin update`
  # for something that isn't installed would be wrong advice on top of red cron.
  :
elif "${TS_CMD[@]}" --help 2>/dev/null | grep -q -- '--credits'; then
  TS_HAS_CREDITS=1
else
  CAP_ALERT="token-scope in the plugin cache predates \`--credits\`, so this report cannot say whether the week is over the credit cap. Fix: run \`/plugin update\` in Claude Code."
  CAP_ALERT_KEY="stale-plugin"
fi

check_credit_cap() {
  if [ "$TS_HAS_CREDITS" -ne 1 ]; then
    printf 'SKIP: no token-scope with --credits available; see the inbox if this is a stale plugin.\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'SKIP: jq not on PATH; cannot read the credits report without guessing.\n'
    return 0
  fi

  local json
  if ! json=$("${TS_CMD[@]}" --credits --since 8w --json 2>/dev/null); then
    printf 'ERROR: token-scope --credits exited non-zero.\n'
    return 0
  fi
  # Distinguish a contract change from an idle week. Routing both to "no data"
  # would let a renamed field silence this check indefinitely.
  if ! printf '%s' "$json" | jq -e 'has("weeks") and (.meta | has("weekly_cap"))' >/dev/null 2>&1; then
    printf 'ERROR: --credits --json is not the expected shape (missing .weeks or .meta.weekly_cap).\n'
    return 0
  fi

  local cap
  cap=$(printf '%s' "$json" | jq -r '.meta.weekly_cap')
  if [ -z "$cap" ] || [ "$cap" = "null" ] || [ "$cap" = "0" ]; then
    printf 'ERROR: weekly_cap is %s — nothing to compare against.\n' "${cap:-empty}"
    return 0
  fi

  # The week in progress: partial AND already started. Filtering on `partial`
  # alone picks a future-dated week when a synced host's clock is skewed, and
  # because that phantom week is nearly empty it reads as comfortably under cap
  # — masking a real over-cap week instead of merely mis-reporting one.
  local today row
  today=$(date -u +%Y-%m-%d)
  row=$(printf '%s' "$json" | jq -c --arg today "$today" '
    [ .weeks[] | select(.partial == true and .weekStart <= $today) ] | last // empty' 2>/dev/null) || row=""
  if [ -z "$row" ]; then
    printf 'No started week in progress in the last 8w — nothing to compare against the cap.\n'
    return 0
  fi

  # Baseline: the worst FULL week in the window. Truncated weeks hold only part
  # of their spend, so including them would understate the bar.
  local baseline
  baseline=$(printf '%s' "$json" | jq -r '
    [ .weeks[] | select(.partial != true and .truncated != true) | .capRatio ]
    | if length == 0 then "" else (max | (. * 100 | round) / 100) end' 2>/dev/null) || baseline=""

  local week ratio shape credits capm
  week=$(printf '%s' "$row" | jq -r '.weekStart')
  # projectedCapRatio is null until a fifth of the week has elapsed, so before
  # then this falls back to spend-so-far and cannot alert on Monday-morning
  # arithmetic. Nulls never reach the message.
  ratio=$(printf '%s' "$row" | jq -r '((.projectedCapRatio // .capRatio) // 0) | (. * 100 | round) / 100')
  shape=$(printf '%s' "$row" | jq -r 'if .projectedCapRatio != null then "projected" else "so far" end')
  credits=$(printf '%s' "$row" | jq -r '((.credits // 0) / 1000000) | (. * 10 | round) / 10')
  capm=$(awk -v c="$cap" 'BEGIN { printf "%.1f", c / 1000000 }')

  printf 'week %s: %sM credits %s vs %sM cap (%sx); worst full week in window: %sx\n' \
    "$week" "$credits" "$shape" "$capm" "$ratio" "${baseline:-n/a}"

  # Escalate only a week that is BOTH over the cap and worse than the worst full
  # week in the window. A bare `> 1` on a host that runs 1.5-4.7x every week is a
  # weekly nag that reports the baseline as news; this fires when the week is
  # genuinely worse than recent behaviour, which is the only version worth reading.
  local trip=0
  if awk -v r="$ratio" 'BEGIN { exit !(r > 1) }'; then
    if [ -z "$baseline" ]; then
      trip=1
    elif awk -v r="$ratio" -v b="$baseline" 'BEGIN { exit !(r > b) }'; then
      trip=1
    fi
  fi

  if [ "$trip" -eq 1 ]; then
    local vs="no full week in the window to compare against"
    [ -n "$baseline" ] && vs="worse than the worst full week in the window (${baseline}x)"
    CAP_ALERT="Week of $week is ${ratio}x the ${capm}M credit cap (${credits}M $shape) — $vs. Cache reads and writes are ~90% of a weighted week, so the lever is context size per turn: shorter sessions and /clear, not shorter answers."
    CAP_ALERT_KEY="$week"
    printf 'WARN: over cap and above baseline\n'
  fi
  return 0
}

if ! {
  printf -- '---\ndate: %s\ntype: ceo-token-intake\n---\n\n' "$TODAY"
  printf '# Token Report — %s\n' "$TODAY"
  capture "RTK — global savings" rtk gain
  capture "ccusage — Claude Code monthly" npx --yes ccusage@latest monthly
  capture "token-scope — last 24h" "${TS_CMD[@]}" --since 1d
  if [ "$TS_HAS_CREDITS" -eq 1 ]; then
    capture "token-scope — credits vs weekly cap" "${TS_CMD[@]}" --credits --since 8w
  fi
  capture "credit cap check" check_credit_cap
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

# Escalate an over-cap week (or a plugin too old to tell) as its own item.
# The marker carries the week, so a still-over week does not re-append tomorrow
# but a new week going over does alert.
# The marker deliberately omits the report wikilink: the daily review line is
# counted by wikilink to prove it is appended exactly once, and a second line
# carrying the same link would break that invariant every week this fires.
#
# Dedupe ignores the checkbox state, unlike the auth alert above. The auth marker
# keys on the host, so a re-alert after check-off IS the transition; this marker
# already keys on the ISO week, so re-appending after a check-off would tell the
# user about the same week twice.
if [ -n "$CAP_ALERT" ]; then
  CAP_MARKER="Credit cap ($CAP_ALERT_KEY) on $HOST"
  CAP_LINE="- [ ] ⚠️ $CAP_MARKER — $CAP_ALERT"
  if ! grep -qF -- "$CAP_MARKER" "$INBOX_FILE"; then
    printf '%s\n' "$CAP_LINE" >> "$INBOX_FILE"
  fi
fi

exit 0
