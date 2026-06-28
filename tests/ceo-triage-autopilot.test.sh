#!/bin/bash
# Behavioral test for ceo-triage-autopilot.sh (v2 adapter). Stubs the skill
# scripts; exercises the REAL ceo-config.sh helpers via the CEO_VAULT bypass.
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/ceo-triage-autopilot.sh"
WORK="$(mktemp -d)"
fail() { echo "FAIL: $1"; echo "--- inbox ---"; cat "$INBOX" 2>/dev/null; echo "--- state ---"; cat "$STATE" 2>/dev/null; rm -rf "$WORK"; exit 1; }

export CEO_VAULT="$WORK/vault"; mkdir -p "$CEO_VAULT/CEO"
export CEO_HOSTNAME="testhost"
export CEO_TRIAGE_OWNERS="nhangen"
INBOX="$CEO_VAULT/CEO/inbox.md"
STATE="$CEO_VAULT/CEO/alerts/triage-autopilot-testhost.md"

SKILL="$WORK/skill"; mkdir -p "$SKILL"; export CEO_TRIAGE_SKILL_DIR="$SKILL"
cat > "$SKILL/triage_update.py" <<'PY'
import sys
sys.exit(0)  # silent success
PY
# plain call: one high-priority event; --mark: empty (consume). The script
# previews (plain), appends, then consumes (--mark) — so a second tick re-previews
# the same event and must be deduped by the inbox marker, not re-appended.
cat > "$SKILL/triage_surface.py" <<'PY'
import sys, json
ev = [{"slug": "nhangen/a", "number": 2, "title": "rce", "url": "u", "labels": ["security"]}]
out = {"owner": "nhangen", "events": [] if "--mark" in sys.argv else ev, "unknown": [], "since": None}
print(json.dumps(out))
PY

# --- Run 1: transition fires, one inbox line, status firing ---
bash "$SCRIPT" >/dev/null 2>&1 || fail "run 1 exited non-zero"
n=$(grep -cF 'triage-surface:nhangen/a#2' "$INBOX" 2>/dev/null || echo 0)
[ "$n" -eq 1 ] || fail "run 1: expected 1 inbox line, got $n"
grep -q '^status: firing' "$STATE" || fail "run 1: state not firing"

# --- Run 2: same event re-previewed but already in inbox → no dup, status clear ---
bash "$SCRIPT" >/dev/null 2>&1 || fail "run 2 exited non-zero"
n=$(grep -cF 'triage-surface:nhangen/a#2' "$INBOX" 2>/dev/null || echo 0)
[ "$n" -eq 1 ] || fail "run 2: duplicate inbox line (got $n) — dedup marker failed"
grep -q '^status: clear' "$STATE" || fail "run 2: state not clear after no new transition"

# --- Missing skill: config error, not a crash; state records it, exit 0 ---
export CEO_TRIAGE_SKILL_DIR="$WORK/nonexistent"
bash "$SCRIPT" >/dev/null 2>&1 || fail "missing-skill run should exit 0"
grep -q 'last_error: skill_not_found' "$STATE" || fail "missing skill not recorded in state"

# --- unknown-priority surfacing: closed-set unknowns escalate once ---
export CEO_TRIAGE_SKILL_DIR="$SKILL"
cat > "$SKILL/triage_surface.py" <<'PY'
import sys, json
out = {"owner": "nhangen", "events": [], "unknown": [{"slug": "nhangen/a", "number": 9, "reason": "x"}], "since": None}
print(json.dumps(out))
PY
bash "$SCRIPT" >/dev/null 2>&1 || fail "unknown run exited non-zero"
grep -q 'unrecognized priority value' "$INBOX" || fail "unknown-priority not escalated to inbox"

echo "PASS ceo-triage-autopilot"; rm -rf "$WORK"; exit 0
