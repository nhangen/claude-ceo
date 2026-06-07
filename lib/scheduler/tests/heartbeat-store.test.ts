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
  last_fired: { "morning-scan": 1_780_000_000_000 },
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

  test("non-numeric dispatched_minute values are dropped so the guard never holds a string", () => {
    const path = join(dir, "badguard.json");
    writeFileSync(
      path,
      JSON.stringify({ ts: 1, host: "x", dispatched_minute: { good: 5, bad: "abc", alsobad: null } }),
    );
    expect(readHeartbeatFile(path)!.dispatched_minute).toEqual({ good: 5 });
  });

  test("a pre-#143 heartbeat with no last_fired reads as empty (re-baselines, no crash)", () => {
    const path = join(dir, "prev143.json");
    writeFileSync(path, JSON.stringify({ ts: 1, host: "x", dispatched_minute: { a: 5 } }));
    expect(readHeartbeatFile(path)!.last_fired).toEqual({});
  });

  test("non-numeric last_fired values are dropped", () => {
    const path = join(dir, "badlastfired.json");
    writeFileSync(
      path,
      JSON.stringify({ ts: 1, host: "x", dispatched_minute: {}, last_fired: { good: 99, bad: "x" } }),
    );
    expect(readHeartbeatFile(path)!.last_fired).toEqual({ good: 99 });
  });
});
