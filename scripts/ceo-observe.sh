#!/usr/bin/env bash
# ceo-observe.sh
# Append a positives-only, discretion-scrubbed learning entry to the model ledger.
# Sourced for unit tests (defines compute_hit_rate); executed as the observe step.
set -uo pipefail

compute_hit_rate() {
  # $1 = JSON array of predicted "repo#num" strings (bare repo or owner/repo)
  # $2 = JSON array of {number, repo} objects (repo may be owner/name from gh)
  # Normalizes both sides to bare basename before comparing so owner-prefixed
  # repos from gh match the bare names carried in the predicted sprint output.
  local pred="$1" actual="$2" total hits
  total=$(echo "$pred" | jq 'length' 2>/dev/null || echo 0)
  hits=$(jq -n --argjson p "$pred" --argjson a "$actual" '
    [ $p[] | . as $x |
      # normalize predicted: strip owner prefix from repo portion
      ($x | (split("#")[0] | split("/") | last) + "#" + (split("#")[1] // "")) as $xn |
      $a[] |
      # normalize actual: strip owner prefix from repo
      select(( (.repo | split("/") | last) + "#" + (.number|tostring) ) == $xn)
    ] | length
  ' 2>/dev/null || echo 0)
  echo "${hits}/${total}"
}

_ceo_observe_main() {
  : "${CEO_VAULT:?CEO_VAULT must be set}"
  : "${TODAY:?TODAY must be set}"
  local ledger_dir="$CEO_VAULT/CEO/model"
  mkdir -p "$ledger_dir"
  local month="${TODAY%-*}"           # YYYY-MM
  local ledger="$ledger_dir/$month.md"

  local input; input=$(cat || true)
  # Extract predicted lines from the synthesis block.
  local predicted; predicted=$(printf '%s\n' "$input" \
    | awk '/CEO-PREDICTED-PRIORITIES/{f=1;next}/-->/{f=0}f' \
    | sed -E 's/^- //; s/:.*$//' | sed '/^$/d')

  local denyfile="$CEO_VAULT/Profile/discretion-denylist.txt"
  # Build fixed-string denylist: one term per line, from file + env var.
  # Fixed strings (-F) prevent regex metachar in client/company names from
  # causing grep to exit non-zero and the || true from silently wiping predicted.
  local _deny_tmp
  _deny_tmp=$(mktemp)
  if [ -f "$denyfile" ]; then
    grep -vE '^\s*(#|$)' "$denyfile" 2>/dev/null >> "$_deny_tmp" || true
  fi
  if [ -n "${CEO_DISCRETION_DENY:-}" ]; then
    printf '%s\n' "${CEO_DISCRETION_DENY}" | tr '|' '\n' | sed '/^$/d' >> "$_deny_tmp"
  fi
  if [ -s "$_deny_tmp" ]; then
    predicted=$(printf '%s\n' "$predicted" | grep -viFf "$_deny_tmp" || true)
  fi
  rm -f "$_deny_tmp"

  local hit="n/a"
  if [ "${YESTERDAY_MERGED_DEGRADED:-0}" = "1" ]; then
    hit="n/a (actuals unavailable)"
  else
    local _prev_len
    _prev_len=$(printf '%s' "${LEDGER_PREV_PREDICTED:-[]}" | jq 'length' 2>/dev/null || echo 0)
    if [ -n "${YESTERDAY_MERGED:-}" ] && [ "${_prev_len:-0}" -gt 0 ]; then
      hit=$(compute_hit_rate "$LEDGER_PREV_PREDICTED" "$YESTERDAY_MERGED")
    fi
  fi

  {
    echo ""
    echo "## $TODAY — model update"
    echo "- yesterday hit-rate: $hit"
    echo "- predicted today:"
    printf '%s\n' "$predicted" | sed 's/^/  - /'
  } >> "$ledger"
}

# Only run main when executed, not when sourced for tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then _ceo_observe_main; fi
