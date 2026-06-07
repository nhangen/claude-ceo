import { describe, expect, test } from "bun:test";
import {
  dispatchArgv,
  HEARTBEAT_STALE_MS,
  heartbeatPath,
  MAX_SLEEP_MS,
  registryPath,
  resolveHost,
} from "@/runtime";

describe("path resolution", () => {
  test("registry lives under <vault>/CEO/registry.json", () => {
    expect(registryPath("/Users/x/Obsidian")).toBe("/Users/x/Obsidian/CEO/registry.json");
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
