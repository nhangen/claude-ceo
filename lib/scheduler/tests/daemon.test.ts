import { describe, expect, test } from "bun:test";
import { lookbackForSchedule } from "@/catchup";
import { createMatcher } from "@/cron";
import type { Playbook } from "@/registry";
import { type DaemonDeps, type Heartbeat, runForever } from "@/daemon";
import type { Swarm } from "@/swarm";
import { CATCHUP_LOOKBACK_CAP_MS, CATCHUP_LOOKBACK_FLOOR_MS } from "@/runtime";

const m = createMatcher({ timezone: "UTC" });
const d = (iso: string) => new Date(iso);

const pb = (over: Partial<Playbook>): Playbook => ({
  name: "p",
  schedule: "0 9 * * *",
  status: "active",
  trigger: "cron",
  hosts: ["*"],
  scope: "each",
  ...over,
});

interface HarnessOpts {
  nows: Date[];
  playbooks: Playbook[] | (() => { playbooks: Playbook[]; warnings: string[] });
  startHeartbeat?: Heartbeat | null;
  host?: string;
  cap?: number;
  /** Pin a fixed look-back for all schedules (the env-override path). Omit to use the production-default derived resolver. */
  lookback?: number;
  /**
   * Per-tick swarm reads (mirrors `loadSwarm`). `null` simulates a torn read.
   * Default: a single static swarm with the given `owners`, returned every tick.
   */
  swarms?: (Swarm | null)[];
  /** Owners for the default static swarm (when `swarms` is not supplied). */
  owners?: Record<string, string>;
  /**
   * Per-tick enabled reads (mirrors `loadEnabled`). When supplied, REPLACES the
   * default accumulate-every-loaded-name behavior. A `null` entry simulates a
   * torn read → empty set that tick.
   */
  enabledByTick?: (Set<string> | null)[];
}

function harness(opts: HarnessOpts) {
  let i = 0;
  const dispatched: string[] = [];
  const sleeps: number[] = [];
  const heartbeats: Heartbeat[] = [];
  const logs: string[] = [];
  let lastHb: Heartbeat | null = null;
  // For each dispatch, the guard minute already persisted to the heartbeat at
  // the moment dispatch is called. undefined ⇒ the guard was NOT yet durable
  // (ordering bug: a crash here would re-fire on restart).
  const guardAtDispatch: Record<string, number | undefined> = {};
  // Same idea for last_fired: the value already persisted to the heartbeat when
  // dispatch is called. Proves catch-up keeps at-most-once even if the two
  // fields are ever split into separate heartbeat writes.
  const lastFiredAtDispatch: Record<string, number | undefined> = {};
  const rawLoader =
    typeof opts.playbooks === "function"
      ? opts.playbooks
      : () => ({ playbooks: opts.playbooks as Playbook[], warnings: [] });
  // B3 made selection scope-aware; the legacy dispatch tests predate per-host
  // enablement and assert each-scope playbooks dispatch. Default behavior:
  // accumulate every loaded name into `enabled` as the loop loads — wrapping
  // (not pre-calling) the loader so its call counter / throw-on-Nth-call
  // behavior is preserved. The accumulated set is returned each tick by
  // `loadEnabled` unless a per-tick `enabledByTick` override is supplied.
  const enabled = new Set<string>();
  const loader = () => {
    const loaded = rawLoader();
    for (const p of loaded.playbooks) enabled.add(p.name);
    return loaded;
  };
  let enabledTick = 0;
  const loadEnabled = (): Set<string> => {
    if (opts.enabledByTick) {
      return opts.enabledByTick[enabledTick++] ?? new Set<string>();
    }
    return new Set(enabled);
  };
  let swarmTick = 0;
  const defaultSwarm: Swarm = { hosts: [], owners: opts.owners ?? {} };
  const loadSwarm = (): Swarm | null => {
    if (opts.swarms) {
      return opts.swarms[swarmTick++] ?? null;
    }
    return defaultSwarm;
  };

  const deps: DaemonDeps = {
    now: () => opts.nows[i++]!,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    loadRegistry: loader,
    loadEnabled,
    loadSwarm,
    dispatch: (name) => {
      guardAtDispatch[name] = lastHb?.dispatched_minute[name];
      lastFiredAtDispatch[name] = lastHb?.last_fired[name];
      dispatched.push(name);
    },
    readHeartbeat: () => opts.startHeartbeat ?? null,
    writeHeartbeat: (hb) => {
      heartbeats.push(hb);
      lastHb = hb;
    },
    log: (msg) => {
      logs.push(msg);
    },
    host: opts.host ?? "ml-1",
    matcher: m,
    maxSleepMs: opts.cap ?? 60_000,
    resolveLookback:
      opts.lookback !== undefined
        ? () => opts.lookback as number
        : (schedule, now) => lookbackForSchedule(schedule, now, m, CATCHUP_LOOKBACK_FLOOR_MS, CATCHUP_LOOKBACK_CAP_MS),
    shouldContinue: () => i < opts.nows.length,
  };
  return {
    deps,
    dispatched,
    sleeps,
    heartbeats,
    logs,
    guardAtDispatch: () => guardAtDispatch,
    lastFiredAtDispatch: () => lastFiredAtDispatch,
  };
}

describe("runForever — dispatch + sleep", () => {
  test("dispatches every due playbook once per tick and sleeps the computed wake", async () => {
    const h = harness({
      nows: [d("2026-06-01T09:00:00Z")],
      playbooks: [pb({ name: "nine", schedule: "0 9 * * *" }), pb({ name: "ten", schedule: "0 10 * * *" })],
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["nine"]);
    // next fire after 09:00 is "nine" at 09:00 tomorrow vs "ten" at 10:00 today → 10:00 today (3600s), capped.
    expect(h.sleeps).toEqual([60_000]);
  });

  test("a mid-minute tick still fires that minute's due set (H2 minute granularity)", async () => {
    const h = harness({ nows: [d("2026-06-01T09:00:43Z")], playbooks: [pb({ name: "nine", schedule: "0 9 * * *" })] });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["nine"]);
  });

  test("writes a liveness heartbeat every tick even when nothing is due", async () => {
    const h = harness({ nows: [d("2026-06-01T09:30:00Z")], playbooks: [pb({ schedule: "0 9 * * *" })] });
    await runForever(h.deps);
    expect(h.dispatched).toEqual([]);
    expect(h.heartbeats).toHaveLength(1);
    expect(h.heartbeats[0]!.runnable_count).toBe(1);
    expect(h.heartbeats[0]!.ts).toBe(d("2026-06-01T09:30:00Z").getTime());
    expect(h.heartbeats[0]!.next_wake_ts).toBe(d("2026-06-01T09:30:00Z").getTime() + 60_000);
  });
});

describe("double-fire guard", () => {
  test("does not re-dispatch the same playbook twice within one minute", async () => {
    // Two ticks 20s apart, both inside the 09:00 minute, every-minute schedule.
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:00:25Z")],
      playbooks: [pb({ name: "ev", schedule: "* * * * *" })],
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev"]);
  });

  test("fires again in the next minute", async () => {
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:01:05Z")],
      playbooks: [pb({ name: "ev", schedule: "* * * * *" })],
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev", "ev"]);
  });

  test("durable guard: a restart inside the same fire-minute does not re-dispatch (H1)", async () => {
    const minute = Math.floor(d("2026-06-01T09:00:00Z").getTime() / 60_000);
    const h = harness({
      nows: [d("2026-06-01T09:00:30Z")],
      playbooks: [pb({ name: "ev", schedule: "* * * * *" })],
      startHeartbeat: {
        ts: d("2026-06-01T09:00:02Z").getTime(),
        host: "ml-1",
        runnable_count: 1,
        next_wake_ts: 0,
        last_dispatch: [{ name: "ev", ts: d("2026-06-01T09:00:02Z").getTime() }],
        dispatched_minute: { ev: minute },
        last_fired: {},
      },
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual([]);
  });

  test("persists the guard to the heartbeat BEFORE dispatching (no crash-window double-fire)", async () => {
    const minute = Math.floor(d("2026-06-01T09:00:00Z").getTime() / 60_000);
    const h = harness({ nows: [d("2026-06-01T09:00:05Z")], playbooks: [pb({ name: "ev", schedule: "* * * * *" })] });
    await runForever(h.deps);
    // If the heartbeat were written after dispatch, this would be undefined.
    expect(h.guardAtDispatch().ev).toBe(minute);
  });

  test("the heartbeat carries the dispatched-minute guard forward", async () => {
    const minute = Math.floor(d("2026-06-01T09:00:00Z").getTime() / 60_000);
    const h = harness({ nows: [d("2026-06-01T09:00:05Z")], playbooks: [pb({ name: "ev", schedule: "* * * * *" })] });
    await runForever(h.deps);
    expect(h.heartbeats[0]!.dispatched_minute.ev).toBe(minute);
    expect(h.heartbeats[0]!.last_dispatch.map((x) => x.name)).toEqual(["ev"]);
  });
});

describe("registry resilience", () => {
  test("a load failure keeps the last-good registry and logs, without crashing the loop", async () => {
    let call = 0;
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:01:05Z")],
      playbooks: () => {
        call++;
        if (call === 2) throw new Error("invalid registry: boom");
        return { playbooks: [pb({ name: "ev", schedule: "* * * * *" })], warnings: [] };
      },
    });
    await runForever(h.deps);
    // Tick 1 loads ev and dispatches; tick 2's load throws → reuse ev → dispatch again (new minute).
    expect(h.dispatched).toEqual(["ev", "ev"]);
    expect(h.logs.some((l) => l.includes("boom"))).toBe(true);
  });
});

describe("missed-slot catch-up (#143)", () => {
  const hbWith = (lastFired: Record<string, number>): Heartbeat => ({
    ts: 0,
    host: "ml-1",
    runnable_count: 0,
    next_wake_ts: 0,
    last_dispatch: [],
    dispatched_minute: {},
    last_fired: lastFired,
  });

  test("fires once for the newest missed slot after a downtime gap and advances last_fired", async () => {
    // Restored last_fired = 09:00; back at 09:17:30; */5 → 09:05/09:10/09:15 missed; fire 09:15 once.
    const h = harness({
      nows: [d("2026-06-01T09:17:30Z")],
      playbooks: [pb({ name: "ev", schedule: "*/5 * * * *" })],
      startHeartbeat: hbWith({ ev: d("2026-06-01T09:00:00Z").getTime() }),
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev"]);
    expect(h.heartbeats[0]!.last_fired.ev).toBe(d("2026-06-01T09:15:00Z").getTime());
  });

  test("a playbook due now AND owing a missed slot fires once (not twice)", async () => {
    // every minute, last_fired 09:00, now exactly on the 09:05 fire.
    const minuteStart = Math.floor(d("2026-06-01T09:05:00Z").getTime() / 60_000) * 60_000;
    const h = harness({
      nows: [d("2026-06-01T09:05:00Z")],
      playbooks: [pb({ name: "ev", schedule: "* * * * *" })],
      startHeartbeat: hbWith({ ev: d("2026-06-01T09:00:00Z").getTime() }),
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev"]);
    expect(h.heartbeats[0]!.last_fired.ev).toBe(minuteStart);
  });

  test("a first-seen playbook (no baseline) gets no catch-up; last_fired initializes to now", async () => {
    const now = d("2026-06-01T09:30:00Z");
    const h = harness({
      nows: [now],
      playbooks: [pb({ name: "ev", schedule: "*/5 * * * *" })], // 09:30 is a fire, but no prior baseline
      startHeartbeat: null,
    });
    await runForever(h.deps);
    // It IS due at 09:30 (live path), so it fires once for the current minute — but NOT a catch-up replay.
    expect(h.dispatched).toEqual(["ev"]);
    expect(h.heartbeats[0]!.last_fired.ev).toBe(now.getTime());
  });

  test("no catch-up replay for a brand-new, not-currently-due playbook", async () => {
    const now = d("2026-06-01T09:32:00Z"); // not a */5 fire
    const h = harness({
      nows: [now],
      playbooks: [pb({ name: "ev", schedule: "*/5 * * * *" })],
      startHeartbeat: null,
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual([]);
    expect(h.heartbeats[0]!.last_fired.ev).toBe(now.getTime());
  });

  test("a slot too stale for the derived look-back window is not replayed", async () => {
    // daily 09:00 derives a 6h look-back; back at 16:00 (7h after 09:00) → too stale → no replay.
    const h = harness({
      nows: [d("2026-06-01T16:00:00Z")],
      playbooks: [pb({ name: "daily", schedule: "0 9 * * *" })],
      startHeartbeat: hbWith({ daily: d("2026-05-31T09:00:00Z").getTime() }),
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual([]);
  });

  test("derived look-back (#157): a daily slot 3h stale catches up where the old global 1h would have skipped it", async () => {
    // daily 09:00, down since yesterday, back at 12:00 (3h after the 09:00 slot).
    // The derived daily look-back is 6h, so 09:00 today is within window → replay once.
    const h = harness({
      nows: [d("2026-06-01T12:00:00Z")],
      playbooks: [pb({ name: "daily", schedule: "0 9 * * *" })],
      startHeartbeat: hbWith({ daily: d("2026-05-31T09:00:00Z").getTime() }),
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["daily"]);
    expect(h.heartbeats[0]!.last_fired.daily).toBe(d("2026-06-01T09:00:00Z").getTime());

    // Same scenario, but the host pins a fixed 1h window (env override) → too stale → skipped.
    const fixed = harness({
      nows: [d("2026-06-01T12:00:00Z")],
      playbooks: [pb({ name: "daily", schedule: "0 9 * * *" })],
      startHeartbeat: hbWith({ daily: d("2026-05-31T09:00:00Z").getTime() }),
      lookback: 3_600_000,
    });
    await runForever(fixed.deps);
    expect(fixed.dispatched).toEqual([]);
  });

  test("advances last_fired to the missed slot and persists it BEFORE dispatch (at-most-once)", async () => {
    const h = harness({
      nows: [d("2026-06-01T09:17:30Z")],
      playbooks: [pb({ name: "ev", schedule: "*/5 * * * *" })],
      startHeartbeat: hbWith({ ev: d("2026-06-01T09:00:00Z").getTime() }),
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev"]);
    // Real ordering assertion: at the moment dispatch was called, the advanced
    // last_fired was ALREADY in the persisted heartbeat. Fails if writeHeartbeat
    // moves after dispatch (even if last_fired ends up correct).
    expect(h.lastFiredAtDispatch().ev).toBe(d("2026-06-01T09:15:00Z").getTime());
  });

  test("prunes last_fired for playbooks no longer runnable", async () => {
    const h = harness({
      nows: [d("2026-06-01T09:30:00Z")],
      playbooks: [pb({ name: "stillhere", schedule: "0 9 * * *" })],
      startHeartbeat: hbWith({ stillhere: d("2026-06-01T09:00:00Z").getTime(), gone: 123 }),
    });
    await runForever(h.deps);
    expect(Object.keys(h.heartbeats[0]!.last_fired)).toEqual(["stillhere"]);
  });
});

describe("scope gating wired from loaders (B4)", () => {
  test("dispatches enabled each-scope playbooks and single-scope playbooks owned by this host", async () => {
    const h = harness({
      nows: [d("2026-06-01T09:00:00Z")],
      host: "ml-1",
      playbooks: [
        pb({ name: "each-on", schedule: "0 9 * * *", scope: "each" }),
        pb({ name: "single-mine", schedule: "0 9 * * *", scope: "single" }),
        pb({ name: "single-theirs", schedule: "0 9 * * *", scope: "single" }),
      ],
      enabledByTick: [new Set(["each-on"])],
      owners: { "single-mine": "ml-1", "single-theirs": "mac" },
    });
    await runForever(h.deps);
    expect(h.dispatched.sort()).toEqual(["each-on", "single-mine"]);
  });

  test("last-good swarm: a torn swarm read keeps the prior tick's owners so an owned single-scope playbook still fires", async () => {
    // Tick 1: swarm names ml-1 as owner → single-scope fires. Tick 2 (next
    // minute): swarm read is torn (null) → owners reused from tick 1 → it still
    // fires. Without last-good, owners would empty and the playbook be dropped.
    const swarm: Swarm = { hosts: ["ml-1"], owners: { mine: "ml-1" } };
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:01:05Z")],
      host: "ml-1",
      playbooks: [pb({ name: "mine", schedule: "* * * * *", scope: "single" })],
      enabledByTick: [new Set<string>(), new Set<string>()],
      swarms: [swarm, null],
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["mine", "mine"]);
  });

  test("a fresh good swarm read overwrites last-good owners (reassignment is not stuck)", async () => {
    // Tick 1: ml-1 owns `mine` → fires here. Tick 2: a fresh good read reassigns
    // ownership to mac → ml-1 must DROP it. If last-good owners were only ever
    // set (never overwritten), ml-1 would keep firing — a stuck-owners bug.
    const tick1: Swarm = { hosts: ["ml-1", "mac"], owners: { mine: "ml-1" } };
    const tick2: Swarm = { hosts: ["ml-1", "mac"], owners: { mine: "mac" } };
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:01:05Z")],
      host: "ml-1",
      playbooks: [pb({ name: "mine", schedule: "* * * * *", scope: "single" })],
      enabledByTick: [new Set<string>(), new Set<string>()],
      swarms: [tick1, tick2],
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["mine"]);
  });

  test("torn enabled read (empty set) disables each-scope dispatch that tick, safe and without crashing", async () => {
    // Tick 1 enabled has the playbook → fires. Tick 2 (next minute) torn read
    // (null → empty set) → not enabled → does NOT fire. No last-good for enabled.
    const h = harness({
      nows: [d("2026-06-01T09:00:05Z"), d("2026-06-01T09:01:05Z")],
      playbooks: [pb({ name: "ev", schedule: "* * * * *", scope: "each" })],
      enabledByTick: [new Set(["ev"]), null],
      owners: {},
    });
    await runForever(h.deps);
    expect(h.dispatched).toEqual(["ev"]);
  });
});
