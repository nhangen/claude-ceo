#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ceo-config.sh"
ceo_load_config
ceo_require_vault
# An absent ledger is still in profile migration mode.
[ -e "$CEO_VAULT/CEO/log/context" ] || exit 0
python3 "$SCRIPT_DIR/ceo-context.py" --vault "$CEO_VAULT" build >/dev/null
