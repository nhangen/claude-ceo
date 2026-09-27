---
name: context-refresh
description: Rebuild accepted context projections and report source drift or review needs
trigger: cron
schedule: "17,47 * * * *"
runner: script
script: ceo-context-refresh.sh
preflight: none
tier: low-stakes write
status: active
scope: single
---

# Context Refresh

A deterministic discovery and projection worker. Cronbird runs it on one scheduler
owner after initializing context through the context CLI and reviewing claims there.
It first checks Vaultkeeper's local scan health, then watches only CEO/from-nathan.md,
Profile/_inbox/*.md, Profile/goals.md, Profile.md, and Daily notes from the rolling
review window. Vaultkeeper health proves only that a local scan completed; it does not
prove upstream sources arrived. It makes no model calls and does not promote inferred
facts.
Every report gather also reads the ledger directly, so a delayed refresh cannot cache
an old accepted fact. An absent ledger retains the profile migration path.

## Outputs

- `CEO/reports/context/current.json` and `current.md`: overwrite derived current view;
  unchanged content is not rewritten.
- `CEO/alerts/context.md`: overwrite state with frontmatter; review/conflicts are
  `firing`, clean projections `clear`, unreadable/corrupt ledger `unknown`.
- CEO/log/context/YYYY-MM.md: appends private, inferred, content-addressed review
  candidates for changed bounded sources. It never accepts or withdraws a claim.
- CEO/alerts/context-discover.md: overwrite discovery state. A stale/faulted
  Vaultkeeper blocks discovery; denylisted source text is never copied into the ledger.
- CEO/reports/context/daily-review-queue.md: overwrite queue of every local Daily
  note in the rolling window that needs human review, keyed by its content hash. It is
  not an upstream-completeness receipt.

## Session capture

Discovery emits only private candidates. A reviewer must capture a specific fact in a
source note, ingest it with the correct effective date, and accept it with a
fact-specific authorization quote. Inferred discoveries cannot be accepted. Use
explicit supersession when correcting an accepted fact. If an accepted source changes
or disappears, its old value is withheld from reports pending review.

A local lock prevents same-host ledger write races. Use one writer host; Syncthing
conflict files stop projection until reviewed. Existing `Profile/_inbox` and training
candidates need deliberate review and ingestion. This worker is not that review.
