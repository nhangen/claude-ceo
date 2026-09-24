/**
 * CEO CLI status and next-runs command (#237).
 * Reads the host-local registry, enabled set, vault swarm.json, and heartbeat,
 * then delegates to cronbird's `computeStatus` to project per-job next-fire times,
 * runnability, and health.
 */
import { existsSync, readFileSync } from "node:fs";
import {
  computeStatus,
  createMatcher,
  STALE_EXIT_CODE,
  type StatusReport,
} from "cronbird/core";
import { readHeartbeatFile } from "cronbird/cli";
import { parseRegistry } from "@/registry";
import { parseEnabled } from "@/enabled";
import { parseSwarm } from "@/swarm";
import {
  enabledPath,
  HEARTBEAT_STALE_MS,
  heartbeatPath,
  registryPath,
  resolveAdapterConfig,
  swarmPath,
} from "@/runtime";

export type StatusSubcommand = "status" | "next-runs";

export interface StatusCliDeps {
  now: () => Date;
  out: (s: string) => void;
  err: (s: string) => void;
  env: Record<string, string | undefined>;
}

/** Absent, corrupt, and fresh are three different answers about the daemon. */
export type HeartbeatState = "ok" | "absent" | "corrupt";

export interface ParsedArgs {
  json: boolean;
  withinMs: number | null;
}

/** Parse `Nd`/`Nh`/`Nm`/`Ns` into ms. Returns null on any other shape. */
export function parseDuration(s: string | undefined): number | null {
  if (!s) return null;
  const m = /^(\d+)(s|m|h|d)$/.exec(s.trim());
  if (!m) return null;
  const n = Number(m[1]);
  const unit = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 }[m[2] as "s" | "m" | "h" | "d"];
  return n * unit;
}

export function parseFlags(sub: StatusSubcommand, args: string[], deps: StatusCliDeps): ParsedArgs | number {
  let json = false;
  let withinMs: number | null = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--json") {
      json = true;
    } else if (a === "--within") {
      const val = args[++i];
      if (val === undefined) {
        deps.err(`--within requires a duration (use e.g. 30m, 2h, 1d)\n`);
        return 2;
      }
      const ms = parseDuration(val);
      if (ms === null) {
        deps.err(`invalid --within duration: ${JSON.stringify(val)} (use e.g. 30m, 2h, 1d)\n`);
        return 2;
      }
      withinMs = ms;
    } else if (a === "--help" || a === "-h") {
      deps.out(usage(sub));
      return 0;
    } else if (a.startsWith("-")) {
      deps.err(`unknown flag: ${a}\n`);
      return 2;
    } else {
      deps.err(`unexpected argument: ${a}\n`);
      return 2;
    }
  }
  if (withinMs !== null && sub !== "next-runs") {
    deps.err(`--within is only valid for next-runs\n`);
    return 2;
  }
  return { json, withinMs };
}

/** Reached only by direct `bun run src/status.ts`: `_wants_help` in the ceo wrapper answers first. */
function usage(sub: StatusSubcommand): string {
  if (sub === "next-runs") {
    return "Usage: ceo playbook next-runs [--within <dur>] [--json]\n";
  }
  return "Usage: ceo status [--json]\n";
}

export function fmtTs(ms: number | null): string {
  return ms === null ? "-" : new Date(ms).toISOString();
}

/** "in 1h 5m" / "2m ago" / "now". */
export function fmtRelative(deltaMs: number): string {
  const past = deltaMs < 0;
  let s = Math.floor(Math.abs(deltaMs) / 1000);
  if (s < 1) return "now";
  const d = Math.floor(s / 86_400); s -= d * 86_400;
  const h = Math.floor(s / 3_600); s -= h * 3_600;
  const m = Math.floor(s / 60);
  const parts = [d && `${d}d`, h && `${h}h`, m && `${m}m`].filter(Boolean).slice(0, 2);
  const body = parts.length ? parts.join(" ") : "<1m";
  return past ? `${body} ago` : `in ${body}`;
}

/** Registry strings reach the terminal here, so control characters are neutralized first. */
function cellText(s: string | undefined): string {
  return (s ?? "").replace(/[\x00-\x1f\x7f]/g, "?");
}

export function table(rows: string[][]): string {
  if (rows.length === 0) return "";
  rows = rows.map((r) => r.map(cellText));
  const cols = Math.max(...rows.map((r) => r.length));
  const widths = Array.from({ length: cols }, (_, c) => Math.max(...rows.map((r) => (r[c] ?? "").length)));
  return rows.map((r) => r.map((cell, c) => cell.padEnd(widths[c]!)).join("  ").trimEnd()).join("\n") + "\n";
}

function yesno(b: boolean): string {
  return b ? "yes" : "no";
}

function renderNextRuns(report: StatusReport, hbState: HeartbeatState, parsed: ParsedArgs, deps: StatusCliDeps): void {
  const cutoff = parsed.withinMs === null ? Infinity : report.now + parsed.withinMs;
  const upcoming = report.jobs
    .filter((j) => j.nextFire !== null && j.nextFire <= cutoff)
    .sort((a, b) => a.nextFire! - b.nextFire!);
  if (parsed.json) {
    deps.out(JSON.stringify({
      host: report.host,
      now: report.now,
      daemonStale: report.daemonStale,
      heartbeatAgeMs: report.heartbeatAgeMs,
      heartbeatState: hbState,
      nextRuns: upcoming.map((j) => ({
        name: j.name, nextFire: j.nextFire, nextFireIso: fmtTs(j.nextFire),
      })),
    }, null, 2) + "\n");
    return;
  }
  const rows: string[][] = [["NAME", "NEXT FIRE", "IN"]];
  for (const j of upcoming) rows.push([j.name, fmtTs(j.nextFire), fmtRelative(j.nextFire! - report.now)]);
  if (upcoming.length === 0) {
    deps.out("no upcoming runs" + (parsed.withinMs !== null ? " in window" : "") + "\n");
    return;
  }
  deps.out(table(rows));
}

function daemonLine(report: StatusReport, hbState: HeartbeatState): string {
  if (hbState === "corrupt") return "heartbeat file unreadable";
  if (report.heartbeatAgeMs === null) return "never checked in";
  return `heartbeat ${fmtRelative(-report.heartbeatAgeMs)}`;
}

function renderStatus(report: StatusReport, hbState: HeartbeatState, parsed: ParsedArgs, deps: StatusCliDeps): void {
  if (parsed.json) {
    // Projected field by field: `report` is cronbird's type, and the CRONBIRD_REF pin
    // is worth nothing if a bump reshapes this command's output for its consumers.
    deps.out(JSON.stringify({
      host: report.host,
      now: report.now,
      daemonStale: report.daemonStale,
      heartbeatAgeMs: report.heartbeatAgeMs,
      heartbeatState: hbState,
      jobs: report.jobs.map((j) => ({
        name: j.name,
        schedule: j.schedule,
        scope: j.scope,
        isActive: j.isActive,
        runnable: j.runnable,
        lastFired: j.lastFired,
        nextFire: j.nextFire,
        health: j.health,
      })),
    }, null, 2) + "\n");
    return;
  }
  const hb = daemonLine(report, hbState);
  const marker = report.daemonStale ? "STALE — " : "";
  deps.out(`host=${report.host}  daemon: ${marker}${hb}\n\n`);
  const rows: string[][] = [["NAME", "SCOPE", "RUNNABLE", "LAST FIRED", "NEXT FIRE", "HEALTH"]];
  for (const j of report.jobs) {
    rows.push([
      j.name,
      j.scope,
      yesno(j.runnable),
      j.lastFired === null ? "-" : fmtRelative(j.lastFired - report.now),
      j.nextFire === null ? "-" : fmtRelative(j.nextFire - report.now),
      j.health,
    ]);
  }
  deps.out(table(rows));
}

function render(sub: StatusSubcommand, report: StatusReport, hbState: HeartbeatState, parsed: ParsedArgs, deps: StatusCliDeps): void {
  if (sub === "next-runs") return renderNextRuns(report, hbState, parsed, deps);
  return renderStatus(report, hbState, parsed, deps);
}

function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * The daemon's parsers default silently on bad input, which is right for something
 * that must never *run* the wrong thing and wrong for a CLI that must never *assert*
 * the wrong thing. These wrappers keep the defaults and say so.
 */
function loadEnabled(enP: string, deps: StatusCliDeps): Set<string> {
  if (!existsSync(enP)) return new Set();
  let raw: string;
  try {
    raw = readFileSync(enP, "utf8");
  } catch (e) {
    deps.err(`warning: enabled file unreadable: ${enP} (${errText(e)})\n`);
    return new Set();
  }
  let doc: unknown;
  try {
    doc = JSON.parse(raw);
  } catch {
    deps.err(`warning: enabled file present but unparseable: ${enP} — no each-scope playbook will report runnable\n`);
    return new Set();
  }
  if (!Array.isArray(doc)) {
    deps.err(`warning: enabled file is not a JSON array: ${enP} — no each-scope playbook will report runnable\n`);
    return new Set();
  }
  // parseEnabled owns the element-level filtering; the checks above exist only to
  // tell an unreadable file apart from a genuinely empty one.
  return parseEnabled(raw);
}

function loadOwners(swP: string, deps: StatusCliDeps): Record<string, string> {
  if (!existsSync(swP)) {
    deps.err(`warning: no swarm file at ${swP} — every single-scope playbook will report not-runnable\n`);
    return {};
  }
  let raw: string;
  try {
    raw = readFileSync(swP, "utf8");
  } catch (e) {
    deps.err(`warning: swarm file unreadable: ${swP} (${errText(e)})\n`);
    return {};
  }
  const swarm = parseSwarm(raw);
  if (swarm === null) {
    deps.err(`warning: swarm file present but unparseable: ${swP} — every single-scope playbook will report not-runnable\n`);
    return {};
  }
  return swarm.owners;
}

export function runCeoStatusCommand(sub: StatusSubcommand, args: string[], deps: StatusCliDeps): number {
  const parsed = parseFlags(sub, args, deps);
  if (typeof parsed === "number") return parsed;

  const home = deps.env.HOME ?? "";
  if (home === "") {
    deps.err(`HOME is not set; cannot locate the host-local registry.\n`);
    return 1;
  }
  const vault = deps.env.CEO_VAULT ?? "";
  const cfg = resolveAdapterConfig(deps.env);

  const regP = registryPath(home);
  if (!existsSync(regP)) {
    deps.err(`No registry found at ${regP}. Run: ceo playbook scan\n`);
    return 1;
  }

  let jobs;
  try {
    const res = parseRegistry(readFileSync(regP, "utf8"));
    jobs = res.jobs;
    for (const w of res.warnings) deps.err(`warning: ${w}\n`);
    if (jobs.length === 0) {
      deps.err(`warning: no playbooks in registry at ${regP}. If that is unexpected, run: ceo playbook scan\n`);
    }
  } catch (e) {
    deps.err(`registry error: ${e instanceof Error ? e.message : String(e)}\n`);
    return 1;
  }

  const enabled = loadEnabled(enabledPath(home), deps);

  const swP = swarmPath(vault);
  const owners = loadOwners(swP, deps);

  const hbP = heartbeatPath(home);
  const heartbeat = readHeartbeatFile(hbP);
  const hbState: HeartbeatState = !existsSync(hbP)
    ? "absent"
    : heartbeat === null
      ? "corrupt"
      : "ok";
  if (hbState === "corrupt") {
    deps.err(`warning: heartbeat file present but unparseable: ${hbP}\n`);
  }

  const report = computeStatus({
    jobs,
    host: cfg.host,
    enabled,
    owners,
    heartbeat,
    matcher: createMatcher(),
    now: deps.now(),
    options: {
      staleGraceMs: HEARTBEAT_STALE_MS,
      daemonHeartbeatStaleMs: HEARTBEAT_STALE_MS,
    },
  });

  render(sub, report, hbState, parsed, deps);

  // A projected fire time is a claim about a live scheduler, so next-runs owes the
  // same alert status does — it was reading the same daemonStale and saying nothing.
  if (report.daemonStale) {
    deps.err(`ALERT: daemon heartbeat stale (${fmtRelative(-report.heartbeatAgeMs!)}) on host=${report.host} — scheduler is not running.\n`);
    return STALE_EXIT_CODE;
  }
  return 0;
}

if (import.meta.main) {
  const rawArgs = process.argv.slice(2);
  let sub: StatusSubcommand = "status";
  let startIdx = 0;
  if (rawArgs[0] === "status" || rawArgs[0] === "next-runs") {
    sub = rawArgs[0] as StatusSubcommand;
    startIdx = 1;
  }
  const rc = runCeoStatusCommand(sub, rawArgs.slice(startIdx), {
    now: () => new Date(),
    out: (s) => process.stdout.write(s),
    err: (s) => process.stderr.write(s),
    env: process.env,
  });
  process.exit(rc);
}
