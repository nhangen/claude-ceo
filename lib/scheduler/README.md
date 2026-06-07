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

## The daemon (`ceo-schedulerd`, #142)

`src/main.ts` is the long-lived daemon. Each tick it re-reads
`$CEO_VAULT/CEO/registry.json`, selects the playbooks **this host** runs on a
schedule, dispatches every due one, writes a heartbeat, and sleeps until the
soonest next fire (capped at 60s so registry edits and clock skew self-heal).

Pipeline, all of it unit-tested behind injected side effects:

- `registry.ts` — `parseRegistry(text)` → `{playbooks, warnings}`. Skips entries
  missing a required field (logs a warning) instead of failing the whole load;
  normalizes `hosts` exactly like the bash scanner (absent/null/malformed → `["*"]`).
- `select.ts` — pure decisions: `selectRunnable(playbooks, host)` (this is where
  **`hosts:` is enforced** — Phase 1 only recorded it), `dueAt(playbooks, when, matcher)`,
  `nextWake(playbooks, from, matcher, capMs)`.
- `daemon.ts` — `runForever(deps)`: the loop, plus the **double-fire guard**. The
  "last dispatched minute" per playbook is persisted in the heartbeat and restored
  at startup, so a `Restart=always` crash inside a fire-minute does not re-run a
  playbook.
- `heartbeat-store.ts` — durable read/write of the heartbeat
  (`~/.ceo/schedulerd/heartbeat.json`, host-local, **not** the synced vault).
  Corrupt/missing → guard starts empty, no crash.
- `catchup.ts` — `newestMissedSlot` / `catchUpFires`: when a downtime or suspend
  gap means slots were skipped, fire **once** for the newest missed slot per
  playbook and skip the rest (no replay storm), bounded by `CATCHUP_LOOKBACK_MS`
  so a stale slot isn't run late. Driven by `last_fired` in the heartbeat (#143).
- `runtime.ts` — path/host/argv helpers and the `MAX_SLEEP_MS` / `HEARTBEAT_STALE_MS`
  / `CATCHUP_LOOKBACK_MS` constants. Dispatch spawns `ceo-cron.sh <name> --scheduled`
  directly (no shell), with `CEO_VAULT` passed via the spawn environment.

Schedules evaluate in the **host's local timezone** (the matcher is created with no
timezone; registry schedules carry no per-entry tz). A second host in a different
zone would need a per-entry tz — out of scope until that exists.

### Missed-slot catch-up (#143)

The live loop only fires the current minute, so slots that should have fired while
the daemon was **down** (or a sleep overshot on suspend) would be lost. On each
tick the daemon also computes catch-up fires: for a playbook that owes fires since
its `last_fired`, it dispatches **once** for the newest missed slot within the
look-back window (default 1h) and skips the rest. A playbook already firing this
minute is not also caught up, and a first-seen playbook (no `last_fired` baseline)
is initialized to "now" rather than replayed.

`last_fired` is persisted in the same pre-dispatch heartbeat write as the
double-fire guard, so catch-up keeps #142's **at-most-once** invariant: a crash
drops a fire rather than doubling it. (This is a deliberate divergence from #143's
"persist after dispatch confirms" wording — at-most-once is the safer guarantee
for write-tier playbooks, and dispatch is a fire-and-forget spawn whose completion
the daemon can't observe anyway.)

The look-back is **one global value** (`CATCHUP_LOOKBACK_MS`, default 1h),
overridable per host via the `CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS` env var (a
non-numeric/zero/negative value falls back to the default). A single global value
is a known limitation: it suits sub-hourly playbooks but is wrong for the
daily-report playbooks that dominate the registry — a daily slot missed by more
than the look-back is **not** replayed (by design, so a morning job doesn't run
late at night). A daily-heavy host should raise the env var; per-playbook (or
per-cadence) look-back is the fuller fix, tracked as a follow-up.

### Run / keep-alive (Linux/WSL)

```bash
CEO_VAULT=~/Documents/Obsidian bun run src/main.ts   # foreground
```

For keep-alive, install the systemd **user** unit template at
`deploy/ceo-schedulerd.service` (see the header comments in that file). macOS
keep-alive is Phase 2 (#144). **Not yet smoke-tested on a live always-on Linux
host** (ML-1 GPU-down) — the loop, guard, and heartbeat are verified via
fake-clock tests and a local start/SIGTERM smoke; only `Restart=always` is
hardware-unverified.

### Liveness

`ceo doctor` reads the heartbeat and reports the daemon alive / stale (>10 min) /
malformed / not-running. The 10-min threshold mirrors `HEARTBEAT_STALE_MS`.

## Develop

```bash
bun install
bun test            # matcher edge matrix + registry/select/daemon/runtime/heartbeat
bun run typecheck
```
