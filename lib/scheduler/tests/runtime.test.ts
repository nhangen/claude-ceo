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
  isSafeSegment,
  isStaleRunning,
  MAX_SLEEP_MS,
  parseDoneEntry,
  parseRunningEntry,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
  RUN_STATE_STALE_MS,
  runningDir,
  runningMarker,
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

describe("parseRunningEntry (startedTs [pid] marker body)", () => {
  test("parses startedTs with no PID (pre-spawn window)", () => {
    expect(parseRunningEntry("1700000000000")).toEqual({ startedTs: 1_700_000_000_000, pid: null });
    expect(parseRunningEntry("  1700000000000\n")).toEqual({ startedTs: 1_700_000_000_000, pid: null });
  });
  test("parses startedTs + PID", () => {
    expect(parseRunningEntry("1700000000000 4242")).toEqual({ startedTs: 1_700_000_000_000, pid: 4242 });
  });
  test("a garbage PID degrades to no-PID (falls back to the time guard), startedTs still honored", () => {
    expect(parseRunningEntry("1700000000000 abc")).toEqual({ startedTs: 1_700_000_000_000, pid: null });
  });
  test("garbage / zero / negative / empty startedTs → null (fail-safe)", () => {
    expect(parseRunningEntry("abc")).toBeNull();
    expect(parseRunningEntry("0")).toBeNull();
    expect(parseRunningEntry("-5")).toBeNull();
    expect(parseRunningEntry("")).toBeNull();
  });
});

describe("runningMarker (serialize)", () => {
  test("startedTs only when PID is absent", () => {
    expect(runningMarker(100)).toBe("100");
    expect(runningMarker(100, null)).toBe("100");
  });
  test("startedTs + PID when known", () => {
    expect(runningMarker(100, 4242)).toBe("100 4242");
  });
  test("round-trips through parseRunningEntry", () => {
    expect(parseRunningEntry(runningMarker(100, 4242))).toEqual({ startedTs: 100, pid: 4242 });
  });
});

describe("isSafeSegment (filename guard)", () => {
  test("accepts kebab/underscore/dot slugs", () => {
    expect(isSafeSegment("morning-brief")).toBe(true);
    expect(isSafeSegment("ticket_triage.v2")).toBe(true);
  });
  test("rejects path separators and traversal", () => {
    expect(isSafeSegment("a/b")).toBe(false);
    expect(isSafeSegment("..")).toBe(false);
    expect(isSafeSegment(".")).toBe(false);
    expect(isSafeSegment("../etc")).toBe(false);
    expect(isSafeSegment("")).toBe(false);
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
  test("with a PID + liveness probe: a dead PID is dropped immediately, a live PID is kept even past the stale window", () => {
    const alive = new Set([4242]);
    const out = buildCompletions(
      {
        crashed: runningMarker(NOW - 1, 9999), // recent but PID gone → crash orphan
        longRun: runningMarker(NOW - RUN_STATE_STALE_MS - 5, 4242), // older than stale but alive → real in-flight
      },
      {},
      NOW,
      { isAlive: (pid) => alive.has(pid) },
    );
    expect(out.running).toEqual({ longRun: NOW - RUN_STATE_STALE_MS - 5 });
  });
  test("without a PID (pre-spawn window), falls back to the time guard", () => {
    const out = buildCompletions(
      { preSpawn: runningMarker(NOW - 1) },
      {},
      NOW,
      { isAlive: () => false }, // probe present but marker has no PID → time guard applies
    );
    expect(out.running).toEqual({ preSpawn: NOW - 1 });
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
