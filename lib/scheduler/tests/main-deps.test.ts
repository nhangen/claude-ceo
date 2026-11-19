import { describe, expect, test } from "bun:test";
import { createMatcher, CATCHUP_LOOKBACK_CAP_MS, CATCHUP_LOOKBACK_FLOOR_MS } from "cronbird/core";
import { createHeartbeatReader, createLookbackResolver } from "@/main";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function withDir(fn: (dir: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "schedulerd-deps-"));
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("createHeartbeatReader (#656)", () => {
  test("restores the prior heartbeat itself, not cronbird's { value, warnings } wrapper", () => {
    withDir((dir) => {
      const path = join(dir, "heartbeat.json");
      writeFileSync(path, JSON.stringify({ ts: 1, dispatched_minute: { morning: 29000000 } }));
      const logged: string[] = [];
      const hb = createHeartbeatReader(path, (m) => logged.push(m))();
      expect(hb?.dispatched_minute).toEqual({ morning: 29000000 });
      expect(logged).toEqual([]);
    });
  });

  test("logs the loader's warning when the heartbeat is corrupt, so an emptied guard is visible", () => {
    withDir((dir) => {
      const path = join(dir, "heartbeat.json");
      writeFileSync(path, "{not json");
      const logged: string[] = [];
      expect(createHeartbeatReader(path, (m) => logged.push(m))()).toBeNull();
      expect(logged).toHaveLength(1);
      expect(logged[0]).toContain(`heartbeat file present but unparseable: ${path}`);
    });
  });

  test("a missing heartbeat is a quiet first boot", () => {
    withDir((dir) => {
      const logged: string[] = [];
      expect(createHeartbeatReader(join(dir, "absent.json"), (m) => logged.push(m))()).toBeNull();
      expect(logged).toEqual([]);
    });
  });
});

describe("createLookbackResolver", () => {
  const now = new Date(2026, 10, 19, 12, 0, 0);
  const matcher = createMatcher();

  test("derives the window from the job's cronSchedule: a daily job gets the cap", () => {
    expect(createLookbackResolver(null, matcher)({ cronSchedule: "0 6 * * *" }, now)).toBe(CATCHUP_LOOKBACK_CAP_MS);
  });

  test("a sub-hourly job gets the floor", () => {
    expect(createLookbackResolver(null, matcher)({ cronSchedule: "*/5 * * * *" }, now)).toBe(CATCHUP_LOOKBACK_FLOOR_MS);
  });

  test("a host-pinned fixed window wins", () => {
    expect(createLookbackResolver(1234, matcher)({ cronSchedule: "0 6 * * *" }, now)).toBe(1234);
  });
});
