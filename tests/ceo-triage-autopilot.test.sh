#!/bin/bash
# Behavioral test for ceo-triage-autopilot.sh (v2 adapter). Stubs the skill with
# a STATEFUL surfacer that mirrors the real consume semantics (events = current −
# marked; --mark adds current to marked), so the consume-after-write ordering is
# actually exercised. Exercises the REAL ceo-config.sh helpers via CEO_VAULT.
# Exit 0 = PASS, 1 = FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/ceo-triage-autopilot.sh"
WORK="$(mktemp -d)"
fail() { echo "FAIL: $1"; echo "--- inbox ---"; cat "$INBOX" 2>/dev/null; echo "--- state ---"; cat "$STATE" 2>/dev/null; rm -rf "$WORK"; exit 1; }

export CEO_VAULT="$WORK/vault"; mkdir -p "$CEO_VAULT/CEO/alerts"
export CEO_HOSTNAME="testhost"
export CEO_TRIAGE_OWNERS="nhangen"
INBOX="$CEO_VAULT/CEO/inbox.md"
STATE="$CEO_VAULT/CEO/alerts/triage-autopilot-testhost.md"

SKILL="$WORK/skill"; mkdir -p "$SKILL"; export CEO_TRIAGE_SKILL_DIR="$SKILL"
export STUB_MARK_FILE="$WORK/marked"          # surfacer's persisted "surfaced" set
export STUB_CURRENT=""                          # comma-sep ids, e.g. "nhangen/a#2"
export STUB_UPDATE_RC=0                         # updater exit code
export STUB_SURFACE_RAW=""                      # if set, surfacer prints this verbatim (exit 0)

# Updater: validates it got an owner arg (stub-cli-argv-validation), then exits RC.
cat > "$SKILL/triage_update.py" <<'PY'
import sys, os
args = [a for a in sys.argv[1:] if not a.startswith("--")]
if not args:
    sys.stderr.write("stub triage_update: missing owner\n"); sys.exit(99)
sys.exit(int(os.environ.get("STUB_UPDATE_RC", "0")))
PY

# Surfacer: stateful. events = current − marked; --mark persists current as marked.
cat > "$SKILL/triage_surface.py" <<'PY'
import sys, os, json
args = [a for a in sys.argv[1:] if not a.startswith("--")]
if not args:
    sys.stderr.write("stub triage_surface: missing owner\n"); sys.exit(99)
raw = os.environ.get("STUB_SURFACE_RAW", "")
if raw:
    print(raw); sys.exit(0)                      # simulate 0-exit malformed output
mf = os.environ["STUB_MARK_FILE"]
marked = set(open(mf).read().split()) if os.path.exists(mf) else set()
cur = [c for c in os.environ.get("STUB_CURRENT", "").split(",") if c]
fresh = [c for c in cur if c not in marked]
ev = [{"slug": c.rsplit("#", 1)[0], "number": int(c.rsplit("#", 1)[1]),
       "title": "t", "url": "u", "labels": ["security"]} for c in fresh]
if "--mark" in sys.argv:
    open(mf, "w").write("\n".join(sorted(set(cur))))
print(json.dumps({"owner": args[0], "events": ev, "unknown": [], "since": None}))
PY

# --- 1. Transition fires once; real consume means run 2 is silent ---
export STUB_CURRENT="nhangen/a#2"
bash "$SCRIPT" >/dev/null 2>&1 || fail "run 1 exited non-zero"
[ "$(grep -cF 'triage-surface:nhangen/a#2' "$INBOX" 2>/dev/null || echo 0)" -eq 1 ] || fail "run 1: expected 1 inbox line"
grep -q '^status: firing' "$STATE" || fail "run 1: not firing"
bash "$SCRIPT" >/dev/null 2>&1 || fail "run 2 exited non-zero"
[ "$(grep -cF 'triage-surface:nhangen/a#2' "$INBOX" 2>/dev/null || echo 0)" -eq 1 ] || fail "run 2: duplicate line"
grep -q '^status: clear' "$STATE" || fail "run 2: not clear (real consume should have emptied events)"

# --- 2. Append failure must NOT consume the transition (catches mark-before-write) ---
export STUB_CURRENT="nhangen/a#2,nhangen/a#3"   # #3 is new
chmod a-w "$INBOX"                                # force the append to fail
bash "$SCRIPT" >/dev/null 2>&1 || fail "run with unwritable inbox should still exit 0"
chmod u+w "$INBOX"
grep -qx "nhangen/a#3" "$STUB_MARK_FILE" 2>/dev/null && fail "append failed but #3 was consumed (atomicity broken)"
bash "$SCRIPT" >/dev/null 2>&1 || fail "retry run exited non-zero"
[ "$(grep -cF 'triage-surface:nhangen/a#3' "$INBOX" 2>/dev/null || echo 0)" -eq 1 ] || fail "retry: #3 not appended after inbox writable again (event was lost)"

# --- 3. Updater incomplete (exit 1): recorded, and consume is skipped ---
rm -f "$STUB_MARK_FILE"; : > "$INBOX"
export STUB_UPDATE_RC=1; export STUB_CURRENT="nhangen/a#5"
bash "$SCRIPT" >/dev/null 2>&1 || fail "incomplete run should exit 0"
grep -q '^incomplete: 1' "$STATE" || fail "incomplete not recorded"
grep -qx "nhangen/a#5" "$STUB_MARK_FILE" 2>/dev/null && fail "consumed on incomplete cache (should skip --mark)"
export STUB_UPDATE_RC=0

# --- 4. Malformed surfacer JSON (exit 0): failure path, not silent 'clear' ---
rm -f "$STUB_MARK_FILE"; : > "$INBOX"
export STUB_SURFACE_RAW="not json at all"
bash "$SCRIPT" >/dev/null 2>&1 || fail "malformed-json run should exit 0"
grep -q 'last_error: surface_or_mark_failed' "$STATE" || fail "malformed JSON not routed to failure path"
[ -s "$STUB_MARK_FILE" ] && fail "malformed surface should not consume anything"
unset STUB_SURFACE_RAW

# --- 5. Missing skill: config error, graceful ---
rm -f "$STUB_MARK_FILE"; : > "$INBOX"
export CEO_TRIAGE_SKILL_DIR="$WORK/nonexistent"
bash "$SCRIPT" >/dev/null 2>&1 || fail "missing-skill run should exit 0"
grep -q 'last_error: skill_not_found' "$STATE" || fail "missing skill not recorded"
export CEO_TRIAGE_SKILL_DIR="$SKILL"

# --- 6. Unknown-priority (closed set): escalate once ---
rm -f "$STUB_MARK_FILE"; : > "$INBOX"
export STUB_SURFACE_RAW='{"owner":"nhangen","events":[],"unknown":[{"slug":"nhangen/a","number":9,"reason":"x"}],"since":null}'
bash "$SCRIPT" >/dev/null 2>&1 || fail "unknown run exited non-zero"
grep -q 'unrecognized priority value' "$INBOX" || fail "unknown-priority not escalated"
unset STUB_SURFACE_RAW

echo "PASS ceo-triage-autopilot"; rm -rf "$WORK"; exit 0
