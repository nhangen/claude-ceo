# Sourceable pure-function library for ceo-cron.sh. NO top-level side effects —
# safe to `source` from tests. Functions read the caller's module-scope globals.

# Returns 0 if the pre-gather key should be injected. Reads global INPUTS_JSON
# (a JSON array, or "null"/empty → default-all for pre-feature playbooks).
_inputs_includes() {
  local key="$1"
  [ "${INPUTS_JSON:-null}" = "null" ] && return 0
  [ -z "${INPUTS_JSON:-}" ] && return 0
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
