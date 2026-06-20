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

  # Discretion scrub: drop any line containing a denied term.
  # CEO_DISCRETION_DENY (regex) is the test/runtime override.
  # The vault denylist (one term/regex per line, # comments and blanks ignored)
  # extends the deny pattern in production without carrying real secrets in code.
  local denyfile="$CEO_VAULT/Profile/discretion-denylist.txt"
  local deny="${CEO_DISCRETION_DENY:-}"
  if [ -f "$denyfile" ]; then
    local fileterms
    fileterms=$(grep -vE '^\s*(#|$)' "$denyfile" 2>/dev/null | paste -sd '|' - 2>/dev/null || true)
    [ -n "$fileterms" ] && deny="${deny:+$deny|}$fileterms"
  fi
  if [ -n "$deny" ]; then
    predicted=$(printf '%s\n' "$predicted" | grep -viE "$deny" || true)
  fi

  local hit="n/a"
  if [ -n "${YESTERDAY_MERGED:-}" ] && [ -n "${LEDGER_PREV_PREDICTED:-}" ]; then
    hit=$(compute_hit_rate "$LEDGER_PREV_PREDICTED" "$YESTERDAY_MERGED")
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
