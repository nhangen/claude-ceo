# Perch — Standalone Host-Aware Cron Scheduler (Extraction of ceo-schedulerd)

**Date:** 2026-06-29
**Status:** Design approved; spec under review
**Goal:** Extract the generic scheduling engine currently embedded in `claude-ceo/lib/scheduler/` (`ceo-schedulerd`) into a standalone, product-agnostic cron/scheduler product (`perch`), with CEO becoming one adapter rather than the host.

---

## Why

`ceo-schedulerd` is a Bun/TypeScript daemon that already does the hard, generic part well: it matches 5-field cron schedules (via croner, with Vixie day-of semantics + DST), decides which jobs are due, replays the newest missed slot within a bounded look-back window, and guarantees at-most-once dispatch via a double-fire guard persisted *before* each dispatch. A codebase research pass found roughly **75% of the daemon is already CEO-agnostic** and confined the CEO coupling to four narrow seams:

1. Hardcoded file paths (`~/.ceo/registry.json`, `~/.ceo/enabled.json`, `<vault>/CEO/swarm.json`, heartbeat paths under `~/.ceo/schedulerd/`).
2. `CEO_*` environment variable names (`CEO_VAULT`, `CEO_HOSTNAME`, `CEO_CRON_BIN`, `CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`).
3. The playbook registry schema fields the daemon reads (`name`, `schedule`, `status`, `trigger`, `hosts`, `scope`).
4. The dispatch binary — a shell invocation `ceo-cron.sh <name> --scheduled`.

Because the engine is generic and the coupling is thin, extraction is **purely additive and low-risk**: CEO keeps running unchanged while the generic core develops, and the running daemons on ML-1 and the MacBook do not break.

The user's framing: *"the cron app should be its own thing not just ceo based."* This spec makes it its own thing.

## Decisions (approved)

| Decision | Choice | Rationale |
|---|---|---|
| End state | **Standalone repo** (`nhangen/perch`); claude-ceo consumes it as a dependency | Matches "its own thing"; additive extraction makes the repo split cheap |
| Dispatch contract | **Shell command** (argv template), language-agnostic | The real "not just CEO" test — any project in any language can drive it; CEO's `ceo-cron.sh` becomes one such command |
| v1 scope | **Full machinery** — cron-match + select + double-fire guard + heartbeat/multi-host (topology owners, `scope: each`/`single`, liveness) | Already built and tested (~1230 lines of tests); excluding it would discard working code. Single-host consumers simply omit a topology provider. |
| Name | `perch` | Short, evocative (the daemon perches and fires on schedule), unclaimed |
| Distribution | **Private** repo, consumed by claude-ceo via git/path dependency; clean publish path to npm/jsr deferred | Avoids license/support/namespace obligations now; additive design means going public later is a cheap, separate decision |

## Tech Stack

- Bun runtime, TypeScript (matches the existing daemon).
- `croner` ^9 for cron matching (the one runtime dependency the engine needs).
- No product dependencies in the core package.

---

## Architecture

Two packages in the new `perch` repo:

```
perch/                            (new repo: nhangen/perch)
  packages/core/                  @perch/core — the engine, zero product deps
    src/
      types.ts                    Job<T>, Topology, Heartbeat, interfaces
      cron.ts                     croner wrapper (CronMatcher)
      select.ts                   selectRunnable / dueAt / nextWake (pure)
      catchup.ts                  missed-slot detection, cadence-derived look-back
      daemon.ts                   runScheduler<T>(deps) — the tick loop + guard
    tests/                        migrated from lib/scheduler/tests (clock/fs/spawn injected)
  packages/cli/                   @perch/cli — generic file-config runner
    src/
      config.ts                   parse + validate perch.config.json
      providers.ts                file-based JobProvider (registry/enabled/topology JSON)
      shell-dispatcher.ts         ShellDispatcher (argv template → spawn)
      heartbeat-file.ts           file HeartbeatStore (+ optional synced dual-write)
      main.ts                     wire config → providers → dispatcher → runScheduler
  deploy/
    perch.plist.template          launchd (parameterized label/paths)
    perch.service.template        systemd user unit
  README.md
```

`claude-ceo/lib/scheduler/` does **not** disappear — it shrinks to a thin CEO **adapter** that depends on `@perch/core` (and reuses `@perch/cli`'s file providers + shell dispatcher where they fit). The CEO-specific pieces that remain:

- Mapping `CEO_VAULT` / `CEO_HOSTNAME` / `CEO_CRON_BIN` env → a generic config object.
- The registry/enabled/swarm file paths under `~/.ceo/` and the vault.
- The dual-write heartbeat (local + `<vault>/CEO/heartbeats/<host>.json`) for `ceo doctor` liveness.
- The dispatch command `ceo-cron.sh <name> --scheduled`.

### The boundary (core interfaces)

```typescript
interface Job<T> {
  name: string;
  cronSchedule: string;       // 5-field cron expression
  isActive: boolean;          // only active jobs fire
  hosts: string[];            // ["*"] = all hosts; ["ml-1"] = host filter
  scope: "each" | "single";   // each → per-host enablement; single → topology ownership
  metadata: T;                // product-specific fields (model, tier, runner, ...)
}

interface JobProvider<T> {
  // Return null on a torn/corrupt read → daemon reuses last-good (no unowning mid-tick).
  loadJobs(): { jobs: Job<T>[]; warnings: string[] } | null;
  // Per-host enablement of scope:each jobs. Empty set on read error (fail-safe).
  loadEnabled(): Set<string>;
  // Cross-host topology (owners map for scope:single). Null → reuse last-good.
  loadTopology(): Topology | null;
}

interface Topology {
  hosts: string[];
  owners: Record<string, string>;   // jobName → owning host
}

interface Dispatcher<T> {
  // Fire-and-forget. MUST NOT throw out of the loop — log + skip on error.
  dispatch(job: Job<T>): void;
}

interface HeartbeatStore {
  read(): Heartbeat | null;          // null on missing/corrupt
  write(hb: Heartbeat): void;
}

interface Heartbeat {
  ts: number;
  hostId: string;
  jobsRunnable: number;
  nextWakeTs: number;
  dispatchedMinute: Record<string, number>;  // double-fire guard
  lastFired: Record<string, number>;          // catch-up baseline
}

interface SchedulerConfig {
  hostname: string;
  maxSleepMs: number;                          // tick cap (registry re-read cadence)
  catchupLookback: (schedule: string, now: Date) => number;
}

export async function runScheduler<T>(
  config: SchedulerConfig,
  provider: JobProvider<T>,
  dispatcher: Dispatcher<T>,
  heartbeat: HeartbeatStore,
): Promise<void>;
```

A non-TS project gets a fully working daemon with **zero code**: install `@perch/cli`, write a `perch.config.json` pointing at a registry JSON and a dispatch command, and run it under launchd/systemd. The default `ShellDispatcher` spawns `<dispatchCommand> <jobName> <...configuredArgs>`.

### Generic config (replaces CEO_* env coupling)

`perch.config.json` (paths absolute or `~`-expanded):

```json
{
  "hostname": "auto",
  "registryPath": "~/.perch/registry.json",
  "enabledPath": "~/.perch/enabled.json",
  "topologyPath": null,
  "heartbeatPath": "~/.perch/heartbeat.json",
  "syncedHeartbeatDir": null,
  "dispatchCommand": ["my-runner.sh"],
  "dispatchArgsTemplate": ["{job}", "--scheduled"],
  "maxSleepMs": 60000,
  "catchupLookbackFloorMs": 3600000,
  "catchupLookbackCapMs": 21600000
}
```

`topologyPath: null` and `syncedHeartbeatDir: null` collapse the daemon to single-host mode (no multi-host ownership, no synced liveness) — the generic, no-swarm case. CEO's adapter fills all fields from its env so its on-disk paths and behavior are byte-identical to today.

---

## Data flow & invariants (unchanged from today)

Each tick (at most `maxSleepMs` apart):

1. Read registry + enabled + topology (each with its documented fail-safe direction).
2. `selectRunnable(jobs, host, enabled, owners)` — keep active jobs whose `hosts` matches this host AND whose scope condition holds (`each` → name in enabled set; `single` → `owners[name] === host`).
3. For each job due now (or with a missed slot inside its look-back window):
   a. Persist the double-fire guard (`dispatchedMinute[name] = thisMinute`) **before** dispatch — the at-most-once invariant.
   b. `dispatcher.dispatch(job)` — fire-and-forget.
   c. Record `lastFired[name]`.
4. Write the heartbeat (local; and synced per-host copy if configured).
5. Sleep until the next fire time, capped at `maxSleepMs` (so the registry is re-read at least that often and the loop self-heals).

Catch-up replays only the **newest** missed slot per job (no replay storm) within a per-schedule window derived from cadence and clamped to `[floor, cap]` (default 1h–6h). First-seen jobs initialize `lastFired` to now (no historical replay on first boot).

## Error handling (fail-safe directions preserved)

| Condition | Behavior |
|---|---|
| Torn/corrupt registry read | `loadJobs()` returns null → reuse last-good jobs |
| Torn/corrupt topology read | `loadTopology()` returns null → reuse last-good owners (don't unown `single` jobs mid-tick) |
| Unreadable enabled file | empty set → nothing `each`-enabled (safe default) |
| One malformed job in registry | skip + warn; the rest of the registry still loads |
| Dispatch spawn error | log + skip the job; loop never crashes |
| Missing croner dependency | documented crash-loop; deploy templates note `bun install` requirement |
| Missing/corrupt heartbeat | treated as no prior guard; first tick initializes (no false double-fire) |

## Testing & migration

- The existing ~1230 lines of tests (`daemon`, `registry`→provider, `select`, `cron`, `catchup`, `heartbeat-store`, `enabled`, `swarm`→topology, `runtime`) move into `@perch/core` and `@perch/cli` largely as-is — they already inject clock, filesystem, and spawn.
- **New tests:**
  - `ShellDispatcher` argv-contract test: assert the spawned argv matches `<command> <job> <templatedArgs>` exactly, and that a dispatch error is caught (not thrown) — per the `stub-cli-argv-validation` and `non-throwing-client-success-check` rules.
  - CEO-adapter round-trip test: feed CEO env (`CEO_VAULT`, `CEO_HOSTNAME`, `CEO_CRON_BIN`) through the adapter and assert the resolved config produces **today's exact paths and dispatch argv** — the regression guard that the extraction changed nothing observable for CEO.
- **README** ships with the `perch` repo at creation (required-README rule): engine overview, config reference, single-host quickstart, multi-host/topology section, deploy templates.

### Migration sequence (staged, each step independently verifiable)

1. Create `nhangen/perch` with `@perch/core` built from the current generic modules + migrated tests. Green test suite is the gate.
2. Add `@perch/cli` (file providers, ShellDispatcher, file heartbeat, config) + its tests.
3. Point `claude-ceo/lib/scheduler` at `@perch/core` as an adapter (CEO env → config). Run the adapter round-trip test.
4. Verify the live daemon on ML-1 and the MacBook: `ceo doctor` heartbeat fresh, a scheduled playbook fires, double-fire guard intact across ticks.
5. Delete the now-duplicated generic modules from `claude-ceo/lib/scheduler` (they live in `@perch/core` now). Confirm no remaining duplicate-source drift.

Each migration step is its own PR-sized unit. claude-ceo is never in a broken intermediate state because the adapter swap (step 3) is behavior-preserving by construction and guarded by the round-trip test.

## Out of scope (v1)

- Publishing `perch` publicly to npm/jsr (deferred; private/git-consumed for now).
- A second non-CEO consumer (the design supports one; building one is separate work).
- Any change to CEO playbook semantics, registry schema, or `ceo playbook scan` behavior — the adapter consumes the existing shapes unchanged.
- A web UI / dashboard for the scheduler.
