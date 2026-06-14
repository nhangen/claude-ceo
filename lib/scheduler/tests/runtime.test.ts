import { describe, expect, test } from "bun:test";
import {
  CATCHUP_LOOKBACK_CAP_MS,
  CATCHUP_LOOKBACK_FLOOR_MS,
  dispatchArgv,
  enabledPath,
  HEARTBEAT_STALE_MS,
  heartbeatPath,
  MAX_SLEEP_MS,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
  swarmPath,
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
