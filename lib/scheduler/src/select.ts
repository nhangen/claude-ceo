/**
 * Pure scheduling decisions for the ceo-schedulerd daemon (#136 Phase 1.5).
 *
 * These functions hold no clock, filesystem, or process state — the daemon loop
 * injects `now` and a {@link CronMatcher}. That keeps the scheduling logic
 * exhaustively unit-testable without sleeping or spawning.
 */
import type { CronMatcher } from "@/cron";
import type { Playbook } from "@/registry";

/**
 * The playbooks this host may run on a schedule: cron-triggered, active, with a
 * non-blank schedule, gated by scope. A `scope: "each"` playbook runs iff it is
 * in this host's local `enabled` set; a `scope: "single"` playbook runs iff this
 * host is its owner (`owners[name] === host`). Ownership is authoritative —
 * local enablement does not gate single-scope playbooks.
 */
export function selectRunnable(
  playbooks: Playbook[],
  host: string,
  enabled: Set<string>,
  owners: Record<string, string>,
): Playbook[] {
  return playbooks.filter((p) => {
    if (p.trigger !== "cron" || p.status !== "active" || p.schedule.trim() === "") return false;
    return p.scope === "single" ? owners[p.name] === host : enabled.has(p.name);
  });
}

/** Playbooks firing during the minute containing `when`. Invalid schedules are skipped. */
export function dueAt(playbooks: Playbook[], when: Date, matcher: CronMatcher): Playbook[] {
  return playbooks.filter((p) => {
    try {
      return matcher.matchesAt(p.schedule, when);
    } catch {
      return false;
    }
  });
}

/**
 * Milliseconds to sleep until the soonest next fire across `playbooks`, clamped
 * to `maxSleepMs`. The cap means the loop re-reads the registry at least that
 * often (picking up edits and self-healing clock skew). Returns the cap when
 * nothing is scheduled or every schedule never fires again. Invalid schedules
 * are ignored.
 */
export function nextWake(
  playbooks: Playbook[],
  from: Date,
  matcher: CronMatcher,
  maxSleepMs: number,
): number {
  let soonest = Infinity;
  for (const p of playbooks) {
    let next: Date | null;
    try {
      next = matcher.nextFire(p.schedule, from);
    } catch {
      continue;
    }
    if (next !== null) soonest = Math.min(soonest, next.getTime());
  }
  if (soonest === Infinity) return maxSleepMs;
  return Math.max(0, Math.min(soonest - from.getTime(), maxSleepMs));
}
