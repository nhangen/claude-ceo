#!/bin/bash
# ceo-nathan-inbox.sh — Reply-channel ingest for the CEO training loop.
#
# Reads Nathan's freeform bullets from a synced dropbox (CEO/from-nathan.md),
# and routes them WITHOUT ever auto-committing a fuzzy answer or silently
# dropping an entry. A candidate answer is *proposed* (staged + surfaced via a
# Pending.md [confirm] line); only an explicit `ok <nb>` commits it. Everything
# unhandled — low-confidence, hallucinated qid, expired, drifted, discretion-
# flagged, sync-conflict — lands in needs-review.
#
# The dropbox is single-writer (only Nathan): this script reads it and NEVER
# writes or clears it. Invoked by ceo-cron.sh when the nathan-inbox playbook
# (runner:script) fires, or on demand via `ceo cron nathan-inbox`.
#
# -e is intentionally OFF: the routing loop runs many greps whose non-zero exit
# is normal control flow, not failure. Errors are handled explicitly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
HOST="${CEO_HOSTNAME:-$(hostname -s)}"
: "${HOST:?HOST resolution failed; set CEO_HOSTNAME or fix hostname}"

DROPBOX="${CEO_NATHAN_DROPBOX:-$CEO_DIR/from-nathan.md}"
PENDING="${CEO_PENDING_FILE:-$VAULT/Pending.md}"
# The matcher is the installed Claude Code harness, headless: `claude -p`. No
# wrapper, no subprocess dressing — the harness IS the model. CEO_NATHAN_PROPOSE_CMD
# overrides the command (tests point it at a stub).
PROPOSE_MODEL="${CEO_MODEL:-sonnet}"
PROPOSE_CMD="${CEO_NATHAN_PROPOSE_CMD:-claude -p --model $PROPOSE_MODEL}"
CONF_MIN="${CEO_NATHAN_CONFIDENCE_MIN:-0.6}"
EXPIRY_DAYS="${CEO_NATHAN_EXPIRY_DAYS:-7}"

LOG_DIR="$CEO_DIR/log"
PROPOSALS="$LOG_DIR/proposed-answers.md"
SEEN="$LOG_DIR/.from-nathan-seen"
NB_COUNTER="$LOG_DIR/.nathan-nb-counter"
ARCHIVE_DIR="$LOG_DIR/from-nathan"
CANDIDATES="$CEO_DIR/training/_candidates.md"
NEEDS_REVIEW="$CEO_DIR/needs-review/nathan-inbox.md"
PROFILE_INBOX="$VAULT/Profile/_inbox/$HOST.md"

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$CEO_DIR/training" "$CEO_DIR/needs-review" \
         "$VAULT/Profile/_inbox"
touch "$PROPOSALS" "$SEEN"

NOW_EPOCH="${CEO_NATHAN_NOW_EPOCH:-$(date +%s)}"

# ---------- small helpers ----------

_hash() { printf '%s' "$1" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1; } | awk '{print $1}'; }
_date_ymd() { date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d; }
_month()    { date -r "$1" +%Y-%m    2>/dev/null || date -d "@$1" +%Y-%m; }
_b64enc()   { printf '%s' "$1" | base64 | tr -d '\n'; }
_b64dec()   { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }

ARCHIVE="$ARCHIVE_DIR/$(_month "$NOW_EPOCH").md"
touch "$ARCHIVE"

_archive()      { printf '%s\n' "$1" >> "$ARCHIVE"; }
_needs_review() { printf -- '- %s\n' "$1" >> "$NEEDS_REVIEW"; }
_seen_add()     { printf '%s\n' "$1" >> "$SEEN"; }
_is_seen()      { grep -qxF "$1" "$SEEN" 2>/dev/null; }

# Discretion denylist (same mechanism as ceo-observe.sh): fixed strings from
# Profile/discretion-denylist.txt + CEO_DISCRETION_DENY (pipe-separated).
_DENY_TMP="$(mktemp)"
trap 'rm -f "$_DENY_TMP"' EXIT
_denyfile="$VAULT/Profile/discretion-denylist.txt"
[ -f "$_denyfile" ] && grep -vE '^\s*(#|$)' "$_denyfile" 2>/dev/null >> "$_DENY_TMP"
[ -n "${CEO_DISCRETION_DENY:-}" ] && printf '%s\n' "$CEO_DISCRETION_DENY" | tr '|' '\n' | sed '/^$/d' >> "$_DENY_TMP"

_is_flagged() {
  [ -s "$_DENY_TMP" ] || return 1
  printf '%s' "$1" | grep -qiFf "$_DENY_TMP"
}

# ---------- Pending.md queries + mutations ----------

# qid is "done" if a Pending line carries its (qid: X) token and a [done] mark.
_qid_done() {
  local qid="$1"
  grep -F "(qid: $qid)" "$PENDING" 2>/dev/null | grep -q '\[done\]'
}

# question text for an open (qid: X) [ask] line (excludes [confirm] lines).
_question_for_qid() {
  local qid="$1"
  grep -F "(qid: $qid)" "$PENDING" 2>/dev/null \
    | grep '^- \[ \] \[ask\]' | grep -v '\[confirm\]' | head -1 \
    | sed -E "s/^- \[ \] \[ask\][[:space:]]*\(qid: $qid\)[[:space:]]*//"
}

_qid_is_open() { grep -F "(qid: $1)" "$PENDING" 2>/dev/null | grep '^- \[ \] \[ask\]' | grep -qv '\[confirm\]'; }

_pending_rewrite() {  # reads an awk program on $1, atomically rewrites Pending
  local prog="$1" tmp
  tmp="$(mktemp)" || { echo "ERROR: mktemp for Pending rewrite" >&2; return 1; }
  if awk "$prog" "$PENDING" > "$tmp"; then mv "$tmp" "$PENDING"; else rm -f "$tmp"; return 1; fi
}

_append_confirm_line() {  # nb qid hash bullet question
  local nb="$1" qid="$2" hash="$3" bullet="$4" q="$5"
  printf -- '- [ ] [ask] [confirm] "%s" → answers "%s"? Reply `ok %s` <!-- nathan-inbox nb:%s qid:%s h:%s -->\n' \
    "$bullet" "$q" "$nb" "$nb" "$qid" "$hash" >> "$PENDING"
}

_remove_confirm_line() {  # nb — drop the [confirm] line carrying nb:<nb>
  _pending_rewrite '/\[confirm\]/ && /nb:'"$1"' / { next } { print }'
}

_confirm_line_hash() {  # nb — the h: recorded in the live confirm line
  grep -F "nb:$1 " "$PENDING" 2>/dev/null | grep '\[confirm\]' | head -1 \
    | sed -E 's/.* h:([a-f0-9]+) -->.*/\1/'
}

_commit_ask_done() {  # qid date bullet — bullet/qid via -v to avoid awk-program injection
  local qid="$1" date="$2" bullet="$3" tmp
  tmp="$(mktemp)" || { echo "ERROR: mktemp for commit" >&2; return 1; }
  awk -v qid="$qid" -v d="$date" -v b="$bullet" '
    $0 ~ /^- \[ \] \[ask\]/ && index($0, "(qid: " qid ")") && $0 !~ /\[confirm\]/ {
      sub(/^- \[ \] \[ask\]/, "- [x] [done]")
      print $0 " — answered " d ": " b
      next
    } { print }
  ' "$PENDING" > "$tmp" && mv "$tmp" "$PENDING" || { rm -f "$tmp"; return 1; }
}

# ---------- proposal store ----------
# record: nb|qid|hash|confidence|created_epoch|status|bullet_b64

_proposal_line() { grep "^$1|" "$PROPOSALS" 2>/dev/null | head -1; }
_prop_field()    { printf '%s' "$1" | cut -d'|' -f"$2"; }

_stage_proposal() {  # nb qid hash conf bullet
  printf '%s|%s|%s|%s|%s|staged|%s\n' "$1" "$2" "$3" "$4" "$NOW_EPOCH" "$(_b64enc "$5")" >> "$PROPOSALS"
}

_mark_proposal() {  # nb newstatus
  local nb="$1" st="$2" tmp
  tmp="$(mktemp)" || { echo "ERROR: mktemp for _mark_proposal" >&2; return 1; }
  if awk -F'|' -v OFS='|' -v nb="$nb" -v st="$st" '$1==nb {$6=st} {print}' "$PROPOSALS" > "$tmp"; then
    mv "$tmp" "$PROPOSALS"
  else
    rm -f "$tmp"; return 1
  fi
}

_mint_nb() {
  local n=0
  [ -f "$NB_COUNTER" ] && n="$(cat "$NB_COUNTER" 2>/dev/null)"
  n=$((n + 1)); printf '%s' "$n" > "$NB_COUNTER"
  printf 'nb-%s-%02d' "$(_date_ymd "$NOW_EPOCH")" "$n"
}

# ---------- classifiers / handlers ----------

handle_confirm() {  # nb
  local nb="$1" line qid storehash status linehash bullet q
  line="$(_proposal_line "$nb")"
  if [ -z "$line" ]; then _needs_review "late/unknown \`ok $nb\` — no live proposal (expired?)"; return; fi
  qid="$(_prop_field "$line" 2)"; storehash="$(_prop_field "$line" 3)"; status="$(_prop_field "$line" 6)"
  if [ "$status" = "committed" ] || _qid_done "$qid"; then
    _mark_proposal "$nb" committed; return   # idempotent no-op
  fi
  linehash="$(_confirm_line_hash "$nb")"
  if [ -n "$linehash" ] && [ "$linehash" != "$storehash" ]; then
    _needs_review "confirmation $nb changed since you saw it (binding drift) — re-propose"; return
  fi
  bullet="$(_b64dec "$(_prop_field "$line" 7)")"
  if [ -z "$bullet" ]; then _needs_review "confirm $nb — answer empty/undecodable; re-issue \`ok $nb\`"; return; fi
  # Re-check discretion at commit time: the denylist reloads each run, so a term
  # added after the bullet was staged must still block the answer from egressing
  # to the (synced) Profile/_inbox.
  if _is_flagged "$bullet"; then
    _needs_review "confirm $nb held — answer now matches the discretion denylist (content withheld)"; return
  fi
  q="$(_question_for_qid "$qid")"
  # Only tear down the proposal + stage the profile answer if the Pending.md
  # commit actually succeeded — otherwise the explicit ok is silently lost.
  if ! _commit_ask_done "$qid" "$(_date_ymd "$NOW_EPOCH")" "$bullet"; then
    _needs_review "commit failed for $nb (could not write Pending.md) — re-issue \`ok $nb\` to retry"; return
  fi
  _remove_confirm_line "$nb"
  _mark_proposal "$nb" committed
  printf -- '- (%s) answered "%s": %s\n' "$(_date_ymd "$NOW_EPOCH")" "$q" "$bullet" >> "$PROFILE_INBOX"
}

handle_correct() {  # nb action(note|dismiss)
  local nb="$1" action="$2" line qid bullet
  line="$(_proposal_line "$nb")"
  if [ -z "$line" ]; then _needs_review "\`$nb → $action\` — no live proposal"; return; fi
  qid="$(_prop_field "$line" 2)"
  if _qid_done "$qid"; then
    _needs_review "\`$nb → $action\` refused — that question is already confirmed (immutable)"; return
  fi
  _remove_confirm_line "$nb"
  _mark_proposal "$nb" "$action"
  if [ "$action" = "note" ]; then
    bullet="$(_b64dec "$(_prop_field "$line" 7)")"
    if _is_flagged "$bullet"; then
      _needs_review "correction $nb → note held — content now matches the discretion denylist (withheld)"
    else
      printf -- '- %s\n' "$bullet" >> "$CANDIDATES"
    fi
  fi
}

handle_candidate() {  # bullet
  local bullet="$1" out prc line qid conf nb hash q prompt
  local -a pcmd
  if _is_flagged "$bullet"; then
    _needs_review "discretion-flagged candidate held (content withheld) — hash $(_hash "$bullet")"
    return
  fi
  # Ask the harness which open question this bullet answers. It returns one line
  # "<qid> <confidence>" (or NONE). qid-legitimacy and the confidence floor are
  # validated below — the harness is not trusted to enforce them.
  prompt="Match this note to at most one of the open questions it answers.

NOTE:
$bullet

OPEN QUESTIONS (id<TAB>text):
$OPEN_Q_LIST

Reply with ONE line: the question id, a space, your confidence 0.0-1.0, using an
id from the list. If none apply, reply with exactly: NONE. No other text."
  # PROPOSE_CMD is multi-word (`claude -p --model …`): split into argv.
  read -ra pcmd <<< "$PROPOSE_CMD"
  out="$(printf '%s' "$prompt" | "${pcmd[@]}" 2>/dev/null)"; prc=$?
  if [ "$prc" -ne 0 ]; then _needs_review "LLM harness unavailable (exit $prc) — held: $bullet"; return; fi
  line="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | head -1)"
  # shellcheck disable=SC2086  # intentional split: fields are qid + confidence
  set -- $line
  case "${1:-}" in ""|NONE|none|None) _needs_review "unmatched: $bullet"; return ;; esac
  qid="$1"; conf="${2:-0}"
  if ! _qid_is_open "$qid"; then _needs_review "proposed qid ($qid) not an open question — held: $bullet"; return; fi
  if ! awk -v c="$conf" -v m="$CONF_MIN" 'BEGIN{exit !((c+0) >= (m+0))}'; then
    _needs_review "low-confidence ($conf) match — held: $bullet"; return
  fi
  nb="$(_mint_nb)"; hash="$(_hash "$bullet")"; q="$(_question_for_qid "$qid")"
  _stage_proposal "$nb" "$qid" "$hash" "$conf" "$bullet"
  _append_confirm_line "$nb" "$qid" "$hash" "$bullet" "$q"
}

handle_note() {  # text
  if _is_flagged "$1"; then
    _needs_review "discretion-flagged note held (content withheld) — hash $(_hash "$1")"
    return
  fi
  printf -- '- %s\n' "$1" >> "$CANDIDATES"
}

# ---------- 1. sync-conflict surfacing (read the copy's NAME, never its body) ----------
for _c in "${DROPBOX%.md}".sync-conflict-*.md "${DROPBOX}".sync-conflict-*; do
  [ -e "$_c" ] || continue
  _key="conflict:$(_hash "$_c")"
  _is_seen "$_key" && continue
  _needs_review "sync conflict on $(basename "$DROPBOX") — reconcile $_c into the primary, then delete the copy"
  _seen_add "$_key"
done

# ---------- 2. open-question map (for the LLM proposer + confirm-line text) ----------
OPEN_Q_LIST="$(grep '^- \[ \] \[ask\]' "$PENDING" 2>/dev/null | grep -v '\[confirm\]' \
  | sed -E 's/^- \[ \] \[ask\][[:space:]]*\(qid:[[:space:]]*([^)]+)\)[[:space:]]*/\1\t/')"

# ---------- 3. route each unseen bullet under "## For the CEO" ----------
[ -f "$DROPBOX" ] || DROPBOX=/dev/null
# awk emits "<occurrence>\t<content>" per bullet. Occurrence-count keying (not
# ordinal position) is stable under mid-list insertion yet keeps intentionally-
# identical bullets distinct. awk's assoc arrays keep this portable to bash 3.2.
while IFS=$'\t' read -r occ content; do
  [ -n "$content" ] || continue
  key="$(_hash "$content"$'\x1f'"$occ")"
  _is_seen "$key" && continue

  cls="candidate"
  if [[ "$content" =~ ^ok[[:space:]]+(nb-[A-Za-z0-9-]+)$ ]]; then
    cls="confirm"; handle_confirm "${BASH_REMATCH[1]}"
  elif [[ "$content" =~ ^(nb-[A-Za-z0-9-]+)[[:space:]]*(->|→)[[:space:]]*(note|dismiss)$ ]]; then
    cls="correct"; handle_correct "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "$content" =~ ^note:[[:space:]]*(.*)$ ]]; then
    cls="note"; handle_note "${BASH_REMATCH[1]}"
  else
    handle_candidate "$content"
  fi

  _seen_add "$key"
  if _is_flagged "$content"; then
    _archive "$NOW_EPOCH class=$cls key=$key content=<withheld:discretion>"
  else
    _archive "$NOW_EPOCH class=$cls key=$key content=$content"
  fi
done < <(awk '
  /^##[[:space:]]+For the CEO[[:space:]]*$/ { insec=1; next }
  /^##[[:space:]]/ { insec=0 }
  insec && /^-[[:space:]]/ { line=$0; sub(/^-[[:space:]]+/, "", line); cnt[line]++; print cnt[line] "\t" line }
' "$DROPBOX")

# ---------- 4. expiry sweep: stale staged proposals → needs-review ----------
EXPIRY_SECS=$((EXPIRY_DAYS * 86400))
while IFS='|' read -r nb qid hash conf created status _; do
  [ -n "${nb:-}" ] || continue
  [ "${status:-}" = "staged" ] || continue
  if [ $((NOW_EPOCH - created)) -gt "$EXPIRY_SECS" ]; then
    _remove_confirm_line "$nb"
    _mark_proposal "$nb" expired
    _needs_review "proposal $nb expired after ${EXPIRY_DAYS}d without confirmation — re-propose if still relevant"
  fi
done < "$PROPOSALS"

exit 0
