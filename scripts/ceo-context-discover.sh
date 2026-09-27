#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ceo-config.sh"
ceo_load_config
ceo_require_vault
python3 "$SCRIPT_DIR/ceo-context-discover.py" --vault "$CEO_VAULT"
