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
  return {
    ts: r.ts,
    host: typeof r.host === "string" ? r.host : "",
    runnable_count: typeof r.runnable_count === "number" ? r.runnable_count : 0,
    next_wake_ts: typeof r.next_wake_ts === "number" ? r.next_wake_ts : 0,
    last_dispatch: lastDispatch,
    dispatched_minute: r.dispatched_minute as Record<string, number>,
  };
}

export function writeHeartbeatFile(path: string, hb: Heartbeat): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(hb, null, 2));
  renameSync(tmp, path);
}
