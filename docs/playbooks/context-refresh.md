---
name: context-refresh
description: Rebuild accepted context projections and report source drift or review needs
trigger: cron
schedule: "17,47 * * * *"
runner: script
script: ceo-context-refresh.sh
preflight: none
tier: low-stakes write
status: draft
---

# Context Refresh

A deterministic projection worker. Enable on one scheduler owner after initializing
context through `ceo context ingest` and reviewing claims with `ceo context accept`.
It makes no model calls and does not promote inferred facts or scan prose for new facts.
Every report gather also reads the ledger directly, so a delayed refresh cannot cache
an old accepted fact. An absent ledger retains the profile migration path.

## Outputs

- `CEO/reports/context/current.json` and `current.md`: overwrite derived current view;
  unchanged content is not rewritten.
- `CEO/alerts/context.md`: overwrite state with frontmatter; review/conflicts are
  `firing`, clean projections `clear`, unreadable/corrupt ledger `unknown`.
- The session-driven CLI appends evidence and decisions to
  `CEO/log/context/YYYY-MM.md`. This worker never changes the ledger or inbox.

## Session capture

When a user states a durable role, priority, constraint or retirement, capture its
source note and effective date, then ingest a record as documented in README.
Default to private candidate evidence. Accept only when explicit user authorization
covers that fact and report visibility; record the acting agent separately from the
authorization source. Inferred suggestions remain candidates until a new confirmed
observation is recorded. Use explicit supersession when correcting an accepted fact.

A local lock prevents same-host ledger write races. Use one writer host; Syncthing
conflict files stop projection until reviewed. Existing `Profile/_inbox` and training
candidates need deliberate review and ingestion. This worker is not that review.
