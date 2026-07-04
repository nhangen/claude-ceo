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

`src/main.ts` is the long-lived daemon. Each tick it re-reads the host-local
`~/.ceo/registry.json` (written by `ceo playbook scan`; the synced vault holds
only `CEO/swarm.json` and `CEO/heartbeats/`, not the registry), selects the
playbooks **this host** runs on a schedule, dispatches every due one, writes a
heartbeat, and sleeps until the soonest next fire (capped at 60s so registry
edits and clock skew self-heal).

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
- `catchup.ts` — `newestMissedSlot` / `catchUpFires` / `lookbackForSchedule`: when
  a downtime or suspend gap means slots were skipped, fire **once** for the newest
  missed slot per playbook and skip the rest (no replay storm), bounded by a
  per-schedule look-back derived from each playbook's own cadence (#157) so a stale
  slot isn't run late. Driven by `last_fired` in the heartbeat (#143).
- `runtime.ts` — path/host/argv helpers and the `MAX_SLEEP_MS` / `HEARTBEAT_STALE_MS`
  / `CATCHUP_LOOKBACK_FLOOR_MS` / `CATCHUP_LOOKBACK_CAP_MS` constants. Dispatch spawns
  `ceo-cron.sh <name> --scheduled` directly (no shell), with `CEO_VAULT` passed via
  the spawn environment.

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
is initialized to "now" rather than replayed. The look-back window is per-schedule
(see below).

`last_fired` is persisted in the same pre-dispatch heartbeat write as the
double-fire guard, so catch-up keeps #142's **at-most-once** invariant: a crash
drops a fire rather than doubling it. (This is a deliberate divergence from #143's
"persist after dispatch confirms" wording — at-most-once is the safer guarantee
for write-tier playbooks, and dispatch is a fire-and-forget spawn whose completion
the daemon can't observe anyway.)

The look-back is **per-schedule, derived from each playbook's own cadence** (#157,
`lookbackForSchedule`): the cadence proxy is the **min gap** between the next few
fires (cadence-intrinsic — invariant to wake time even for irregular schedules like
`0 9,12`), clamped to `[CATCHUP_LOOKBACK_FLOOR_MS, CATCHUP_LOOKBACK_CAP_MS]` (1h–6h).
So a sub-hourly playbook gets ~1h (a slot hours stale isn't replayed) while a daily
report gets the 6h cap (an overnight-suspend miss still catches up in the morning).
A long-cadence slot missed by more than the cap is **not** replayed — by design, so
a morning job doesn't run late at night (a weekly slot missed >6h is likewise
dropped).

A host may still pin **one fixed window for every playbook** via the
`CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS` env var (the #143 escape hatch); a
non-numeric/zero/negative value is ignored and the derived per-schedule default is
used instead.

### Run / keep-alive

First install dependencies (creates `node_modules/croner`) — **required** on
every host, or the daemon crash-loops on a `croner` ENOENT:

```bash
bun install                                          # in lib/scheduler (once per host)
CEO_VAULT=~/Documents/Obsidian bun run src/main.ts   # foreground (either OS)
```

Run the daemon **from `lib/scheduler`** (or set the agent's working directory
there): it resolves the `@/*` tsconfig path alias relative to the working
directory, so `bun run` from elsewhere fails to resolve `@/cron`. The deploy
templates pin `WorkingDirectory` for exactly this reason.

One OS-level agent keeps the daemon alive; the daemon does all scheduling.

- **Linux/WSL:** install the systemd **user** unit template at
  `deploy/ceo-schedulerd.service` (see its header comments). Smoke-tested live on
  ML-1 (WSL) 2026-06-28 — comes up healthy and heartbeats with `bun install` run
  and `WorkingDirectory` set; the loop/guard/heartbeat are also covered by
  fake-clock tests.
- **macOS (#144):** install the launchd **LaunchAgent** template at
  `deploy/com.ceo.schedulerd.plist` (see its header). It needs a logged-in GUI
  session (it's a LaunchAgent, not a headless LaunchDaemon, because it reads the
  user's synced vault). `ceo playbook scan` on macOS no longer installs
  per-playbook plists — the daemon reads the registry directly.

#### Migrating off the retired per-playbook launchd backend (#98 → #144)

Before #144, macOS installed one `com.ceo.<name>-N` plist per fire-time. Those
are retired. If any remain loaded they **double-fire** alongside the daemon, so
`ceo doctor` flags them. Remove them:

```bash
for p in ~/Library/LaunchAgents/com.ceo.*.plist; do
  [ "$(basename "$p" .plist)" = com.ceo.schedulerd ] && continue
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null
  rm -f "$p"
done
```

### Liveness

`ceo doctor` reads the heartbeat and reports the daemon alive / stale (>10 min) /
malformed / not-running. The 10-min threshold mirrors `HEARTBEAT_STALE_MS`.

## Develop

```bash
bun install
bun test            # matcher edge matrix + registry/select/daemon/runtime/heartbeat
bun run typecheck
```
