import { describe, expect, test } from "bun:test";
import { createMatcher } from "cronbird/core";
import {
  buildCompletions,
  cadenceMs,
  DEFAULT_COOLDOWN_SECONDS,
  parseCooldownSeconds,
  resolveCooldownSeconds,
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

describe("parseCooldownSeconds (global guard value, fail-safe toward guarding)", () => {
  test("reads cooldown_seconds from settings.json", () => {
    expect(parseCooldownSeconds('{"cooldown_seconds":900}')).toBe(900);
  });
  test("0 is honoured — an explicit opt-out is not the same as a missing value", () => {
    expect(parseCooldownSeconds('{"cooldown_seconds":0}')).toBe(0);
  });
  test("absent / empty / malformed / wrong-type → the default, never 0", () => {
    // An unreadable config must not silently disarm the guard. Each of these
    // returning 0 would look identical to the honoured opt-out above.
    for (const raw of ["", "{}", "not json", '{"cooldown_seconds":"1800"}', '{"cooldown_seconds":-5}', '{"cooldown_seconds":12.5}', '{"cooldown_seconds":null}']) {
      expect(parseCooldownSeconds(raw)).toBe(DEFAULT_COOLDOWN_SECONDS);
    }
  });
  test("the default matches the shell side's `_cfg '.cooldown_seconds' '1800'`", () => {
    // These two are a pair: ceo-cron.sh still applies the gate on manual runs, so
    // a drift here means manual and scheduled runs disagree on the same guard.
    expect(DEFAULT_COOLDOWN_SECONDS).toBe(1800);
  });
});

describe("cadenceMs (tightest interval a schedule fires at)", () => {
  const matcher = createMatcher();
  const NOW = new Date("2026-08-11T00:00:00Z");
  test("*/30 → 30 minutes", () => {
    expect(cadenceMs("*/30 * * * *", NOW, matcher)).toBe(30 * 60_000);
  });
  test("hourly and daily", () => {
    expect(cadenceMs("0 * * * *", NOW, matcher)).toBe(60 * 60_000);
    expect(cadenceMs("0 3 * * *", NOW, matcher)).toBe(24 * 60 * 60_000);
  });
  test("min-of-gaps, not the next gap — an irregular schedule reports its tightest interval", () => {
    // Fires 09:00 and 12:00: the forward gaps are 3h and 21h. Asked at 00:00 the
    // *first* gap is 9h, so a next-gap proxy would answer 9h here and 3h an hour
    // later. The min is 3h regardless of when you ask.
    expect(cadenceMs("0 9,12 * * *", NOW, matcher)).toBe(3 * 60 * 60_000);
    expect(cadenceMs("0 9,12 * * *", new Date("2026-08-11T10:00:00Z"), matcher)).toBe(3 * 60 * 60_000);
  });
  test("unparseable schedule → null rather than a throw inside a per-tick resolver", () => {
    expect(cadenceMs("not a cron", NOW, matcher)).toBeNull();
  });
});

describe("resolveCooldownSeconds (guard must never outrank an explicit schedule)", () => {
  const matcher = createMatcher();
  const NOW = new Date("2026-08-11T00:00:00Z");

  test("a */30 schedule is capped to 15m, so the 1800s global cannot eat every other slot", () => {
    // The production bug: cronbird measures cooldown from the previous run's
    // completion (slot + runtime), so 1800s against a 1800s cadence skipped
    // ticket-triage-autopilot ~1000 times at "29m ago" — a real cadence of 60m.
    expect(resolveCooldownSeconds(1800, "*/30 * * * *", NOW, matcher)).toBe(900);
  });

  test("the cap is what prevents the skip; the uncapped global would not", () => {
    // Self-validating: asserts the pre-fix value actually suppressed the next
    // slot, so this test fails if the cap is removed *and* proves the scenario
    // was real rather than hypothetical.
    const cadenceSec = cadenceMs("*/30 * * * *", NOW, matcher)! / 1000;
    const runtimeSec = 5; // a fast run; the gap to the next slot is cadence - 5
    expect(1800).toBeGreaterThan(cadenceSec - runtimeSec); // uncapped → skipped
    expect(resolveCooldownSeconds(1800, "*/30 * * * *", NOW, matcher)).toBeLessThan(cadenceSec - runtimeSec);
  });

  test("anything slower than hourly is still bound by the global, not the cap", () => {
    expect(resolveCooldownSeconds(1800, "0 3 * * *", NOW, matcher)).toBe(1800);
    expect(resolveCooldownSeconds(1800, "0 */6 * * *", NOW, matcher)).toBe(1800);
  });

  test("a 0 global disables the gate outright, cap or no cap", () => {
    expect(resolveCooldownSeconds(0, "*/30 * * * *", NOW, matcher)).toBe(0);
  });

  test("unparseable schedule keeps the global — it never fires, so the value is moot", () => {
    expect(resolveCooldownSeconds(1800, "not a cron", NOW, matcher)).toBe(1800);
  });

  test("every enabled-in-production schedule keeps its own cadence", () => {
    // Guards the whole registry, not just the one that broke: for each schedule,
    // the resolved cooldown must leave room for a run of up to half its period.
    for (const s of ["*/30 * * * *", "0 */6 * * *", "45 8 * * 1-5", "0 6 * * 1-5", "30 9 * * *", "0 8 * * SUN"]) {
      const cadence = cadenceMs(s, NOW, matcher)!;
      expect(resolveCooldownSeconds(1800, s, NOW, matcher) * 1000).toBeLessThanOrEqual(cadence / 2);
    }
  });
});
