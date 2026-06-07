/**
 * Durable persistence for the daemon heartbeat. The heartbeat doubles as the
 * double-fire guard's backing store (H1): on startup the daemon restores
 * `dispatched_minute` from here, so a `Restart=always` crash inside a fire-minute
 * does not re-run a playbook. A corrupt or missing file reads as `null` — the
 * guard starts empty rather than crashing the daemon at boot.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { DispatchRecord, Heartbeat } from "@/daemon";

export function readHeartbeatFile(path: string): Heartbeat | null {
  if (!existsSync(path)) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.ts !== "number") return null;
  if (typeof r.dispatched_minute !== "object" || r.dispatched_minute === null) return null;
  const lastDispatch = Array.isArray(r.last_dispatch) ? (r.last_dispatch as DispatchRecord[]) : [];
  // Drop any non-numeric guard value: a string slipping in would never `===`
  // the current epoch-minute, silently disabling the double-fire guard for that
  // playbook. Keep parity with the registry path's strictness.
  const dispatchedMinute = numericMap(r.dispatched_minute);
  // last_fired drives catch-up; same numeric filter, and absent (pre-#143
  // heartbeats) reads as empty so the daemon simply re-baselines.
  const lastFired = numericMap(r.last_fired);
  return {
    ts: r.ts,
    host: typeof r.host === "string" ? r.host : "",
    runnable_count: typeof r.runnable_count === "number" ? r.runnable_count : 0,
    next_wake_ts: typeof r.next_wake_ts === "number" ? r.next_wake_ts : 0,
    last_dispatch: lastDispatch,
    dispatched_minute: dispatchedMinute,
    last_fired: lastFired,
  };
}

// Drop any non-numeric value: a string slipping into the guard or last_fired
// would never compare correctly, silently disabling it for that playbook.
function numericMap(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (typeof raw === "object" && raw !== null) {
    for (const [name, v] of Object.entries(raw as Record<string, unknown>)) {
      if (typeof v === "number") out[name] = v;
    }
  }
  return out;
}

export function writeHeartbeatFile(path: string, hb: Heartbeat): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(hb, null, 2));
  renameSync(tmp, path);
}
