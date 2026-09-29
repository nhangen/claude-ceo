#!/usr/bin/env bash
# ceo-owners-health.sh — entry point for the owners-health playbook (#562).
# The check lives in `ceo swarm owners-health`; --scheduled keeps a sleeping
# peer out of the inbox and escalates only a peer whose daemon reported fatal.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/ceo" swarm owners-health --scheduled
