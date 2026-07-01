import { describe, expect, test } from "bun:test";
import { resolveAdapterConfig } from "../src/main";

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
