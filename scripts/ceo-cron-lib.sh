# shellcheck shell=bash
# Sourceable pure-function library for ceo-cron.sh. NO top-level side effects —
# safe to `source` from tests. Functions read the caller's module-scope globals.

# Returns 0 if the pre-gather key should be injected. Reads global INPUTS_JSON
# (a JSON array, or "null"/empty → default-all for pre-feature playbooks).
_inputs_includes() {
  local key="$1"
  [ "${INPUTS_JSON:-null}" = "null" ] && return 0
  echo "$INPUTS_JSON" | jq -e --arg k "$key" 'index($k) != null' >/dev/null 2>&1
}

# Emit the v1 morning-flow extra signals, gated by the playbook's inputs list.
# In the lib so it is unit-testable without driving a full dispatch.
ceo_build_pregathered_extras() {
  local out=""
  _inputs_includes current_sprint  && out+="- Current sprint (${CURRENT_SPRINT_COUNT:-0} items): ${CURRENT_SPRINT_ITEMS:-[]}"$'\n'
  _inputs_includes yesterday_merged && out+="- Yesterday merged (observable positives): ${YESTERDAY_MERGED:-[]}"$'\n'
  _inputs_includes ledger_recent    && out+="- model ledger (recent, model-of-Nathan): ${LEDGER_RECENT:-}"$'\n'
  printf '%s' "$out"
}

# Append the model-of-Nathan ledger entry after a successful morning run.
# In the lib so it is unit-testable. Never fails the flow.
ceo_morning_observe_hook() {
  local trigger="$1" log_entry="$2"
  [ "$trigger" = "morning" ] || return 0
  [ "${CEO_DRY_RUN:-}" = "1" ] && return 0
  if ! printf '%s\n' "$log_entry" \
      | YESTERDAY_MERGED="${YESTERDAY_MERGED:-[]}" \
        LEDGER_PREV_PREDICTED="${LEDGER_PREV_PREDICTED:-[]}" \
        bash "${SCRIPT_DIR}/ceo-observe.sh" >/dev/null 2>&1; then
    command -v _v >/dev/null 2>&1 && _v "observe step failed (non-fatal)"
  fi
  return 0
}

# Deterministic fallback digest for morning trigger when synthesis produces no
# usable LOG_ENTRY output. Reads module-scope globals set by the pre-gather phase.
ceo_morning_raw_digest() {
  echo "**Morning (raw digest — synthesis unavailable)**"
  local sprint; sprint=$(echo "${CURRENT_SPRINT_ITEMS:-[]}" | jq -r '.[]? | "- [sprint] " + .repo + "#" + (.number|tostring) + " " + .title' 2>/dev/null)
  [ -n "$sprint" ] && { echo "Current sprint:"; echo "$sprint"; }
  local rev; rev=$(echo "${PR_REVIEW_REQUESTED:-[]}" | jq -r '.[]? | "- [review] " + (.title // "PR")' 2>/dev/null)
  [ -n "$rev" ] && { echo "Needs review:"; echo "$rev"; }
  [ -n "${DAILY_NOTE_TOP3:-}" ] && { echo "Top 3:"; echo "${DAILY_NOTE_TOP3}"; }
}

# _classify_claude_failure <exit_code> <raw_stdout> — decide how a `claude
# --print` invocation ended, so the caller can route it. Prints exactly one of:
#   ok        succeeded (complete result)
#   transient availability/throttle failure (5xx, 429, network) — safe to fall
#             back to a local model
#   auth      authentication failure — NEVER fall back (a local-model report
#             would re-mute the logged-out alarm); fail loud + escalate
#   terminal  logic/invocation error, truncated output, or an unrecognized
#             failure — fail loud, no fallback, no retry (fail-safe default)
#
# Primary signal is the `--output-format json` envelope (single-call path, the
# only path that falls back): `is_error`, `api_error_status` (HTTP status),
# `stop_reason`. Plan/exec phases emit plain text (no envelope) and never fall
# back, so for them we only distinguish ok vs a best-effort banner match — the
# legacy `session limit` substring survives ONLY as this last-resort tier, never
# as the primary key. Never exits non-zero; unknown → terminal (fail-safe, not
# fail-open-to-fallback). Requires jq for the envelope path; degrades to the
# banner tier without it. Pure — no globals, no I/O.
_classify_claude_failure() {
  local rc="${1:-1}" raw="${2:-}"
  local is_error="" status="" subtype="" stop=""
  if command -v jq >/dev/null 2>&1; then
    # NB: do NOT use `.is_error // empty` — jq's `//` treats the boolean `false`
    # like null, collapsing a genuine `is_error:false` to empty. Read it raw
    # ("false"/"true"/"null"/"" for non-object).
    is_error=$(printf '%s' "$raw" | jq -r 'if type=="object" then (.is_error) else empty end' 2>/dev/null || true)
    status=$(printf '%s'  "$raw" | jq -r 'if type=="object" then (.api_error_status // empty) else empty end' 2>/dev/null || true)
    subtype=$(printf '%s' "$raw" | jq -r 'if type=="object" then (.subtype // empty) else empty end' 2>/dev/null || true)
    stop=$(printf '%s'    "$raw" | jq -r 'if type=="object" then (.stop_reason // empty) else empty end' 2>/dev/null || true)
  fi

  # Parseable success envelope: ok, unless the result was truncated (a partial
  # report must not pass as healthy — the exit-0 silent-degradation case).
  if [ "$is_error" = "false" ]; then
    [ "$stop" = "max_tokens" ] && { echo "terminal"; return 0; }
    echo "ok"; return 0
  fi

  # Parseable error envelope with an HTTP status → route by status class.
  case "$status" in
    429|5[0-9][0-9]) echo "transient"; return 0 ;;
    401|403)         echo "auth";      return 0 ;;
    4[0-9][0-9])     echo "terminal";  return 0 ;;
  esac
  # Structured error whose subtype names auth (status absent/unmapped).
  case "$subtype" in
    *auth*|*login*|*credential*) echo "auth"; return 0 ;;
  esac
  # Structured error, is_error true, but no usable status → unknown-but-real.
  [ "$is_error" = "true" ] && { echo "terminal"; return 0; }

  # No parseable envelope. Exit 0 = success (plain-text plan/exec phases).
  if [ "$rc" -eq 0 ] 2>/dev/null; then echo "ok"; return 0; fi

  # Non-zero exit, non-JSON stdout → last-resort banner match.
  if printf '%s' "$raw" | grep -qEi 'session limit|hit your limit|rate.?limit|overloaded'; then
    echo "transient"; return 0
  fi
  if printf '%s' "$raw" | grep -qEi 'authentication_failed|not authenticated|logged out|invalid api key|please run .?/login'; then
    echo "auth"; return 0
  fi
  echo "terminal"; return 0   # fail-safe: unknown never falls open to fallback
}
