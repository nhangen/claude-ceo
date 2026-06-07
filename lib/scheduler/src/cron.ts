import { Cron } from "croner";

/**
 * Cron next-fire matcher for the ceo-schedulerd daemon (#136 Phase 1.5).
 *
 * The daemon reads 5-field cron schedules from registry.json, asks this module
 * for the next fire instant, and sleeps until then. The croner dependency is
 * isolated behind {@link CronMatcher} so the engine can be swapped without
 * touching the daemon.
 */

/** Thrown for any expression croner cannot parse, or that is not 5-field. */
export class CronExpressionError extends Error {
  constructor(expr: unknown, cause?: unknown) {
    const detail = cause instanceof Error ? ` (${cause.message})` : "";
    super(`invalid cron expression: ${JSON.stringify(expr)}${detail}`);
    this.name = "CronExpressionError";
  }
}

export interface CronMatcher {
  /** The next fire instant strictly after `from`, or null if the cron never fires again. */
  nextFire(expr: string, from: Date): Date | null;
  /** Whether `expr` fires during the minute containing `when` (seconds ignored). */
  matchesAt(expr: string, when: Date): boolean;
}

export interface MatcherOptions {
  /** IANA timezone the schedule is evaluated in (e.g. "America/New_York"). Defaults to host-local. */
  timezone?: string;
}

const MINUTE_MS = 60_000;

class CronerMatcher implements CronMatcher {
  constructor(private readonly opts: MatcherOptions = {}) {}

  private build(expr: string): Cron {
    // Enforce the registry's 5-field contract before croner sees it: croner
    // also accepts a 6-field seconds form, which would break the minute
    // granularity the daemon and matchesAt() assume.
    const fields = expr.trim().split(/\s+/);
    if (expr.trim() === "" || fields.length !== 5) {
      throw new CronExpressionError(expr);
    }
    try {
      // legacyMode:true gives Vixie semantics — when BOTH day-of-month and
      // day-of-week are restricted, the cron fires if EITHER matches (the
      // behavior native cron and the registry's schedules assume).
      return new Cron(expr, { timezone: this.opts.timezone, legacyMode: true });
    } catch (cause) {
      throw new CronExpressionError(expr, cause);
    }
  }

  nextFire(expr: string, from: Date): Date | null {
    return this.build(expr).nextRun(from);
  }

  matchesAt(expr: string, when: Date): boolean {
    const cron = this.build(expr);
    const minute = Math.floor(when.getTime() / MINUTE_MS) * MINUTE_MS;
    // nextRun is strictly-after, so probe from 1ms before the minute boundary:
    // a fire at `minute` is then returned exactly.
    const next = cron.nextRun(new Date(minute - 1));
    return next !== null && next.getTime() === minute;
  }
}

export function createMatcher(opts: MatcherOptions = {}): CronMatcher {
  return new CronerMatcher(opts);
}
