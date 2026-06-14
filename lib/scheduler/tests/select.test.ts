import { describe, expect, test } from "bun:test";
import { createMatcher } from "@/cron";
import type { Playbook } from "@/registry";
import { dueAt, nextWake, selectRunnable } from "@/select";

const m = createMatcher({ timezone: "UTC" });
const d = (iso: string) => new Date(iso);

const pb = (over: Partial<Playbook>): Playbook => ({
  name: "p",
  schedule: "0 9 * * *",
  status: "active",
  trigger: "cron",
  hosts: ["*"],
  scope: "each",
  ...over,
});

describe("selectRunnable — status + trigger + schedule gating", () => {
  const enabled = new Set(["a", "b", "c", "p"]);

  test("drops non-active status", () => {
    const pbs = [pb({ name: "a", status: "draft" }), pb({ name: "b", status: "disabled" }), pb({ name: "c", status: "active" })];
    expect(selectRunnable(pbs, "ml-1", enabled, {}).map((p) => p.name)).toEqual(["c"]);
  });

  test("drops non-cron triggers", () => {
    const pbs = [pb({ name: "a", trigger: "manual" }), pb({ name: "b", trigger: "cron" })];
    expect(selectRunnable(pbs, "ml-1", enabled, {}).map((p) => p.name)).toEqual(["b"]);
  });

  test("drops entries with a blank schedule", () => {
    const pbs = [pb({ name: "a", schedule: "   " }), pb({ name: "b", schedule: "0 9 * * *" })];
    expect(selectRunnable(pbs, "ml-1", enabled, {}).map((p) => p.name)).toEqual(["b"]);
  });
});

describe("selectRunnable — scope gating", () => {
  const owners = { soloA: "ml-1", soloB: "mac" };
  const enabled = new Set(["eachOn"]);
  test("each runs only when locally enabled", () => {
    const pbs = [pb({ name: "eachOn", scope: "each" }), pb({ name: "eachOff", scope: "each" })];
    expect(selectRunnable(pbs, "ml-1", enabled, owners).map((p) => p.name)).toEqual(["eachOn"]);
  });
  test("single runs only on its owner, ignoring local enable state", () => {
    const pbs = [pb({ name: "soloA", scope: "single" }), pb({ name: "soloB", scope: "single" })];
    expect(selectRunnable(pbs, "ml-1", enabled, owners).map((p) => p.name)).toEqual(["soloA"]);
  });
  test("single with no owner runs nowhere", () => {
    const pbs = [pb({ name: "orphan", scope: "single" })];
    expect(selectRunnable(pbs, "ml-1", new Set(), {})).toEqual([]);
  });
  test("a single playbook NOT owned by this host is excluded even if enabled", () => {
    const pbs = [pb({ name: "soloB", scope: "single" })];
    expect(selectRunnable(pbs, "ml-1", new Set(["soloB"]), owners)).toEqual([]);
  });
  test("status/trigger/blank-schedule gating still applies to each", () => {
    const pbs = [
      pb({ name: "draft", scope: "each", status: "draft" }),
      pb({ name: "manual", scope: "each", trigger: "manual" }),
      pb({ name: "blank", scope: "each", schedule: "  " }),
      pb({ name: "ok", scope: "each" }),
    ];
    expect(selectRunnable(pbs, "ml-1", new Set(["draft","manual","blank","ok"]), {}).map((p) => p.name)).toEqual(["ok"]);
  });
});

describe("dueAt — minute-granular fire set", () => {
  test("returns only playbooks firing during the given minute", () => {
    const pbs = [
      pb({ name: "nine", schedule: "0 9 * * *" }),
      pb({ name: "every15", schedule: "*/15 * * * *" }),
      pb({ name: "noon", schedule: "0 12 * * *" }),
    ];
    expect(dueAt(pbs, d("2026-06-01T09:00:00Z"), m).map((p) => p.name)).toEqual(["nine", "every15"]);
  });

  test("fires regardless of the seconds component (minute granularity)", () => {
    expect(dueAt([pb({ schedule: "0 9 * * *" })], d("2026-06-01T09:00:43Z"), m)).toHaveLength(1);
  });

  test("a playbook with an invalid schedule is silently skipped, not crashing the tick", () => {
    const pbs = [pb({ name: "bad", schedule: "not a cron" }), pb({ name: "ok", schedule: "0 9 * * *" })];
    expect(dueAt(pbs, d("2026-06-01T09:00:00Z"), m).map((p) => p.name)).toEqual(["ok"]);
  });
});

describe("nextWake — ms until the soonest next fire, capped", () => {
  const CAP = 60_000;

  test("sleeps exactly until the soonest next-fire when under the cap", () => {
    const pbs = [pb({ schedule: "*/5 * * * *" })];
    // from 12:00:00 → next */5 fire is 12:05:00 → 300_000ms, capped at 60_000.
    expect(nextWake(pbs, d("2026-06-01T12:00:00Z"), m, CAP)).toBe(CAP);
    // from 12:04:00 → next fire 12:05:00 → 60_000ms, exactly the cap boundary.
    expect(nextWake(pbs, d("2026-06-01T12:04:00Z"), m, CAP)).toBe(60_000);
    // from 12:04:30 → next fire 12:05:00 → 30_000ms, under the cap.
    expect(nextWake(pbs, d("2026-06-01T12:04:30Z"), m, CAP)).toBe(30_000);
  });

  test("takes the minimum across all playbooks", () => {
    const pbs = [pb({ name: "hourly", schedule: "0 * * * *" }), pb({ name: "soon", schedule: "*/5 * * * *" })];
    // from 12:01:00 → hourly fires 13:00 (3540s), */5 fires 12:05 (240s) → 240_000, capped to 60_000.
    expect(nextWake(pbs, d("2026-06-01T12:01:00Z"), m, CAP)).toBe(CAP);
    // from 12:04:10 → */5 fires 12:05:00 → 50_000ms (< cap), wins over hourly.
    expect(nextWake(pbs, d("2026-06-01T12:04:10Z"), m, CAP)).toBe(50_000);
  });

  test("falls back to the cap when nothing is scheduled (or all never-fire)", () => {
    expect(nextWake([], d("2026-06-01T12:00:00Z"), m, CAP)).toBe(CAP);
    expect(nextWake([pb({ schedule: "0 0 30 2 *" })], d("2026-06-01T12:00:00Z"), m, CAP)).toBe(CAP);
  });

  test("ignores invalid schedules rather than throwing", () => {
    const pbs = [pb({ name: "bad", schedule: "99 * * * *" }), pb({ name: "ok", schedule: "*/5 * * * *" })];
    expect(nextWake(pbs, d("2026-06-01T12:04:30Z"), m, CAP)).toBe(30_000);
  });
});
