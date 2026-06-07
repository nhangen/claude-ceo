import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Heartbeat } from "@/daemon";
import { readHeartbeatFile, writeHeartbeatFile } from "@/heartbeat-store";

const dir = mkdtempSync(join(tmpdir(), "ceo-hb-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const hb: Heartbeat = {
  ts: 1_780_000_000_000,
  host: "ml-1",
  runnable_count: 3,
  next_wake_ts: 1_780_000_060_000,
  last_dispatch: [{ name: "morning-scan", ts: 1_780_000_000_000 }],
  dispatched_minute: { "morning-scan": 29_666_666 },
};

describe("heartbeat round-trip", () => {
  test("writes then reads back an identical heartbeat (creates ~/.ceo/schedulerd)", () => {
    const path = join(dir, "schedulerd", "heartbeat.json");
    writeHeartbeatFile(path, hb);
    expect(readHeartbeatFile(path)).toEqual(hb);
  });

  test("missing file reads as null (guard simply starts empty)", () => {
    expect(readHeartbeatFile(join(dir, "nope.json"))).toBeNull();
  });

  test("malformed JSON reads as null rather than throwing at startup", () => {
    const path = join(dir, "corrupt.json");
    writeFileSync(path, "{ this is not json");
    expect(readHeartbeatFile(path)).toBeNull();
  });

  test("structurally wrong heartbeat (no dispatched_minute) reads as null", () => {
    const path = join(dir, "wrong.json");
    writeFileSync(path, JSON.stringify({ ts: 1, host: "x" }));
    expect(readHeartbeatFile(path)).toBeNull();
  });
});
