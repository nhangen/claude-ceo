/**
 * Real-environment helpers for ceo-schedulerd, kept pure so they are unit-tested
 * without touching the filesystem. `main.ts` composes them with Bun's spawn/fs.
 */
import type { CompletionRecord, CronMatcher } from "cronbird/core";

/**
 * How long without a heartbeat before `ceo doctor` reports the daemon stale.
 * Comfortably larger than {@link MAX_SLEEP_MS} so a single missed wake never
 * trips it. Keep in sync with the threshold in `ceo doctor` (scripts/ceo).
 */
export const HEARTBEAT_STALE_MS = 600_000; // 10 minutes

// Single source of truth — cronbird/core owns the wake cap and the catch-up
// look-back bounds. The daemon uses these exact values, so the staleness
// invariant (HEARTBEAT_STALE_MS >= 5 * MAX_SLEEP_MS) is checked against them.
export { MAX_SLEEP_MS, CATCHUP_LOOKBACK_FLOOR_MS, CATCHUP_LOOKBACK_CAP_MS } from "cronbird/core";

/**
 * Optional per-host override (`CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`) that pins a
 * single fixed look-back for every playbook, bypassing the per-schedule derived
 * default. Returns the parsed value when set to a positive integer, else `null`
 * — absent, non-numeric, zero, and negative all fall through to the derived
 * look-back rather than silently installing a wrong window. The env override
 * survives from #143 as an escape hatch; the derived default is the #157 fix.
 */
export function resolveFixedLookbackMs(raw: string | undefined): number | null {
  if (raw === undefined) return null;
  const n = Number(raw.trim());
  return Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * Vault-side global settings. `cooldown_seconds` lives here rather than in the
 * registry: it is one value for the whole fleet, and `ceo-cron.sh` already reads
 * it from this file via `_cfg '.cooldown_seconds' '1800'`.
 */
export function settingsPath(vault: string): string {
  return `${vault}/CEO/settings.json`;
}

/** Must match `ceo-cron.sh`'s `_cfg '.cooldown_seconds' '1800'` default. */
export const DEFAULT_COOLDOWN_SECONDS = 1800;

/**
 * `cooldown_seconds` from CEO/settings.json. Fail-safe in the *guarding*
 * direction: an absent, torn, or malformed settings file yields the default, not
 * zero — an unreadable config must not silently disarm the runaway guard, and
 * must not throw inside a resolver the daemon calls every tick. A non-integer or
 * negative value is treated the same way, since `jq` on the shell side would
 * also have handed that through unvalidated.
 */
export function parseCooldownSeconds(raw: string): number {
  try {
    const v = (JSON.parse(raw) as { cooldown_seconds?: unknown }).cooldown_seconds;
    return typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : DEFAULT_COOLDOWN_SECONDS;
  } catch {
    return DEFAULT_COOLDOWN_SECONDS;
  }
}

/** Forward fires sampled to estimate a schedule's tightest interval. */
const CADENCE_SAMPLES = 5;

/**
 * The schedule's tightest interval in ms — the min gap over the next
 * {@link CADENCE_SAMPLES} fires, or `null` for an unparseable or single-fire
 * schedule.
 *
 * Min-of-gaps is the same cadence proxy `cronbird`'s `lookbackForSchedule` uses,
 * and for the same reason: a forward sample anchored at `now` swings with wake
 * time for an irregular schedule (fires at 09:00 and 12:00 give 3h-then-21h or
 * 21h-then-3h depending on when you ask), while the min is intrinsic to the
 * schedule. It is deliberately *unclamped* here — that function's [1h, 6h] clamp
 * bounds a catch-up window, and this feeds a rate limit, where clamping a
 * 30-minute cadence up to an hour would reintroduce the very bug below.
 */
export function cadenceMs(schedule: string, now: Date, matcher: CronMatcher): number | null {
  let cursor = now;
  let prev: Date | null = null;
  let minGap = Number.POSITIVE_INFINITY;
  for (let i = 0; i < CADENCE_SAMPLES; i++) {
    let next: Date | null;
    try {
      next = matcher.nextFire(schedule, cursor);
    } catch {
      break;
    }
    if (next === null) break;
    if (prev !== null) minGap = Math.min(minGap, next.getTime() - prev.getTime());
    prev = next;
    cursor = next;
  }
  return Number.isFinite(minGap) ? minGap : null;
}

/**
 * The cooldown cronbird enforces for one job: the global guard, capped so it can
 * never suppress a slot the schedule deliberately asks for.
 *
 * The guard is runaway protection inherited from the crontab era, when a
 * misconfigured crontab really could re-fire a playbook in a tight loop. Under
 * the daemon that job is already done by the epoch-minute double-fire guard, the
 * `MAX_CONCURRENT=1` queue, and `ceo-cron.sh`'s own lock — so the cooldown's
 * remaining value is a backstop, and it must not outrank an explicit schedule.
 *
 * Uncapped, it does. cronbird measures the cooldown from the previous run's
 * *completion*, which lands at `slot + runtime`, so a cooldown at or above the
 * cadence eats every other slot. `ticket-triage-autopilot` (a 30-minutely
 * schedule against the 1800s global) proved this in production: ~1000 lines of
 * `last run too recent (29m ago)` in cron-skips.log, i.e. a real cadence of 60
 * minutes, not 30, for as long as it was enabled.
 *
 * Halving the cadence is the cap: a run must take longer than half its own
 * period before the guard can bite, and anything slower than hourly is still
 * bound by the global 1800s. An unparseable schedule keeps the global value — it
 * never fires, so the number is moot.
 */
export function resolveCooldownSeconds(
  globalSeconds: number,
  schedule: string,
  now: Date,
  matcher: CronMatcher,
): number {
  if (globalSeconds <= 0) return 0;
  const cadence = cadenceMs(schedule, now, matcher);
  if (cadence === null) return globalSeconds;
  return Math.min(globalSeconds, Math.floor(cadence / 2000));
}

/** Host-local — the registry is now generated per host under `~/.ceo`, not synced via the vault, so concurrent hosts no longer write-conflict on it. */
export function registryPath(home: string): string {
  return `${home}/.ceo/registry.json`;
}

export function swarmPath(vault: string): string {
  return `${vault}/CEO/swarm.json`;
}

export function enabledPath(home: string): string {
  return `${home}/.ceo/enabled.json`;
}

export function heartbeatPath(home: string): string {
  return `${home}/.ceo/schedulerd/heartbeat.json`;
}

/**
 * Synced per-host liveness heartbeat in the shared vault, namespaced by host so
 * two hosts never write the same file (no Syncthing conflict). Consumed by the
 * offline-owner alert (E2): a host whose synced heartbeat goes stale is
 * presumed offline and its single-scope playbooks unowned.
 */
export function syncedHeartbeatPath(vault: string, host: string): string {
  return `${vault}/CEO/heartbeats/${host}.json`;
}

export function resolveHost(env: { CEO_HOSTNAME?: string }, osHost: string): string {
  const override = env.CEO_HOSTNAME?.trim();
  return override ? override : osHost;
}

/**
 * Argv for one scheduled dispatch. Spawned without a shell (no `bash -lc`) so
 * there is no quoting/injection surface and no profile-sourcing surprise under
 * systemd; `CEO_VAULT`/`PATH` are passed via the spawn environment instead.
 */
export function dispatchArgv(cronBin: string, name: string): string[] {
  return [cronBin, name, "--scheduled"];
}

// --- Dispatch-completion state (cronbird #9 `readCompletions` contract) --------
//
// cronbird's post-#9 loop dispatches through a queue capped at MAX_CONCURRENT
// and advances only when a job's completion is observed via `readCompletions()`.
// The daemon's `dispatch` is fire-and-forget, so without a wrapper writing run
// state the loop sees "nothing ever completes" and strands every job queued
// behind the first — silently dropping the loser of any same-minute collision
// (e.g. morning + morning-brief at 03:20). This layer is that wrapper: the
// dispatch glue in main.ts writes `running/<name>` (body: startedTs epoch-ms)
// before spawn and, on exit, `done/<name>` (body: CompletionRecord JSON) while
// clearing the running marker. `readCompletions` reassembles both dirs.
//
// One writer/reader (the daemon's single event loop) → no cross-process torn
// reads; plain writeFileSync is safe, no temp-rename needed. `done/` holds one
// file per job (overwritten each completion), so it stays bounded to the job set.

/** Root for the dispatch-completion state dirs, host-local under `~/.ceo`. */
export function runStateDir(home: string): string {
  return `${home}/.ceo/schedulerd/run-state`;
}
/** In-flight run markers: `running/<name>` body = startedTs (epoch-ms). */
export function runningDir(home: string): string {
  return `${runStateDir(home)}/running`;
}
/** Last-completion records: `done/<name>` body = CompletionRecord JSON. */
export function doneDir(home: string): string {
  return `${runStateDir(home)}/done`;
}

/**
 * A `running/<name>` marker older than this is ignored: a daemon crash mid-run
 * orphans the child (its exit handler dies with the daemon), leaving a marker
 * that would otherwise wedge the MAX_CONCURRENT=1 queue forever. Comfortably
 * longer than any real playbook run.
 */
export const RUN_STATE_STALE_MS = 3_600_000; // 1 hour

/** A parsed `running/<name>` marker: when it started, and the child PID if known. */
export interface RunningMarker {
  startedTs: number;
  /** null during the brief pre-spawn window before the PID is known. */
  pid: number | null;
}

/**
 * Serialize a running marker. Written as `startedTs` before spawn (PID unknown),
 * rewritten as `startedTs pid` once the child exists so a crashed daemon's
 * orphaned marker can be dropped by liveness rather than waiting out the stale
 * window.
 */
export function runningMarker(startedTs: number, pid?: number | null): string {
  return pid != null && pid > 0 ? `${startedTs} ${pid}` : String(startedTs);
}

/** Parse a `running/<name>` body (`startedTs` or `startedTs pid`); null on garbage/torn. */
export function parseRunningEntry(raw: string): RunningMarker | null {
  const parts = raw.trim().split(/\s+/);
  const startedTs = Number(parts[0]);
  if (!Number.isFinite(startedTs) || startedTs <= 0) return null;
  const pidNum = parts.length > 1 ? Number(parts[1]) : NaN;
  return { startedTs, pid: Number.isInteger(pidNum) && pidNum > 0 ? pidNum : null };
}

/**
 * A job name is used directly as a run-state filename, so it must be a single
 * safe path segment — no `/`, no `.`/`..`. Live registry names are kebab slugs;
 * this guards the path-escape surface if a future name isn't.
 */
export function isSafeSegment(name: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(name) && name !== "." && name !== "..";
}

/** Parse+validate a `done/<name>` body (CompletionRecord JSON); null on garbage/torn. */
export function parseDoneEntry(raw: string): CompletionRecord | null {
  try {
    const v = JSON.parse(raw) as Partial<CompletionRecord>;
    if (
      typeof v?.ts === "number" &&
      typeof v?.exitCode === "number" &&
      typeof v?.durationMs === "number"
    ) {
      return { ts: v.ts, exitCode: v.exitCode, durationMs: v.durationMs };
    }
  } catch {
    // torn/partial write — treat as absent, matching cronbird's fail-safe read contract
  }
  return null;
}

/** True when an in-flight marker is old enough to be a crash orphan, not a live run. */
export function isStaleRunning(startedTs: number, now: number, staleMs = RUN_STATE_STALE_MS): boolean {
  return now - startedTs > staleMs;
}

/** Build the CompletionRecord written to `done/<name>` when a dispatched run exits. */
export function completionRecord(startedTs: number, endedTs: number, exitCode: number): CompletionRecord {
  return { ts: endedTs, exitCode, durationMs: Math.max(0, endedTs - startedTs) };
}

/**
 * Reassemble the `readCompletions()` shape from raw dir contents (name → file
 * body). Pure so the stale-filter and torn-read handling are unit-tested without
 * fs; main.ts reads the dirs and passes the maps in. Stale/garbage running
 * markers and unparseable done records are dropped (fail-safe: an unreadable
 * entry means "not running" / "no completion", never a wrong gate).
 */
export function buildCompletions(
  runningRaw: Record<string, string>,
  doneRaw: Record<string, string>,
  now: number,
  opts: { staleMs?: number; isAlive?: (pid: number) => boolean } = {},
): { running: Record<string, number>; done: Record<string, CompletionRecord> } {
  const staleMs = opts.staleMs ?? RUN_STATE_STALE_MS;
  const isAlive = opts.isAlive;
  const running: Record<string, number> = {};
  for (const [name, raw] of Object.entries(runningRaw)) {
    const m = parseRunningEntry(raw);
    if (m === null) continue;
    // With a known PID and a liveness probe: a live child is genuinely in-flight
    // (keep it, even past the stale window — respects MAX_CONCURRENT=1 for a long
    // job); a dead PID is a crash orphan, dropped immediately (no 1h stall).
    if (m.pid !== null && isAlive) {
      if (isAlive(m.pid)) running[name] = m.startedTs;
      continue;
    }
    // No PID yet (pre-spawn window) or no probe → fall back to the time guard.
    if (!isStaleRunning(m.startedTs, now, staleMs)) running[name] = m.startedTs;
  }
  const done: Record<string, CompletionRecord> = {};
  for (const [name, raw] of Object.entries(doneRaw)) {
    const rec = parseDoneEntry(raw);
    if (rec !== null) done[name] = rec;
  }
  return { running, done };
}
