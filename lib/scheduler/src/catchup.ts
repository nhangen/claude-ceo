/**
 * Missed-slot catch-up for ceo-schedulerd (#136 Phase 1.5, issue #143).
 *
 * When the daemon was down or a sleep overshot (suspend), schedules that should
 * have fired during the gap were skipped — the live loop only fires the current
 * minute via `matchesAt`. Catch-up fires **once** for the newest missed slot of
 * each playbook and skips the rest (no replay storm), bounded by a look-back
 * window so a slot that is too stale to be useful is not replayed.
 *
 * Pure: the daemon injects `now`, the matcher, and the look-back. The current
 * minute is deliberately excluded — that is the live dueAt path's responsibility.
 */
import type { CronMatcher } from "@/cron";
import type { Playbook } from "@/registry";

const MINUTE_MS = 60_000;
/** Bound on forward iteration when scanning for missed fires (defensive). */
const MAX_SCAN = 100_000;
/** Fires sampled forward to estimate a schedule's cadence (yields N-1 gaps). */
const PERIOD_SAMPLES = 5;

/**
 * A per-schedule catch-up look-back derived from the schedule's own cadence
 * (#157), so a registry with mixed cadences isn't served by one global value:
 * a 5-minutely slot shouldn't replay hours late, but a daily slot missed by an
 * overnight suspend should still catch up within a few hours.
 *
 * The cadence proxy is the MIN gap between the next {@link PERIOD_SAMPLES} fires
 * — the tightest interval the schedule fires at. Min-of-gaps (not the single
 * next gap) is deliberate: a forward sample anchored at `now` varies with wake
 * time for irregular schedules (e.g. fires at 09:00 and 12:00 give a 3h-then-21h
 * or 21h-then-3h pattern depending on `now`), whereas the min is
 * cadence-intrinsic. The result is
 * clamped to [floorMs, capMs]: sub-floor cadences clamp up (catch-up fires the
 * newest slot once regardless), and long cadences (daily, weekly) clamp down to
 * the cap — a weekly slot missed by more than the cap is deliberately not
 * replayed (don't run a stale job late at night). Unparseable / single-fire
 * schedules fall back to the floor and never throw.
 *
 * The min over a fixed sample window is an upper-bound estimate: a schedule
 * whose tightest gap only recurs beyond the window would round *up* toward the
 * cap. That errs conservative — a too-large look-back only ever replays the one
 * already-newest slot once (newest-slot semantics) and is still clamped to the
 * cap — so under-sampling can't cause a replay storm.
 */
export function lookbackForSchedule(
  schedule: string,
  now: Date,
  matcher: CronMatcher,
  floorMs: number,
  capMs: number,
): number {
  let cursor = now;
  let prev: Date | null = null;
  let minGap = Number.POSITIVE_INFINITY;
  for (let i = 0; i < PERIOD_SAMPLES; i++) {
    let next: Date | null;
    try {
      next = matcher.nextFire(schedule, cursor);
    } catch {
      break;
    }
    if (next === null) break;
    if (prev !== null) {
      const gap = next.getTime() - prev.getTime();
      if (gap < minGap) minGap = gap;
    }
    prev = next;
    cursor = next;
  }
  if (!Number.isFinite(minGap)) return floorMs;
  return Math.min(Math.max(minGap, floorMs), capMs);
}

/**
 * The newest fire strictly after `lastFired` (clamped to `now - lookbackMs`) and
 * strictly before the start of the minute containing `now`, or `null` if none.
 * An unparseable schedule yields `null` rather than throwing.
 */
export function newestMissedSlot(
  schedule: string,
  lastFired: number,
  now: Date,
  matcher: CronMatcher,
  lookbackMs: number,
): Date | null {
  const floor = Math.max(lastFired, now.getTime() - lookbackMs);
  const currentMinuteStart = Math.floor(now.getTime() / MINUTE_MS) * MINUTE_MS;
  if (floor >= currentMinuteStart) return null;

  let cursor = new Date(floor);
  let newest: Date | null = null;
  for (let i = 0; i < MAX_SCAN; i++) {
    let next: Date | null;
    try {
      next = matcher.nextFire(schedule, cursor);
    } catch {
      return null;
    }
    if (next === null || next.getTime() >= currentMinuteStart) break;
    newest = next;
    cursor = next;
  }
  return newest;
}

export interface CatchUpFire {
  playbook: Playbook;
  slot: Date;
}

/**
 * Catch-up fires for a set of playbooks. A playbook with no `last_fired` baseline
 * is skipped — the daemon has no basis to claim a slot was missed before it
 * started watching, so first-sight never triggers a replay.
 *
 * `lookbackFor` resolves each playbook's look-back from its own schedule (#157):
 * the daemon passes a period-derived resolver ({@link lookbackForSchedule}) or a
 * fixed `() => n` when the host pins the window via the env override.
 */
export function catchUpFires(
  playbooks: Playbook[],
  lastFired: Record<string, number>,
  now: Date,
  matcher: CronMatcher,
  lookbackFor: (schedule: string) => number,
): CatchUpFire[] {
  const fires: CatchUpFire[] = [];
  for (const p of playbooks) {
    const baseline = lastFired[p.name];
    if (baseline === undefined) continue;
    const slot = newestMissedSlot(p.schedule, baseline, now, matcher, lookbackFor(p.schedule));
    if (slot !== null) fires.push({ playbook: p, slot });
  }
  return fires;
}
