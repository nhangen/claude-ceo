#!/bin/bash
# Self-contained test harness for ceo-nathan-inbox.sh — verifies the reply-channel
# ingest: confirm-before-commit, no-auto-commit, no-silent-drop, discretion,
# watermark idempotency, expiry, and binding-drift invariants.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INGEST="$SCRIPT_DIR/ceo-nathan-inbox.sh"

source "$SCRIPT_DIR/test-harness.sh"

setup() {
  TEST_HOME=$(mktemp -d)
  HOME_BACKUP="$HOME"
  PATH_BACKUP="$PATH"
  export HOME="$TEST_HOME"
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  export CEO_HOSTNAME="testhost"
  mkdir -p "$CEO_DIR"
  touch "$CEO_DIR/inbox.md"  # satisfy ceo_validate_vault

  export CEO_NATHAN_DROPBOX="$CEO_DIR/from-nathan.md"
  export CEO_PENDING_FILE="$CEO_VAULT/Pending.md"
  export CEO_NATHAN_EXPIRY_DAYS=7
  export CEO_NATHAN_CONFIDENCE_MIN=0.6
  # Injectable clock — default "now" for most tests.
  export CEO_NATHAN_NOW_EPOCH=1751846400   # 2025-07-07T00:00:00Z-ish fixed base

  # LLM propose stub. Controlled by PROPOSE_QID / PROPOSE_CONF / PROPOSE_FAIL.
  mkdir -p "$TEST_HOME/stubs"
  # The stub records every invocation to PROPOSE_INVOKED_LOG so a test can assert
  # a bullet did NOT reach the LLM (discretion egress guard).
  export PROPOSE_INVOKED_LOG="$TEST_HOME/propose-invoked"
  cat > "$TEST_HOME/stubs/propose-stub.sh" << 'STUB'
#!/bin/bash
[ -n "${PROPOSE_INVOKED_LOG:-}" ] && echo called >> "$PROPOSE_INVOKED_LOG"
[ -n "${PROPOSE_FAIL:-}" ] && exit 1
cat >/dev/null   # consume the open-questions list on stdin
if [ -n "${PROPOSE_QID:-}" ]; then
  printf '%s\t%s\n' "$PROPOSE_QID" "${PROPOSE_CONF:-0.9}"
fi
exit 0
STUB
  chmod +x "$TEST_HOME/stubs/propose-stub.sh"
  export CEO_NATHAN_PROPOSE_CMD="$TEST_HOME/stubs/propose-stub.sh"
  unset PROPOSE_QID PROPOSE_CONF PROPOSE_FAIL
}

proposer_was_invoked() { [ -f "$PROPOSE_INVOKED_LOG" ] && echo yes || echo no; }

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$HOME_BACKUP"
  export PATH="$PATH_BACKUP"
  unset CEO_VAULT CEO_DIR CEO_HOSTNAME TEST_HOME HOME_BACKUP PATH_BACKUP
  unset CEO_NATHAN_DROPBOX CEO_PENDING_FILE CEO_NATHAN_EXPIRY_DAYS
  unset CEO_NATHAN_CONFIDENCE_MIN CEO_NATHAN_NOW_EPOCH CEO_NATHAN_PROPOSE_CMD
  unset PROPOSE_QID PROPOSE_CONF PROPOSE_FAIL PROPOSE_INVOKED_LOG
}

# ---------- fixtures ----------

write_dropbox() {
  { echo "## For the CEO"; printf '%s\n' "$@"; } > "$CEO_NATHAN_DROPBOX"
}

write_pending() {
  printf '%s\n' "$@" > "$CEO_PENDING_FILE"
}

run_ingest() { bash "$INGEST" >/dev/null 2>&1; }
run_ingest_v() { bash "$INGEST" 2>&1; }

PENDING()      { cat "$CEO_PENDING_FILE" 2>/dev/null; }
PROPOSALS()    { cat "$CEO_DIR/log/proposed-answers.md" 2>/dev/null; }
CANDIDATES()   { cat "$CEO_DIR/training/_candidates.md" 2>/dev/null; }
NEEDS_REVIEW() { cat "$CEO_DIR/needs-review/nathan-inbox.md" 2>/dev/null; }
ARCHIVE()      { cat "$CEO_DIR"/log/from-nathan/*.md 2>/dev/null; }
PROFILE_INBOX(){ cat "$CEO_VAULT/Profile/_inbox/$CEO_HOSTNAME.md" 2>/dev/null; }

# nb-id of the (only) staged proposal.
first_nb() { PROPOSALS | head -1 | cut -d'|' -f1; }

# ---------- tests ----------

test_candidate_stages_proposal_but_does_not_commit() {
  write_pending "- [ ] [ask] (qid: q-1) top goal this quarter"
  write_dropbox "- closing the 2nd Altamira CoP is my top goal"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest

  assert_contains "$(PROPOSALS)" "q-1" "proposal record should be staged"
  assert_contains "$(PENDING)" "[confirm]" "a confirm line should be written into Pending.md"
  assert_contains "$(PENDING)" "- [ ] [ask]" "the original ask stays unchecked (not committed)"
  assert_not_contains "$(PENDING)" "[done]" "the question must NOT be auto-committed"
}

test_confirm_commits_qid_done_and_stages_profile() {
  write_pending "- [ ] [ask] (qid: q-1) top goal this quarter"
  write_dropbox "- closing the 2nd Altamira CoP is my top goal"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)

  write_dropbox "- closing the 2nd Altamira CoP is my top goal" "- ok $nb"
  run_ingest

  assert_contains "$(PENDING)" "[done]" "confirming should flip the ask to done"
  assert_contains "$(PROFILE_INBOX)" "Altamira" "committed answer should stage to Profile/_inbox"
}

test_correct_note_removes_proposal_routes_to_candidates() {
  write_pending "- [ ] [ask] (qid: q-1) top goal this quarter"
  write_dropbox "- some ambiguous bullet"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)

  write_dropbox "- some ambiguous bullet" "- $nb → note"
  run_ingest

  assert_contains "$(CANDIDATES)" "some ambiguous bullet" "corrected bullet routes to candidates"
  assert_not_contains "$(PENDING)" "[confirm]" "the confirm line is withdrawn"
}

test_note_prefix_goes_to_candidates() {
  write_pending "- [ ] [ask] (qid: q-1) anything"
  write_dropbox "- note: stop surfacing dependabot PRs, I batch them"
  run_ingest

  assert_contains "$(CANDIDATES)" "dependabot" "note: bullet lands in _candidates"
  assert_not_contains "$(PROPOSALS)" "q-1" "a note is never proposed as an answer"
}

test_low_confidence_held_in_needs_review() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- maybe something"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.3" run_ingest

  assert_contains "$(NEEDS_REVIEW)" "maybe something" "low-confidence candidate held in needs-review"
  assert_not_contains "$(PENDING)" "[confirm]" "no proposal staged below the confidence floor"
}

test_hallucinated_qid_held_in_needs_review() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-DOES-NOT-EXIST" PROPOSE_CONF="0.99" run_ingest

  assert_contains "$(NEEDS_REVIEW)" "an answer" "qid absent from open set → needs-review"
  assert_not_contains "$(PROPOSALS)" "q-DOES-NOT-EXIST" "no proposal against a non-existent qid"
}

test_llm_unavailable_candidate_to_needs_review_note_still_works() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- a candidate answer" "- note: a deterministic note"
  PROPOSE_FAIL=1 run_ingest

  assert_contains "$(NEEDS_REVIEW)" "a candidate answer" "candidate falls through when LLM is down"
  assert_contains "$(CANDIDATES)" "deterministic note" "deterministic note path works without the LLM"
}

test_unconfirmed_proposal_relisted_not_committed() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  run_ingest   # second run, no ok

  assert_not_contains "$(PENDING)" "[done]" "still not committed without an explicit ok"
  assert_contains "$(PROPOSALS)" "q-1" "the proposal persists across runs"
}

test_proposal_expires_to_needs_review() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest

  # Advance the injectable clock past the expiry window and re-run.
  export CEO_NATHAN_NOW_EPOCH=$((CEO_NATHAN_NOW_EPOCH + 8 * 86400))
  run_ingest

  assert_contains "$(NEEDS_REVIEW)" "expired" "an expired proposal is surfaced, not silently held forever"
  assert_not_contains "$(PENDING)" "[confirm]" "the stale confirm line is withdrawn on expiry"
}

test_ok_after_binding_drift_not_committed() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)

  # Simulate drift: the frozen store hash no longer matches what was reported.
  sed -i.bak "s/^\($nb|q-1|\)[a-f0-9]*/\1deadbeefdrift/" "$CEO_DIR/log/proposed-answers.md"
  rm -f "$CEO_DIR/log/proposed-answers.md.bak"

  write_dropbox "- an answer" "- ok $nb"
  run_ingest

  assert_not_contains "$(PENDING)" "[done]" "a drifted confirmation must not commit the stale qid"
  assert_contains "$(NEEDS_REVIEW)" "$nb" "drifted confirmation surfaces in needs-review"
}

test_reconfirm_already_done_is_noop() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)
  write_dropbox "- an answer" "- ok $nb"
  run_ingest
  local after_first; after_first=$(grep -c '\[done\]' "$CEO_PENDING_FILE")

  # Replay the same ok (crash/replay) — must not double-commit or error.
  write_dropbox "- an answer" "- ok $nb" "- ok $nb"
  run_ingest
  local after_replay; after_replay=$(grep -c '\[done\]' "$CEO_PENDING_FILE")

  assert_eq "$after_replay" "$after_first" "re-confirming an already-done qid is a no-op"
}

test_dismiss_against_confirmed_qid_refused() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)
  write_dropbox "- an answer" "- ok $nb"
  run_ingest

  write_dropbox "- an answer" "- ok $nb" "- $nb → dismiss"
  run_ingest

  assert_contains "$(PENDING)" "[done]" "an already-confirmed answer stays committed (immutable)"
  assert_contains "$(NEEDS_REVIEW)" "refused" "a dismiss against a confirmed qid is refused, not applied"
}

test_duplicate_entry_skipped_on_rerun() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local before; before=$(PROPOSALS | wc -l | tr -d ' ')
  run_ingest   # unchanged dropbox
  local after; after=$(PROPOSALS | wc -l | tr -d ' ')

  assert_eq "$after" "$before" "an unchanged entry is skipped by the watermark on re-run"
}

test_two_identical_notes_both_ingested() {
  write_pending "- [ ] [ask] (qid: q-1) x"
  write_dropbox "- note: batch the deps" "- note: batch the deps"
  run_ingest

  local n; n=$(CANDIDATES | grep -c "batch the deps")
  assert_eq "$n" "2" "two intentionally-identical notes both ingest (occurrence-count keying)"
}

test_midlist_insertion_only_new_ingested() {
  write_pending "- [ ] [ask] (qid: q-1) x"
  write_dropbox "- note: alpha" "- note: gamma"
  run_ingest
  # Insert a bullet between the two existing ones.
  write_dropbox "- note: alpha" "- note: beta" "- note: gamma"
  run_ingest

  assert_eq "$(CANDIDATES | grep -c 'alpha')" "1" "alpha not re-ingested"
  assert_eq "$(CANDIDATES | grep -c 'beta')"  "1" "the inserted bullet is ingested once"
  assert_eq "$(CANDIDATES | grep -c 'gamma')" "1" "gamma not re-ingested despite shifting position"
}

test_discretion_flag_withholds_content() {
  export CEO_DISCRETION_DENY="SecretClientCorp"
  write_pending "- [ ] [ask] (qid: q-1) x"
  write_dropbox "- note: the SecretClientCorp deal closes next week"
  run_ingest
  unset CEO_DISCRETION_DENY

  assert_not_contains "$(CANDIDATES)"   "SecretClientCorp" "flagged content not written to candidates"
  assert_not_contains "$(ARCHIVE)"      "SecretClientCorp" "flagged content not written to archive"
  assert_not_contains "$(PROPOSALS)"    "SecretClientCorp" "flagged content not written to proposals"
  assert_contains     "$(NEEDS_REVIEW)" "withheld" "a discretion hit is surfaced (content withheld)"
}

test_sync_conflict_surfaced_not_ingested() {
  write_pending "- [ ] [ask] (qid: q-1) x"
  write_dropbox "- note: primary bullet"
  # A syncthing conflict copy sitting next to the dropbox.
  { echo "## For the CEO"; echo "- note: conflicted content only in the copy"; } \
    > "$CEO_DIR/from-nathan.sync-conflict-20260707-abcdef.md"
  run_ingest

  assert_contains     "$(NEEDS_REVIEW)" "conflict" "sync conflict is surfaced for reconciliation"
  assert_not_contains "$(CANDIDATES)"   "conflicted content only in the copy" "conflict copy contents are not auto-ingested"
}

test_nothing_dropped_no_match() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- a bullet the model cannot place"
  # Stub returns no proposal at all.
  run_ingest

  assert_contains "$(NEEDS_REVIEW)" "a bullet the model cannot place" "an unmatched candidate is never silently dropped"
}

# --- regression tests from the mini-panel review of PR #248 ---

# Finding A: a multi-word proposer command (production default is "ceo llm-propose")
# must be invoked as argv, not sought as one binary with an embedded space.
test_multiword_proposer_command_is_invoked() {
  export CEO_NATHAN_PROPOSE_CMD="bash $TEST_HOME/stubs/propose-stub.sh"
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest

  assert_contains "$(PROPOSALS)" "q-1" "a multi-word proposer command must still stage a proposal"
  assert_eq "$(proposer_was_invoked)" "yes" "the multi-word command must actually run"
}

# Finding C: the discretion guard on the CANDIDATE path (the default classification)
# must hold — a flagged bullet must never reach the external LLM proposer.
test_discretion_candidate_path_no_llm_egress() {
  export CEO_DISCRETION_DENY="SecretClientCorp"
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- the SecretClientCorp merger is my top priority"   # candidate path (no note:)
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  unset CEO_DISCRETION_DENY

  assert_eq       "$(proposer_was_invoked)" "no" "a flagged candidate must NOT reach the LLM proposer"
  assert_not_contains "$(PROPOSALS)"  "SecretClientCorp" "flagged candidate not staged"
  assert_not_contains "$(ARCHIVE)"    "SecretClientCorp" "flagged candidate content not archived"
  assert_contains     "$(NEEDS_REVIEW)" "withheld" "flagged candidate surfaced, content withheld"
}

# Finding B: if the Pending.md commit write fails, the ok must NOT be reported as
# committed (no confirm-line deletion, no profile write) and must surface.
test_commit_write_failure_not_reported_committed() {
  if [ "$(id -u)" = "0" ]; then assert_eq root root "perms test skipped as root"; return; fi
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- an answer"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest
  local nb; nb=$(first_nb)
  chmod 500 "$CEO_VAULT"                 # Pending.md's dir (vault root) unwritable → mv fails
  write_dropbox "- an answer" "- ok $nb"
  run_ingest
  chmod 700 "$CEO_VAULT"                 # restore for teardown's rm -rf

  assert_not_contains "$(PENDING)"      "[done]"        "a failed Pending write must not look committed"
  assert_not_contains "$(PROFILE_INBOX)" "an answer"    "no profile answer staged when the commit failed"
  assert_contains     "$(NEEDS_REVIEW)" "commit failed" "commit failure surfaced to needs-review"
}

# Finding E: discretion re-checked at commit time — a denylist term added AFTER a
# bullet was staged must still block the answer from reaching Profile/_inbox.
test_discretion_rechecked_on_confirm() {
  write_pending "- [ ] [ask] (qid: q-1) top goal"
  write_dropbox "- the Zephyr project is my focus"
  PROPOSE_QID="q-1" PROPOSE_CONF="0.9" run_ingest      # no denylist yet → staged
  local nb; nb=$(first_nb)
  export CEO_DISCRETION_DENY="Zephyr"                  # term added after staging
  write_dropbox "- the Zephyr project is my focus" "- ok $nb"
  run_ingest
  unset CEO_DISCRETION_DENY

  assert_not_contains "$(PROFILE_INBOX)" "Zephyr" "a term added after staging must not leak on confirm"
  assert_not_contains "$(PENDING)"       "[done]" "flagged-on-confirm answer is not committed"
  assert_contains     "$(NEEDS_REVIEW)"  "withheld" "held with content withheld"
}

# L2: a sync conflict is surfaced once, not re-surfaced on every subsequent run.
test_sync_conflict_surfaced_once() {
  write_pending "- [ ] [ask] (qid: q-1) x"
  write_dropbox "- note: primary"
  { echo "## For the CEO"; echo "- note: conflicted"; } \
    > "$CEO_DIR/from-nathan.sync-conflict-20260707-a.md"
  run_ingest
  run_ingest

  assert_eq "$(NEEDS_REVIEW | grep -c 'sync conflict')" "1" "a sync conflict is surfaced once, not every run"
}

run_tests
