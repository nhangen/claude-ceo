import { describe, expect, test } from "bun:test";
import { createMatcher } from "@/cron";
import type { Playbook } from "@/registry";
import { type DaemonDeps, type Heartbeat, runForever } from "@/daemon";

const m = createMatcher({ timezone: "UTC" });
const d = (iso: string) => new Date(iso);

const pb = (over: Partial<Playbook>): Playbook => ({
  name: "p",
  schedule: "0 9 * * *",
  status: "active",
  trigger: "cron",
  hosts: ["*"],
  ...over,
});

interface HarnessOpts {
  nows: Date[];
  playbooks: Playbook[] | (() => { playbooks: Playbook[]; warnings: string[] });
  startHeartbeat?: Heartbeat | null;
  host?: string;
  cap?: number;
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
  const loader =
    typeof opts.playbooks === "function"
      ? opts.playbooks
      : () => ({ playbooks: opts.playbooks as Playbook[], warnings: [] });

  const deps: DaemonDeps = {
    now: () => opts.nows[i++]!,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    loadRegistry: loader,
    dispatch: (name) => {
      guardAtDispatch[name] = lastHb?.dispatched_minute[name];
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
    shouldContinue: () => i < opts.nows.length,
  };
  return { deps, dispatched, sleeps, heartbeats, logs, guardAtDispatch: () => guardAtDispatch };
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
