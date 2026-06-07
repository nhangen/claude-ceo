# ceo-scheduler

Internal CEO lib — the **cron next-fire matcher** for the `ceo-schedulerd` daemon
(issue #136, Phase 1.5). Given a 5-field cron expression, it answers two
questions the daemon needs:

- **`nextFire(expr, from)`** — the next fire instant strictly after `from` (what
  the daemon sleeps until), or `null` if the cron never fires again.
- **`matchesAt(expr, when)`** — whether the cron fires during the minute
  containing `when` (seconds ignored).

It is the foundation of the dispatcher redesign: the daemon (#142) and missed-slot
catch-up (#143) both build on it. Dispatch stays in bash (`ceo-cron.sh`); this
module only computes *when*.

## Why a module, not inline

The repo previously had only a cron *enumerator* (`_ceo_cron_field_expand` in
`scripts/ceo`), which expands a field into its values — it cannot compute a
next-fire instant, handle day-of-month-OR-day-of-week, or reason about DST.

## Engine

[`croner`](https://github.com/hexagon/croner) backs the matcher, isolated behind
the `CronMatcher` interface so it can be swapped without touching the daemon.
croner runs in `legacyMode` (Vixie semantics): when **both** day-of-month and
day-of-week are restricted, the cron fires if **either** matches — the behavior
native cron and the registry's schedules assume.

Only the 5-field form is accepted (croner's optional 6-field seconds form is
rejected) to preserve the minute granularity the daemon and `matchesAt` assume.

## Usage

```ts
import { createMatcher } from "@/cron";

const m = createMatcher({ timezone: "America/New_York" }); // omit → host-local
const next = m.nextFire("30 9 * * 1-5", new Date()); // next weekday 09:30 ET
const firingNow = m.matchesAt("*/15 * * * *", new Date());
```

`createMatcher` accepts an optional IANA `timezone`; schedules are evaluated in
that zone (defaults to host-local). Invalid or non-5-field expressions throw
`CronExpressionError`.

## Develop

```bash
bun install
bun test            # edge-case matrix: wildcards/ranges/lists/steps, DOM-OR-DOW,
                    # month, minute-granularity matchesAt, invalid exprs, tz, DST
bun run typecheck
```
