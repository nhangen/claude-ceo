import { describe, expect, test } from "bun:test";
import { catchUpFires, lookbackForSchedule, newestMissedSlot } from "@/catchup";
import { createMatcher } from "@/cron";
import type { Playbook } from "@/registry";

const m = createMatcher({ timezone: "UTC" });
const d = (iso: string) => new Date(iso);
const ms = (iso: string) => d(iso).getTime();
const HOUR = 3_600_000;
const FLOOR = HOUR; // 1h
const CAP = 6 * HOUR; // 6h

const pb = (over: Partial<Playbook>): Playbook => ({
  name: "p",
  schedule: "*/5 * * * *",
  status: "active",
  trigger: "cron",
  hosts: ["*"],
  scope: "each",
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

  test("forward-DST (spring-forward) replays the correct prior slot across the gap", () => {
    const ny = createMatcher({ timezone: "America/New_York" });
    // 2026-03-08 spring-forward (02:00→03:00 local; the 02:00 wall-clock hour does
    // not exist). Hourly, 2h look-back. Down since 05:00Z (00:00 EST), back at
    // 08:30Z (04:30 EDT) — newest fire before the 08:30Z minute is 08:00Z (04:00 EDT).
    const slot = newestMissedSlot("0 * * * *", ms("2026-03-08T05:00:00Z"), d("2026-03-08T08:30:00Z"), ny, 2 * HOUR);
    expect(slot).toEqual(d("2026-03-08T08:00:00Z"));
  });
});

describe("lookbackForSchedule", () => {
  const now = d("2026-06-01T10:00:00Z");

  test("sub-floor cadence (*/5) clamps UP to the floor", () => {
    // 5-minute period < 1h floor → floor. (Newest-slot-only fires once anyway.)
    expect(lookbackForSchedule("*/5 * * * *", now, m, FLOOR, CAP)).toBe(FLOOR);
  });

  test("hourly period passes through unclamped", () => {
    expect(lookbackForSchedule("0 * * * *", now, m, FLOOR, CAP)).toBe(HOUR);
  });

  test("an in-range period (every 2h) is used as-is", () => {
    expect(lookbackForSchedule("0 */2 * * *", now, m, FLOOR, CAP)).toBe(2 * HOUR);
  });

  test("daily period clamps DOWN to the cap", () => {
    expect(lookbackForSchedule("0 9 * * *", now, m, FLOOR, CAP)).toBe(CAP);
  });

  test("weekly period clamps down to the cap (a >cap-stale weekly slot is not replayed)", () => {
    expect(lookbackForSchedule("0 9 * * 1", now, m, FLOOR, CAP)).toBe(CAP);
  });

  test("irregular schedule uses the MIN gap and is invariant to `now` (the tightest cadence)", () => {
    // 0 9,12 → gaps of 3h (09→12) and 21h (12→09 next day). The min gap is 3h,
    // in range → 3h. A single-forward-gap proxy anchored at `now` would yield
    // 21h→cap(6h) at 10:00 but 3h at 13:00; min-of-gaps is the same either way.
    const at10 = lookbackForSchedule("0 9,12 * * *", d("2026-06-01T10:00:00Z"), m, FLOOR, CAP);
    const at13 = lookbackForSchedule("0 9,12 * * *", d("2026-06-01T13:00:00Z"), m, FLOOR, CAP);
    expect(at10).toBe(3 * HOUR);
    expect(at13).toBe(3 * HOUR);
  });

  test("unparseable schedule falls back to the floor (never throws)", () => {
    expect(lookbackForSchedule("not a cron", now, m, FLOOR, CAP)).toBe(FLOOR);
  });
});

describe("catchUpFires", () => {
  const fixedHour = () => HOUR;

  test("includes playbooks with a missed slot, excludes those without a last_fired baseline", () => {
    const pbs = [pb({ name: "seen" }), pb({ name: "fresh" })];
    const lastFired = { seen: ms("2026-06-01T09:00:00Z") }; // 'fresh' has no baseline yet
    const fires = catchUpFires(pbs, lastFired, d("2026-06-01T09:17:30Z"), m, fixedHour);
    expect(fires.map((f) => f.playbook.name)).toEqual(["seen"]);
    expect(fires[0]!.slot).toEqual(d("2026-06-01T09:15:00Z"));
  });

  test("excludes a playbook with no gap", () => {
    const pbs = [pb({ name: "current" })];
    const lastFired = { current: ms("2026-06-01T09:15:00Z") };
    expect(catchUpFires(pbs, lastFired, d("2026-06-01T09:17:30Z"), m, fixedHour)).toEqual([]);
  });

  test("resolver is applied per schedule: a 3h-stale daily slot catches up (derived ~6h) where a fixed 1h would skip", () => {
    const daily = pb({ name: "daily", schedule: "0 9 * * *" });
    const lastFired = { daily: ms("2026-05-31T09:00:00Z") }; // yesterday 09:00
    const now = d("2026-06-01T12:00:00Z"); // 3h after today's 09:00 slot
    const derived = (s: string) => lookbackForSchedule(s, now, m, FLOOR, CAP);
    expect(catchUpFires([daily], lastFired, now, m, derived).map((f) => f.slot)).toEqual([
      d("2026-06-01T09:00:00Z"),
    ]);
    // The same slot is 3h stale → a fixed 1h look-back drops it.
    expect(catchUpFires([daily], lastFired, now, m, fixedHour)).toEqual([]);
  });
});
