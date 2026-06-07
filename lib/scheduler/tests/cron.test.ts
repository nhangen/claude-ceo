import { describe, expect, test } from "bun:test";
import { createMatcher, CronExpressionError } from "@/cron";

// All tests pin an explicit UTC timezone so they are deterministic regardless
// of the CI/host timezone. The DST/tz section uses named zones on purpose.
const m = createMatcher({ timezone: "UTC" });

const d = (iso: string) => new Date(iso);

// Collect every fire strictly after `start` and at-or-before `end`.
function firesBetween(expr: string, start: Date, end: Date): Date[] {
  const out: Date[] = [];
  let cur = start;
  // Hard cap to fail loudly rather than hang if nextFire ever stalls.
  for (let i = 0; i < 10000; i++) {
    const next = m.nextFire(expr, cur);
    if (next === null || next.getTime() > end.getTime()) break;
    out.push(next);
    cur = next;
  }
  return out;
}

describe("nextFire — wildcards, ranges, lists, steps", () => {
  test("every-minute fires at the next minute boundary", () => {
    expect(m.nextFire("* * * * *", d("2026-06-01T12:00:30Z"))).toEqual(d("2026-06-01T12:01:00Z"));
  });

  test("nextFire is strictly after `from` (a fire minute returns the NEXT one)", () => {
    expect(m.nextFire("* * * * *", d("2026-06-01T12:00:00Z"))).toEqual(d("2026-06-01T12:01:00Z"));
    expect(m.nextFire("30 9 * * *", d("2026-06-01T09:30:00Z"))).toEqual(d("2026-06-02T09:30:00Z"));
  });

  test("specific minute+hour", () => {
    expect(m.nextFire("30 9 * * *", d("2026-06-01T00:00:00Z"))).toEqual(d("2026-06-01T09:30:00Z"));
    expect(m.nextFire("30 9 * * *", d("2026-06-01T10:00:00Z"))).toEqual(d("2026-06-02T09:30:00Z"));
  });

  test("hour range 9-17", () => {
    const fires = firesBetween("0 9-17 * * *", d("2026-06-01T00:00:00Z"), d("2026-06-01T23:59:00Z"));
    expect(fires).toEqual([
      d("2026-06-01T09:00:00Z"), d("2026-06-01T10:00:00Z"), d("2026-06-01T11:00:00Z"),
      d("2026-06-01T12:00:00Z"), d("2026-06-01T13:00:00Z"), d("2026-06-01T14:00:00Z"),
      d("2026-06-01T15:00:00Z"), d("2026-06-01T16:00:00Z"), d("2026-06-01T17:00:00Z"),
    ]);
  });

  test("hour list 9,12,17", () => {
    const fires = firesBetween("0 9,12,17 * * *", d("2026-06-01T00:00:00Z"), d("2026-06-01T23:59:00Z"));
    expect(fires).toEqual([
      d("2026-06-01T09:00:00Z"), d("2026-06-01T12:00:00Z"), d("2026-06-01T17:00:00Z"),
    ]);
  });

  test("minute step */15", () => {
    const fires = firesBetween("*/15 * * * *", d("2026-06-01T12:00:00Z"), d("2026-06-01T12:59:00Z"));
    expect(fires).toEqual([
      d("2026-06-01T12:15:00Z"), d("2026-06-01T12:30:00Z"), d("2026-06-01T12:45:00Z"),
    ]);
  });

  test("step within a range 0-12/3 (hours)", () => {
    // Start 1ms before midnight so the 00:00 fire (a valid 0-12/3 occurrence)
    // is included — firesBetween returns fires strictly AFTER its start.
    const fires = firesBetween("0 0-12/3 * * *", d("2026-05-31T23:59:59Z"), d("2026-06-01T23:59:00Z"));
    expect(fires).toEqual([
      d("2026-06-01T00:00:00Z"), d("2026-06-01T03:00:00Z"), d("2026-06-01T06:00:00Z"),
      d("2026-06-01T09:00:00Z"), d("2026-06-01T12:00:00Z"),
    ]);
  });

  test("month field restricts to January", () => {
    expect(m.nextFire("0 0 1 1 *", d("2026-02-01T00:00:00Z"))).toEqual(d("2027-01-01T00:00:00Z"));
  });
});

describe("day-of-month vs day-of-week semantics (Vixie OR)", () => {
  // 2026-01-13 is a Tuesday (the 13th, not Friday).
  // 2026-01-16 is a Friday (the 16th, not the 13th).
  // 2026-01-20 is a Tuesday (neither the 13th nor a Friday).
  test("both DOM and DOW restricted → fires if EITHER matches", () => {
    expect(m.matchesAt("0 0 13 * 5", d("2026-01-13T00:00:00Z"))).toBe(true);  // 13th (DOM)
    expect(m.matchesAt("0 0 13 * 5", d("2026-01-16T00:00:00Z"))).toBe(true);  // Friday (DOW)
    expect(m.matchesAt("0 0 13 * 5", d("2026-01-20T00:00:00Z"))).toBe(false); // neither
  });

  test("DOM restricted, DOW wildcard → only the 13th", () => {
    expect(m.matchesAt("0 0 13 * *", d("2026-01-13T00:00:00Z"))).toBe(true);
    expect(m.matchesAt("0 0 13 * *", d("2026-01-16T00:00:00Z"))).toBe(false); // Friday but not 13th
  });

  test("DOW restricted, DOM wildcard → only Fridays", () => {
    expect(m.matchesAt("0 0 * * 5", d("2026-01-16T00:00:00Z"))).toBe(true);
    expect(m.matchesAt("0 0 * * 5", d("2026-01-13T00:00:00Z"))).toBe(false); // 13th but Tuesday
  });
});

describe("matchesAt — minute granularity, ignores seconds", () => {
  test("true exactly on the fire minute", () => {
    expect(m.matchesAt("30 9 * * *", d("2026-06-01T09:30:00Z"))).toBe(true);
  });
  test("ignores the seconds component", () => {
    expect(m.matchesAt("30 9 * * *", d("2026-06-01T09:30:59Z"))).toBe(true);
  });
  test("false on a non-fire minute", () => {
    expect(m.matchesAt("30 9 * * *", d("2026-06-01T09:31:00Z"))).toBe(false);
    expect(m.matchesAt("30 9 * * *", d("2026-06-01T08:30:00Z"))).toBe(false);
  });
});

describe("invalid expressions", () => {
  test("nextFire throws CronExpressionError", () => {
    expect(() => m.nextFire("not a cron", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
    expect(() => m.nextFire("99 * * * *", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
  });
  test("matchesAt throws CronExpressionError", () => {
    expect(() => m.matchesAt("60 * * * *", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
  });
  test("wrong field count is rejected (5-field only)", () => {
    expect(() => m.nextFire("* * * *", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
  });

  // croner ACCEPTS the 6-field seconds form; the length guard is the only thing
  // rejecting it. Without the guard "* * * * * *" fires every second, breaking
  // the daemon's (and matchesAt's) minute-granularity contract. This is the
  // guard's sole unique coverage — every other invalid input croner throws on.
  test("6-field seconds form is rejected (minute granularity only)", () => {
    expect(() => m.nextFire("* * * * * *", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
    expect(() => m.matchesAt("* * * * * *", d("2026-06-01T00:00:00Z"))).toThrow(CronExpressionError);
  });
});

describe("never-fires", () => {
  // Feb 30 is a valid expression that can never match → null (the daemon treats
  // this as "no next fire," not an error). Pins the Date|null return contract.
  test("nextFire returns null for an unsatisfiable schedule", () => {
    expect(m.nextFire("0 0 30 2 *", d("2026-06-01T00:00:00Z"))).toBeNull();
  });
});

describe("timezone handling", () => {
  test("the same expression fires at a different UTC instant per timezone", () => {
    const utc = createMatcher({ timezone: "UTC" });
    const ny = createMatcher({ timezone: "America/New_York" });
    const from = d("2026-06-01T00:00:00Z"); // EDT (UTC-4) in June
    expect(utc.nextFire("0 12 * * *", from)).toEqual(d("2026-06-01T12:00:00Z"));
    expect(ny.nextFire("0 12 * * *", from)).toEqual(d("2026-06-01T16:00:00Z")); // 12:00 EDT
  });

  test("default matcher (no timezone) still produces monotonic fires", () => {
    const local = createMatcher();
    const a = local.nextFire("*/5 * * * *", d("2026-06-01T00:00:00Z"));
    expect(a).not.toBeNull();
    const b = local.nextFire("*/5 * * * *", a!);
    expect(b!.getTime()).toBeGreaterThan(a!.getTime());
  });
});

describe("DST transitions stay monotonic (no gap stall, no fall-back replay)", () => {
  const ny = createMatcher({ timezone: "America/New_York" });

  // Spring forward: 2026-03-08, clocks jump 02:00 → 03:00 in America/New_York.
  test("hourly schedule advances strictly through the spring-forward gap", () => {
    let cur = d("2026-03-08T04:00:00Z"); // 23:00 EST the night before
    let prev = cur.getTime();
    for (let i = 0; i < 12; i++) {
      const next = ny.nextFire("0 * * * *", cur);
      expect(next).not.toBeNull();
      expect(next!.getTime()).toBeGreaterThan(prev);
      prev = next!.getTime();
      cur = next!;
    }
  });

  // Fall back: 2026-11-01, clocks repeat 01:00 → 01:59 twice in America/New_York.
  test("hourly schedule does not stall or rewind across the fall-back overlap", () => {
    let cur = d("2026-11-01T04:00:00Z"); // 00:00 EDT
    let prev = cur.getTime();
    for (let i = 0; i < 12; i++) {
      const next = ny.nextFire("0 * * * *", cur);
      expect(next).not.toBeNull();
      expect(next!.getTime()).toBeGreaterThan(prev);
      prev = next!.getTime();
      cur = next!;
    }
  });

  // Exact wall-clock policy (pins croner's gap/overlap contract — a croner
  // upgrade that changed it must break here, not silently in the daemon).
  test("spring-forward: a 02:00 schedule shifts to 03:00 EDT (does not skip the day)", () => {
    // 2026-03-08 02:00 EST does not exist; croner fires at 03:00 EDT = 07:00Z.
    expect(ny.nextFire("0 2 * * *", d("2026-03-07T12:00:00Z"))).toEqual(d("2026-03-08T07:00:00Z"));
  });

  test("fall-back: a 01:30 schedule fires once, at the first (EDT) occurrence", () => {
    // 2026-11-01 01:30 happens twice; croner fires at 01:30 EDT = 05:30Z (not 06:30Z EST).
    expect(ny.nextFire("30 1 * * *", d("2026-10-31T12:00:00Z"))).toEqual(d("2026-11-01T05:30:00Z"));
  });
});
