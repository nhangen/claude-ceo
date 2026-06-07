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
 */
export function catchUpFires(
  playbooks: Playbook[],
  lastFired: Record<string, number>,
  now: Date,
  matcher: CronMatcher,
  lookbackMs: number,
): CatchUpFire[] {
  const fires: CatchUpFire[] = [];
  for (const p of playbooks) {
    const baseline = lastFired[p.name];
    if (baseline === undefined) continue;
    const slot = newestMissedSlot(p.schedule, baseline, now, matcher, lookbackMs);
    if (slot !== null) fires.push({ playbook: p, slot });
  }
  return fires;
}
