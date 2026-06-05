---
name: reconcile
description: Propose which open inbox/daily-note to-dos can be closed or amended, from recent daily notes + PR state
trigger: cron
schedule: "50 7 * * 1-5"
runner: claude
model: sonnet
preflight: none
tier: high-stakes
status: draft
inputs: ["pr_data", "daily_note", "pending_count", "today_log", "yesterday_log"]
artifact: CEO/reports/reconcile/{TODAY}.md
---

# Reconcile

Read recent evidence of completed work and propose which open to-dos can be closed or
amended. **Propose only — never close, archive, or edit a to-do in place.** Each
proposal is a **high-stakes action**: the dispatcher's FILTER phase routes it to
`CEO/approvals/pending.md` and the user approves it there. Approval is what actually
checks an item off; this playbook never does.

## What to read (cwd is the vault root)

1. `CEO/inbox.md` — every unchecked `- [ ]` item. Skip `[x]`, `[done]`, `[failed]`.
2. The 3 most recent daily notes under `Daily/` (by dated filename, newest first,
   on or before today). Read them in full. Also collect any unchecked `- [ ]` lines
   under a `## Tasks` heading in those notes — those are open to-dos too.
3. PR/issue evidence comes ONLY from the pre-gathered `PR data` lines. Do NOT run
   `gh` or any git command. If an item names a PR/issue that is not in the
   pre-gathered sets, treat its PR state as unknown.

## How to classify each open to-do

Assign exactly one verb per item:

- **close** — high confidence the whole item is done. The only strong signal is a
  repo-qualified `org/repo#N` that appears in the pre-gathered PR data as MERGED, and
  whose verb is satisfied by a merge. A *review*/*QA*/*check* task is NOT satisfied by
  a merge. A closed-unmerged PR is NOT "done". When unsure, do not use close.
- **amend** — partially done or a bundle of subtasks where some are done and some are
  not (e.g. "move pcri and decon to wsl" with pcri mostly done, decon not). Propose a
  rewrite that resolves the done portion and keeps the rest open. State explicitly
  what is NOT covered (if the note says "mostly", say so).
- **keep** — no sufficient evidence. Leave it untouched and do NOT propose anything.

## What to propose and record

**Proposals (close / amend) are high-stakes actions — do NOT write `approvals/pending.md`
yourself.** In the PLAN phase, emit one `ACTION` line per close/amend at the
`high-stakes` tier; the shell FILTER routes them to `CEO/approvals/pending.md` in the
canonical format and defers them for approval. Pack the whole proposal into the
description (the command field is `n/a` — there is no command to run):

```
ACTION: <n> | high-stakes | reconcile close: "<to-do verbatim>" — <one-line evidence, e.g. org/repo#N merged> | n/a
ACTION: <n> | high-stakes | reconcile amend: "<to-do verbatim>" → <rewritten line>; NOT covered: <what remains> | n/a
```

**Decision record (low-stakes-write).** Emit one `low-stakes-write` ACTION to append
today's full record to `CEO/reports/reconcile/<TODAY>.md` (create the file if absent),
one line per item examined — including `keep`s, which are not proposed elsewhere:

```
- <close|amend|keep> | <confidence: high|medium|low> | <to-do verbatim> | <evidence or "none">
```

This is the only file this playbook writes directly. The record is the audit trail;
the approvals queue holds only the actionable close/amend subset. **Always emit this
report ACTION — even on a day when every item is `keep` and there are no proposals —
so the record always exists for the morning scan** (otherwise, with no safe action to
execute, the run produces nothing).

## Hard invariants (v1)

- Do NOT write to `CEO/inbox.md`.
- Do NOT edit any file under `Daily/` (no in-place `[x]`).
- Do NOT write to `CEO/approvals/pending.md` directly — proposals reach it only as
  filtered high-stakes actions.
- Do NOT run `gh`, `git`, or any command that changes remote state.
- Nothing is closed or archived automatically — every resolution is a proposal.

## Output

End with the LOG_ENTRY block. In **Output** give the counts; in **Proposals** list the
close/amend proposals (these are the high-stakes actions written to pending.md):

```
**Output:**
Reconcile: <N> close-proposed, <N> amend-proposed, <N> kept. Record: CEO/reports/reconcile/<TODAY>.md
**Proposals:**
- <each close/amend proposal, or 'none'>
```
