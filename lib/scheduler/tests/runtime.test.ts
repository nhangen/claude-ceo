import { describe, expect, test } from "bun:test";
import {
  buildCompletions,
  CATCHUP_LOOKBACK_CAP_MS,
  CATCHUP_LOOKBACK_FLOOR_MS,
  completionRecord,
  dispatchArgv,
  doneDir,
  enabledPath,
  HEARTBEAT_STALE_MS,
  heartbeatPath,
  isStaleRunning,
  MAX_SLEEP_MS,
  parseDoneEntry,
  parseRunningEntry,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
  RUN_STATE_STALE_MS,
  runningDir,
  runStateDir,
  swarmPath,
  syncedHeartbeatPath,
} from "@/runtime";

describe("path resolution", () => {
  test("registryPath is host-local under ~/.ceo, not the synced vault", () => {
    expect(registryPath("/home/me")).toBe("/home/me/.ceo/registry.json");
  });

  test("swarmPath is in the synced vault", () => {
    expect(swarmPath("/vault")).toBe("/vault/CEO/swarm.json");
  });

  test("enabledPath is host-local", () => {
    expect(enabledPath("/home/me")).toBe("/home/me/.ceo/enabled.json");
  });

  test("heartbeat is host-local under ~/.ceo, never the synced vault", () => {
    expect(heartbeatPath("/home/nhang")).toBe("/home/nhang/.ceo/schedulerd/heartbeat.json");
  });

  test("syncedHeartbeatPath is in the synced vault, namespaced by host", () => {
    expect(syncedHeartbeatPath("/vault", "ml-1")).toBe("/vault/CEO/heartbeats/ml-1.json");
  });
});

describe("resolveHost", () => {
  test("CEO_HOSTNAME overrides the OS hostname", () => {
    expect(resolveHost({ CEO_HOSTNAME: "ml-1" }, "macbook")).toBe("ml-1");
  });
  test("blank or absent CEO_HOSTNAME falls back to the OS hostname", () => {
    expect(resolveHost({ CEO_HOSTNAME: "  " }, "macbook")).toBe("macbook");
    expect(resolveHost({}, "macbook")).toBe("macbook");
  });
});

describe("dispatchArgv", () => {
  test("invokes the cron binary with the playbook name and --scheduled, no shell", () => {
    expect(dispatchArgv("ceo-cron.sh", "morning-scan")).toEqual(["ceo-cron.sh", "morning-scan", "--scheduled"]);
  });
});

describe("staleness threshold is comfortably larger than the wake cap", () => {
  test("a single missed wake cannot trip a stale alert", () => {
    expect(HEARTBEAT_STALE_MS).toBeGreaterThanOrEqual(5 * MAX_SLEEP_MS);
  });
});

describe("catch-up look-back bounds (#157)", () => {
  test("the floor is sane and strictly below the cap", () => {
    expect(CATCHUP_LOOKBACK_FLOOR_MS).toBe(3_600_000); // 1h
    expect(CATCHUP_LOOKBACK_CAP_MS).toBe(21_600_000); // 6h
    expect(CATCHUP_LOOKBACK_FLOOR_MS).toBeLessThan(CATCHUP_LOOKBACK_CAP_MS);
  });
});

describe("dispatch-completion state paths", () => {
  test("run-state dirs are host-local under ~/.ceo/schedulerd", () => {
    expect(runStateDir("/home/me")).toBe("/home/me/.ceo/schedulerd/run-state");
    expect(runningDir("/home/me")).toBe("/home/me/.ceo/schedulerd/run-state/running");
    expect(doneDir("/home/me")).toBe("/home/me/.ceo/schedulerd/run-state/done");
  });
});

describe("parseRunningEntry (startedTs marker body)", () => {
  test("parses a positive epoch-ms integer", () => {
    expect(parseRunningEntry("1700000000000")).toBe(1_700_000_000_000);
    expect(parseRunningEntry("  1700000000000\n")).toBe(1_700_000_000_000);
  });
  test("garbage / zero / negative / empty → null (fail-safe)", () => {
    expect(parseRunningEntry("abc")).toBeNull();
    expect(parseRunningEntry("0")).toBeNull();
    expect(parseRunningEntry("-5")).toBeNull();
    expect(parseRunningEntry("")).toBeNull();
  });
});

describe("parseDoneEntry (CompletionRecord body)", () => {
  test("parses a valid record", () => {
    expect(parseDoneEntry('{"ts":100,"exitCode":0,"durationMs":42}')).toEqual({ ts: 100, exitCode: 0, durationMs: 42 });
  });
  test("torn JSON or missing/typewrong fields → null", () => {
    expect(parseDoneEntry('{"ts":100,"exitCode":0')).toBeNull(); // truncated write
    expect(parseDoneEntry('{"ts":100,"exitCode":0}')).toBeNull(); // missing durationMs
    expect(parseDoneEntry('{"ts":"x","exitCode":0,"durationMs":1}')).toBeNull(); // wrong type
    expect(parseDoneEntry("")).toBeNull();
  });
});

describe("isStaleRunning (crash-orphan guard)", () => {
  test("a marker within the window is live", () => {
    expect(isStaleRunning(1_000, 1_000 + RUN_STATE_STALE_MS, RUN_STATE_STALE_MS)).toBe(false);
  });
  test("a marker older than the window is a stale orphan", () => {
    expect(isStaleRunning(1_000, 1_000 + RUN_STATE_STALE_MS + 1, RUN_STATE_STALE_MS)).toBe(true);
  });
});

describe("completionRecord", () => {
  test("records exit code and clamps duration to >= 0", () => {
    expect(completionRecord(100, 142, 0)).toEqual({ ts: 142, exitCode: 0, durationMs: 42 });
    expect(completionRecord(200, 100, 1).durationMs).toBe(0); // clock skew never yields negative
  });
});

describe("buildCompletions (readCompletions reassembly)", () => {
  const NOW = 10_000_000;
  test("assembles valid running + done entries", () => {
    const out = buildCompletions(
      { morning: String(NOW - 1000) },
      { "morning-brief": '{"ts":123,"exitCode":0,"durationMs":5}' },
      NOW,
    );
    expect(out.running).toEqual({ morning: NOW - 1000 });
    expect(out.done).toEqual({ "morning-brief": { ts: 123, exitCode: 0, durationMs: 5 } });
  });
  test("drops a stale running marker so a crash orphan cannot wedge the MAX_CONCURRENT=1 queue", () => {
    const out = buildCompletions(
      { stuck: String(NOW - RUN_STATE_STALE_MS - 1), live: String(NOW - 1) },
      {},
      NOW,
    );
    expect(out.running).toEqual({ live: NOW - 1 }); // stuck dropped
  });
  test("drops garbage/torn entries on both sides (fail-safe)", () => {
    const out = buildCompletions({ bad: "nope" }, { torn: '{"ts":1' }, NOW);
    expect(out.running).toEqual({});
    expect(out.done).toEqual({});
  });
});

describe("resolveFixedLookbackMs (env override → fixed window, else derived)", () => {
  test("absent env → null (use the per-schedule derived look-back)", () => {
    expect(resolveFixedLookbackMs(undefined)).toBeNull();
  });
  test("a positive integer override pins a fixed window for all playbooks", () => {
    expect(resolveFixedLookbackMs("21600000")).toBe(21_600_000);
  });
  test("non-numeric / zero / negative / blank → null (fall through to derived, never a wrong window)", () => {
    expect(resolveFixedLookbackMs("abc")).toBeNull();
    expect(resolveFixedLookbackMs("0")).toBeNull();
    expect(resolveFixedLookbackMs("-5")).toBeNull();
    expect(resolveFixedLookbackMs("  ")).toBeNull();
  });
});
