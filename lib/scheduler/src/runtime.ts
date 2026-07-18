/**
 * Real-environment helpers for ceo-schedulerd, kept pure so they are unit-tested
 * without touching the filesystem. `main.ts` composes them with Bun's spawn/fs.
 */
import type { CompletionRecord } from "cronbird/core";

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

/** Parse a `running/<name>` body (epoch-ms startedTs); null on garbage/torn. */
export function parseRunningEntry(raw: string): number | null {
  const n = Number(raw.trim());
  return Number.isFinite(n) && n > 0 ? n : null;
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
  staleMs = RUN_STATE_STALE_MS,
): { running: Record<string, number>; done: Record<string, CompletionRecord> } {
  const running: Record<string, number> = {};
  for (const [name, raw] of Object.entries(runningRaw)) {
    const ts = parseRunningEntry(raw);
    if (ts !== null && !isStaleRunning(ts, now, staleMs)) running[name] = ts;
  }
  const done: Record<string, CompletionRecord> = {};
  for (const [name, raw] of Object.entries(doneRaw)) {
    const rec = parseDoneEntry(raw);
    if (rec !== null) done[name] = rec;
  }
  return { running, done };
}
