---
name: nathan-inbox
description: Ingest Nathan's freeform replies from the CEO/from-nathan.md dropbox; propose answers to open Pending.md questions (confirm-before-commit), route notes, never auto-commit or silently drop
trigger: cron
schedule: "15 3 * * *"
preflight: none
tier: low-stakes-write
status: active
scope: single
runner: script
script: ceo-nathan-inbox.sh
model: sonnet
---

# Nathan Inbox

Shell-only ingest for the CEO **reply channel**. The daily report is send-only;
this is the inbound half. Nathan writes freeform bullets in a synced dropbox
from any device; this playbook routes them on the next CEO run, **before**
`morning`, so proposals surface in that morning's report.

Runs all 7 days at ~03:15 (weekend answers must not wait for Monday).

## The dropbox — `CEO/from-nathan.md`

Single-writer by convention: **only Nathan edits it; this playbook reads it and
never writes or clears it.** Bullets live under a `## For the CEO` heading:

```markdown
## For the CEO
- my single most important goal this quarter is closing the 2nd Altamira CoP
- note: stop surfacing dependabot PRs as priorities, I batch them
- ok nb-2026-07-06-03
- nb-2026-07-06-04 → note
```

- plain bullet → **candidate** answer (classified by a bounded LLM proposal).
- `note: <text>` → freeform note (skips question-matching).
- `ok <nb-id>` → confirm a proposed match.
- `<nb-id> → note` / `<nb-id> → dismiss` → correct or dismiss a proposal.

No `qid` typing. The `nb-…` ids Nathan references are pre-printed in the report.

## Confirm-before-commit (the safety mechanism)

A wrong auto-answer would *silently and permanently* close a question Nathan
never answered. So a fuzzy LLM match is **never** auto-committed:

1. A candidate bullet gets an LLM proposal `{qid, confidence}`. The proposed qid
   is **validated against the live open-`[ask]` set** — a hallucinated qid is
   discarded (→ needs-review).
2. A validated, confident match is *staged*: a frozen record in
   `CEO/log/proposed-answers.md` **and** a `- [ ] [ask] [confirm] …` line
   written into `Pending.md` (which `morning` already quotes). The question is
   **not** yet answered.
3. Nathan replies `ok <nb>` next time → the answer commits: the `[ask]` line
   flips to `[x] [done]`, the answer stages to `Profile/_inbox/<host>.md`.

Commit is idempotent (guarded by the qid's live `[done]` state) and
binding-checked: the `ok` commits only if the frozen `(nb → qid, content-hash)`
still matches what was reported. Unconfirmed proposals expire to needs-review
after `CEO_NATHAN_EXPIRY_DAYS` (default 7).

## qid (auto-stamped)

Every matchable `Pending.md [ask]` line carries a `qid:` token, e.g.
`- [ ] [ask] (qid: q-80ffff) what is my top goal this quarter`. **Nobody mints
these by hand** — not Nathan (who never edits `Pending.md`), not the authoring
agent. Before building the open-question map each run, the ingest auto-stamps
`(qid: q-<6-char sha1 of the question text>)` onto any open `[ask]` line missing
one. The stamp is idempotent, stable (same text → same id), and skips `[confirm]`
lines and already-tagged lines. Local hash only — no LLM egress, no discretion
concern. A question authored without a qid is therefore matchable on the next
run, not lost to needs-review.

## Outputs

| File | Mode | When |
|---|---|---|
| `Pending.md` | edit | Stage `[confirm]` lines; flip `[ask]`→`[done]` on commit. Only file whose `[done]` state gates immutability. |
| `CEO/log/proposed-answers.md` | append/rewrite | Frozen proposal records `nb\|qid\|hash\|confidence\|created_epoch` (machine-owned state). |
| `CEO/log/.from-nathan-seen` | append | Processed-entry hash set (reprocessing guard). |
| `CEO/log/.nathan-nb-counter` | overwrite | Global append-only counter minting stable `nb-` ids (never reused). |
| `CEO/log/from-nathan/YYYY-MM.md` | append | Durable archive; one line per processed entry (content withheld for discretion-flagged). |
| `CEO/training/_candidates.md` | append | Freeform notes; **never** the live corpus (a human promotes later). |
| `CEO/needs-review/nathan-inbox.md` | append | Everything held: low-confidence, hallucinated qid, expired, drifted, discretion-flagged (withheld), sync-conflict. **Nothing is ever silently dropped.** |
| `Profile/_inbox/<host>.md` | append | Committed answers staged for profile promotion. |

## Discretion

Before writing any bullet content to a synced/logged file, a fixed-string
denylist (`Profile/discretion-denylist.txt` + `CEO_DISCRETION_DENY`, same
mechanism as `ceo-observe.sh`) is applied. A hit is held in needs-review with
its **content withheld** (only a hash recorded) — the flagged text is not
written to proposals, candidates, archive, or profile.

## On-demand

`ceo cron nathan-inbox` runs it immediately (`CEO_FORCE=1`), bypassing cooldown.

## Origin

v1 of the CEO training loop's *enabler* (the reply channel). Capture
(auto-detecting recurring instructions) and Enforce (in-session agent
supervision) are later subsystems. Design lives in Obsidian, not the repo.

## Documented gaps

- The match is the only non-deterministic step. It uses the **installed Claude
  Code harness** directly — headless `claude -p` (override with
  `CEO_NATHAN_PROPOSE_CMD`, default `claude -p --model $CEO_MODEL`) — not a
  wrapper or a spawned CEO subprocess. The harness returns one line
  `<qid> <confidence>` (or `NONE`); the ingest validates the qid against the open
  set and applies the confidence floor. If the harness fails/unavailable, the
  candidate falls through to needs-review — no silent loss. Every other path is
  deterministic bash and unit-tested.
- **No lock:** a cron run racing a manual `ceo cron nathan-inbox` could read the
  seen-set before either appends and double-propose one bullet. `scope: single`
  on one scheduler makes this rare; a `flock` guard is a follow-up.
- Proposing among *several* open questions and two bullets matching one qid in a
  single run are correctly handled by the qid-`[done]` guard but not yet
  regression-tested (follow-up).
- Substring discretion matching has an acknowledged false-negative risk; the
  needs-review bucket is the backstop.
- Re-targeting a proposal to a *different specific* question is out of scope for
  v1 (Nathan doesn't see qids); a wrong match is dismissed and re-answered as a
  fresh bullet.

## Install / Disable

Registered by `ceo playbook scan` (ML-1 only, `scope: single`). Disable via
`status: disabled` + re-scan.
