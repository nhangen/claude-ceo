#!/usr/bin/env bash
# ceo-savings-report.sh — unified per-tier breakdown across the shared ledger
# (ollama-agent rows + claude-tier/interactive-tier rows). Additive to
# ceo-ollama-batch's existing per-batch `token-scope --savings` calls; this
# reports counts and known costs from the ledger, never a guessed dollar
# figure for rows with no recorded cost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ceo-model-ledger.sh
source "$SCRIPT_DIR/ceo-model-ledger.sh"

LEDGER="$(ceo_ledger_path)"

if [ ! -f "$LEDGER" ]; then
  echo "No ledger found at $LEDGER — nothing to report."
  exit 0
fi

echo "=== Per-tier row counts ==="
jq -rs '
  map(.model // "unknown")
  | group_by(.)
  | map({model: .[0], count: length})
  | sort_by(.model)
  | .[]
  | "\(.model): \(.count)"
' "$LEDGER" | sed 's/gpt-oss:20b/ollama/'

echo ""
echo "=== Cost known vs unpriced ==="
UNPRICED=$(jq -rs 'map(select(.cost_usd == null and (.ollama_input_tokens | not))) | length' "$LEDGER")
echo "unpriced: $UNPRICED"

echo ""
echo "=== Known cost total (claude-tier / interactive-tier rows) ==="
jq -rs '
  map(select(.cost_usd != null))
  | map(.cost_usd)
  | add // 0
' "$LEDGER"
