import { describe, expect, test } from "bun:test";
import type { Heartbeat } from "cronbird/core";
import { resolveAdapterConfig, SchedulerDispatchContext } from "../src/main";

function heartbeat(attempts: Record<string, number>): Heartbeat {
  return {
    ts: 1,
    host: "ml-1",
    runnable_count: 0,
    next_wake_ts: 2,
    last_dispatch: [],
    dispatched_minute: {},
    last_fired: {},
    queue: [],
    running: {},
    last_completed: {},
    attempts,
    last_run: {},
    last_success: {},
  };
}

describe("CEO adapter round-trip (byte-identical to pre-extraction)", () => {
  const env = { CEO_VAULT: "/vault", HOME: "/home/u", CEO_HOSTNAME: "ml-1", CEO_CRON_BIN: "ceo-cron.sh" };
  test("resolves the exact pre-extraction paths, argv, host, and label", () => {
    const c = resolveAdapterConfig(env);
    expect(c.registryPath).toBe("/home/u/.ceo/registry.json");
    expect(c.heartbeatPath).toBe("/home/u/.ceo/schedulerd/heartbeat.json");
    expect(c.swarmPath).toBe("/vault/CEO/swarm.json");
    expect(c.syncedHeartbeatPath).toBe("/vault/CEO/heartbeats/ml-1.json");
    expect(c.dispatchArgv("morning-scan")).toEqual(["ceo-cron.sh", "morning-scan", "--scheduled"]);
    expect(c.host).toBe("ml-1");
    expect(c.launchdLabel).toBe("com.ceo.schedulerd");
  });
  test("hostname falls back to short os hostname when CEO_HOSTNAME is unset", () => {
    const c = resolveAdapterConfig({ CEO_VAULT: "/v", HOME: "/h" });
    expect(c.host.length).toBeGreaterThan(0);
    expect(c.host).not.toContain(".");
  });
});

describe("NoRx retry metadata dispatch context", () => {
  const inheritedEnv = {
    PATH: "/bin",
    CEO_SCHEDULER_ATTEMPT: "stale",
    CEO_SCHEDULER_MAX_ATTEMPTS: "stale",
  };

  test.each([
    [0, "1"],
    [1, "2"],
    [2, "3"],
  ])("injects persisted attempt %i as dispatched attempt %s", (persistedAttempt, dispatchedAttempt) => {
    const context = new SchedulerDispatchContext();
    context.retain(heartbeat({ "norx-bookkeeping": persistedAttempt }));

    expect(context.envFor("norx-bookkeeping", inheritedEnv)).toMatchObject({
      CEO_SCHEDULER_ATTEMPT: dispatchedAttempt,
      CEO_SCHEDULER_MAX_ATTEMPTS: "3",
    });
  });

  test("uses the most recently persisted reset counter", () => {
    const context = new SchedulerDispatchContext();
    context.retain(heartbeat({ "norx-bookkeeping": 2 }));
    context.retain(heartbeat({ "norx-bookkeeping": 0 }));

    expect(context.envFor("norx-bookkeeping", inheritedEnv)?.CEO_SCHEDULER_ATTEMPT).toBe("1");
  });

  test("retains a heartbeat only after its persistence succeeds", () => {
    const context = new SchedulerDispatchContext();
    context.persist(heartbeat({ "norx-bookkeeping": 0 }), () => {});

    expect(() => context.persist(heartbeat({ "norx-bookkeeping": 2 }), () => {
      throw new Error("write failed");
    })).toThrow("write failed");
    expect(context.envFor("norx-bookkeeping", inheritedEnv)?.CEO_SCHEDULER_ATTEMPT).toBe("1");
  });

  test("does not pass scheduler retry metadata to other playbooks", () => {
    const context = new SchedulerDispatchContext();
    context.retain(heartbeat({ "norx-bookkeeping": 2 }));

    expect(context.envFor("morning-scan", inheritedEnv)).toEqual({ PATH: "/bin" });
  });

  test.each([undefined, -1, 1.5, 3, Number.NaN])("refuses missing or invalid persisted attempts: %p", (attempt) => {
    const context = new SchedulerDispatchContext();
    const attempts: Record<string, number> = attempt === undefined ? {} : { "norx-bookkeeping": attempt };
    context.retain(heartbeat(attempts));

    expect(context.envFor("norx-bookkeeping", inheritedEnv)).toBeNull();
  });

  test("refuses NoRx dispatch before a heartbeat has successfully been retained", () => {
    const context = new SchedulerDispatchContext();

    expect(context.envFor("norx-bookkeeping", inheritedEnv)).toBeNull();
  });
});
