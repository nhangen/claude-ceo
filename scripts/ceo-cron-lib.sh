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

# (ceo_build_pregathered_extras, ceo_morning_observe_hook, ceo_morning_raw_digest
#  are added to this lib by Tasks 3B, 6, 7 respectively.)
