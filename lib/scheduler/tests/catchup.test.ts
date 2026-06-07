import { describe, expect, test } from "bun:test";
import { catchUpFires, newestMissedSlot } from "@/catchup";
import { createMatcher } from "@/cron";
import type { Playbook } from "@/registry";

const m = createMatcher({ timezone: "UTC" });
const d = (iso: string) => new Date(iso);
const ms = (iso: string) => d(iso).getTime();
const HOUR = 3_600_000;

const pb = (over: Partial<Playbook>): Playbook => ({
  name: "p",
  schedule: "*/5 * * * *",
  status: "active",
  trigger: "cron",
  hosts: ["*"],
  ...over,
});

describe("newestMissedSlot", () => {
  test("no gap → null (last fire is recent, nothing missed before the current minute)", () => {
    // */5, last fired 09:00, now 09:03 — next fire is 09:05, nothing missed.
    expect(newestMissedSlot("*/5 * * * *", ms("2026-06-01T09:00:00Z"), d("2026-06-01T09:03:00Z"), m, HOUR)).toBeNull();
  });

  test("gap → the NEWEST missed slot, skipping the rest", () => {
    // down since 09:00, back at 09:17:30 — 09:05/09:10/09:15 were missed; fire once for 09:15.
    expect(newestMissedSlot("*/5 * * * *", ms("2026-06-01T09:00:00Z"), d("2026-06-01T09:17:30Z"), m, HOUR)).toEqual(
      d("2026-06-01T09:15:00Z"),
    );
  });

  test("excludes the current minute (that is the live dueAt path's job)", () => {
    // every minute, last fired 09:00, now exactly on the 09:05 fire — newest *missed* is 09:04.
    expect(newestMissedSlot("* * * * *", ms("2026-06-01T09:00:00Z"), d("2026-06-01T09:05:00Z"), m, HOUR)).toEqual(
      d("2026-06-01T09:04:00Z"),
    );
  });

  test("look-back bound: a slot older than now-lookback is too stale to replay", () => {
    const lastFired = ms("2026-05-31T09:00:00Z"); // yesterday
    // daily 09:00; back at 11:00 with a 1h look-back → 09:00 today is >1h stale → null.
    expect(newestMissedSlot("0 9 * * *", lastFired, d("2026-06-01T11:00:00Z"), m, HOUR)).toBeNull();
    // back at 09:30 → 09:00 today is within the look-back → replay it once.
    expect(newestMissedSlot("0 9 * * *", lastFired, d("2026-06-01T09:30:00Z"), m, HOUR)).toEqual(
      d("2026-06-01T09:00:00Z"),
    );
  });

  test("look-back floor wins over a very stale last_fired (only recent misses replay)", () => {
    // last fired 30 days ago, */5, now 09:17:30, 1h look-back → newest missed within the hour is 09:15.
    expect(newestMissedSlot("*/5 * * * *", ms("2026-05-01T00:00:00Z"), d("2026-06-01T09:17:30Z"), m, HOUR)).toEqual(
      d("2026-06-01T09:15:00Z"),
    );
  });

  test("invalid schedule → null, never throws", () => {
    expect(newestMissedSlot("not a cron", ms("2026-06-01T09:00:00Z"), d("2026-06-01T09:30:00Z"), m, HOUR)).toBeNull();
  });

  test("backward-DST (fall-back) stays monotonic and replays a real prior slot", () => {
    const ny = createMatcher({ timezone: "America/New_York" });
    // 2026-11-01 fall-back. Hourly. Down since 04:00Z, back at 07:30Z.
    const slot = newestMissedSlot("0 * * * *", ms("2026-11-01T04:00:00Z"), d("2026-11-01T07:30:00Z"), ny, HOUR);
    expect(slot).not.toBeNull();
    // Newest fire strictly before the 07:00Z minute, after the look-back floor (06:30Z) → 07:00Z.
    expect(slot).toEqual(d("2026-11-01T07:00:00Z"));
  });
});

describe("catchUpFires", () => {
  test("includes playbooks with a missed slot, excludes those without a last_fired baseline", () => {
    const pbs = [pb({ name: "seen" }), pb({ name: "fresh" })];
    const lastFired = { seen: ms("2026-06-01T09:00:00Z") }; // 'fresh' has no baseline yet
    const fires = catchUpFires(pbs, lastFired, d("2026-06-01T09:17:30Z"), m, HOUR);
    expect(fires.map((f) => f.playbook.name)).toEqual(["seen"]);
    expect(fires[0]!.slot).toEqual(d("2026-06-01T09:15:00Z"));
  });

  test("excludes a playbook with no gap", () => {
    const pbs = [pb({ name: "current" })];
    const lastFired = { current: ms("2026-06-01T09:15:00Z") };
    expect(catchUpFires(pbs, lastFired, d("2026-06-01T09:17:30Z"), m, HOUR)).toEqual([]);
  });
});
