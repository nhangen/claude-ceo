/**
 * The ceo-schedulerd control loop (#136 Phase 1.5, issue #142).
 *
 * Every tick: re-read the registry, pick the playbooks this host runs now, fire
 * each due one via the injected `dispatch` (a non-blocking spawn of
 * `ceo-cron.sh <name> --scheduled`), write a liveness heartbeat, then sleep
 * until the soonest next fire (capped so the loop re-reads the registry and
 * self-heals clock skew).
 *
 * All side effects are injected via {@link DaemonDeps} so the loop is tested
 * with a fake clock and recorders — no real sleeping or spawning. The
 * double-fire guard is persisted in the heartbeat and restored at startup so a
 * `Restart=always` crash inside a fire-minute does not re-run a playbook.
 */
import { catchUpFires } from "@/catchup";
import type { CronMatcher } from "@/cron";
import { dueAt, nextWake, selectRunnable } from "@/select";
import type { Playbook } from "@/registry";

const MINUTE_MS = 60_000;
/** How many recent dispatches to retain in the heartbeat for observability. */
const MAX_RECENT_DISPATCH = 20;

export interface DispatchRecord {
  name: string;
  ts: number;
}

export interface Heartbeat {
  ts: number;
  host: string;
  runnable_count: number;
  next_wake_ts: number;
  last_dispatch: DispatchRecord[];
  /** playbook name → epoch-minute it was last dispatched (the durable double-fire guard). */
  dispatched_minute: Record<string, number>;
  /** playbook name → epoch-ms of the newest slot fired (drives missed-slot catch-up, #143). */
  last_fired: Record<string, number>;
}

export interface DaemonDeps {
  now(): Date;
  sleep(ms: number): Promise<void>;
  loadRegistry(): { playbooks: Playbook[]; warnings: string[] };
  /** Fire-and-forget spawn of the dispatch command; must not block the loop. */
  dispatch(name: string): void;
  /** Prior heartbeat (if any) used to restore the guard across restarts. */
  readHeartbeat(): Heartbeat | null;
  writeHeartbeat(hb: Heartbeat): void;
  log(msg: string): void;
  host: string;
  matcher: CronMatcher;
  maxSleepMs: number;
  /**
   * Catch-up look-back resolver (#157): given a playbook's schedule and the
   * current `now`, returns how far back a missed slot may be and still replay.
   * Production passes a per-schedule derived resolver (or a fixed window when
   * the host pins `CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`).
   */
  resolveLookback(schedule: string, now: Date): number;
  shouldContinue(): boolean;
  /**
   * Scope gating for {@link selectRunnable}: the each-scope playbooks enabled on
   * this host, and the name→owner map for single-scope playbooks. Optional only
   * as a B3→B4 stopgap — production currently leaves both unset, so the daemon is
   * a safe no-op (selects nothing). B4 wires `enabled.json` + `swarm.json` and
   * should make these required.
   */
  enabled?: Set<string>;
  owners?: Record<string, string>;
}

function epochMinute(when: Date): number {
  return Math.floor(when.getTime() / MINUTE_MS);
}

export async function runForever(deps: DaemonDeps): Promise<void> {
  const prior = deps.readHeartbeat();
  const guard = new Map<string, number>(prior ? Object.entries(prior.dispatched_minute) : []);
  const recent: DispatchRecord[] = prior ? [...prior.last_dispatch] : [];
  let lastFired: Record<string, number> = prior ? { ...prior.last_fired } : {};
  let lastGood: Playbook[] = [];

  while (deps.shouldContinue()) {
    const now = deps.now();
    const minute = epochMinute(now);

    let playbooks = lastGood;
    try {
      const loaded = deps.loadRegistry();
      playbooks = loaded.playbooks;
      lastGood = playbooks;
      for (const w of loaded.warnings) deps.log(`registry: ${w}`);
    } catch (err) {
      deps.log(`registry load failed, reusing last-good: ${err instanceof Error ? err.message : String(err)}`);
    }

    // TODO(B4): load enabled.json (each-scope enablement) + swarm.json owners
    // in main.ts and make these DaemonDeps fields required. Until then an
    // unwired production daemon selects nothing for each-scope and nothing for
    // unowned single-scope — a safe no-op.
    const runnable = selectRunnable(playbooks, deps.host, deps.enabled ?? new Set<string>(), deps.owners ?? {});
    const minuteStart = minute * MINUTE_MS;

    // Current-minute fires (live path), then catch-up fires for slots missed
    // while the daemon was down. The dueNames filter is defensive: catch-up only
    // returns slots strictly before the current minute, so it can't already
    // overlap `due` today — but it keeps a single tick from double-dispatching a
    // playbook if that exclusion ever changes.
    const due = dueAt(runnable, now, deps.matcher).filter((p) => guard.get(p.name) !== minute);
    const dueNames = new Set(due.map((p) => p.name));
    const catches = catchUpFires(runnable, lastFired, now, deps.matcher, (s) => deps.resolveLookback(s, now)).filter(
      (f) => !dueNames.has(f.playbook.name),
    );

    // Rebuild last_fired keyed by the current runnable set, which prunes removed
    // playbooks. A first-seen playbook (or one that briefly left the runnable set
    // — draft/host-scope flip) has no baseline and initializes to now, so it is
    // treated as first-seen and never replayed: at-most-once over double-fire.
    const nextLastFired: Record<string, number> = {};
    for (const p of runnable) nextLastFired[p.name] = lastFired[p.name] ?? now.getTime();
    for (const p of due) {
      guard.set(p.name, minute);
      nextLastFired[p.name] = minuteStart;
      recent.push({ name: p.name, ts: now.getTime() });
    }
    for (const f of catches) {
      nextLastFired[f.playbook.name] = Math.max(nextLastFired[f.playbook.name] ?? 0, f.slot.getTime());
      recent.push({ name: f.playbook.name, ts: now.getTime() });
    }
    lastFired = nextLastFired;
    if (recent.length > MAX_RECENT_DISPATCH) recent.splice(0, recent.length - MAX_RECENT_DISPATCH);

    // Drop guard entries older than the previous minute — only the current
    // minute (and a same-minute restart) can produce a double-fire.
    for (const [name, mn] of guard) if (mn < minute - 1) guard.delete(name);

    const wake = nextWake(runnable, now, deps.matcher, deps.maxSleepMs);
    // Persist the guard and last_fired BEFORE firing. A crash between here and
    // the spawn must not re-fire on restart, so dispatch is at-most-once: a
    // crash drops a fire rather than doubling it (safer for write-tier
    // playbooks). NB this diverges from #143's "persist after dispatch confirms"
    // wording in favour of #142's panel-approved at-most-once invariant.
    deps.writeHeartbeat({
      ts: now.getTime(),
      host: deps.host,
      runnable_count: runnable.length,
      next_wake_ts: now.getTime() + wake,
      last_dispatch: [...recent],
      dispatched_minute: Object.fromEntries(guard),
      last_fired: lastFired,
    });
    for (const p of due) deps.dispatch(p.name);
    for (const f of catches) deps.dispatch(f.playbook.name);

    await deps.sleep(wake);
  }
}
