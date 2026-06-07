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
  shouldContinue(): boolean;
}

function epochMinute(when: Date): number {
  return Math.floor(when.getTime() / MINUTE_MS);
}

export async function runForever(deps: DaemonDeps): Promise<void> {
  const prior = deps.readHeartbeat();
  const guard = new Map<string, number>(prior ? Object.entries(prior.dispatched_minute) : []);
  const recent: DispatchRecord[] = prior ? [...prior.last_dispatch] : [];
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

    const runnable = selectRunnable(playbooks, deps.host);
    const toDispatch = dueAt(runnable, now, deps.matcher).filter((p) => guard.get(p.name) !== minute);
    for (const p of toDispatch) {
      guard.set(p.name, minute);
      recent.push({ name: p.name, ts: now.getTime() });
    }
    if (recent.length > MAX_RECENT_DISPATCH) recent.splice(0, recent.length - MAX_RECENT_DISPATCH);

    // Drop guard entries older than the previous minute — only the current
    // minute (and a same-minute restart) can produce a double-fire.
    for (const [name, mn] of guard) if (mn < minute - 1) guard.delete(name);

    const wake = nextWake(runnable, now, deps.matcher, deps.maxSleepMs);
    // Persist the guard BEFORE firing. A crash between here and the spawn must
    // not re-fire on restart, so dispatch is at-most-once: a crash drops a fire
    // rather than doubling it (the safer direction for write-tier playbooks).
    deps.writeHeartbeat({
      ts: now.getTime(),
      host: deps.host,
      runnable_count: runnable.length,
      next_wake_ts: now.getTime() + wake,
      last_dispatch: [...recent],
      dispatched_minute: Object.fromEntries(guard),
    });
    for (const p of toDispatch) deps.dispatch(p.name);

    await deps.sleep(wake);
  }
}
