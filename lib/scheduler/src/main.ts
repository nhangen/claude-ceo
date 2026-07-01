#!/usr/bin/env bun
/**
 * ceo-schedulerd entrypoint (#142). Composition root: resolves the environment,
 * wires real clock / spawn / filesystem into the tested {@link runForever} loop,
 * and shuts down cleanly on SIGINT/SIGTERM. All scheduling logic lives in the
 * unit-tested modules; this file is intentionally thin.
 *
 * Required env: `CEO_VAULT` (registry root), `HOME` (heartbeat dir).
 * Optional env: `CEO_HOSTNAME` (host id override), `CEO_CRON_BIN` (dispatch
 * binary, default `ceo-cron.sh` on PATH).
 *
 * Schedules evaluate in the host's local timezone (the matcher is created with
 * no timezone, matching `new Date()`); registry schedules carry no per-entry tz.
 */
import { readFileSync, existsSync } from "node:fs";
import { hostname } from "node:os";
import {
  createMatcher,
  runForever,
  lookbackForSchedule,
  CATCHUP_LOOKBACK_FLOOR_MS,
  CATCHUP_LOOKBACK_CAP_MS,
  MAX_SLEEP_MS,
  type DaemonDeps,
} from "perch/core";
import {
  readHeartbeatFile,
  writeHeartbeatFile,
  writeHeartbeatWithSync,
  writeSyncedHeartbeat,
} from "perch/cli";
import { parseRegistry } from "@/registry";
import { parseEnabled } from "@/enabled";
import { parseSwarm } from "@/swarm";
import {
  dispatchArgv,
  enabledPath,
  heartbeatPath,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
  swarmPath,
  syncedHeartbeatPath,
} from "@/runtime";

/** The launchd service label — must never change (plist is not regenerated on update). */
const LAUNCHD_LABEL = "com.ceo.schedulerd";

export interface AdapterConfig {
  registryPath: string;
  heartbeatPath: string;
  swarmPath: string;
  syncedHeartbeatPath: string;
  /** Returns the argv for one scheduled dispatch given the playbook name. */
  dispatchArgv(name: string): string[];
  host: string;
  launchdLabel: string;
}

/**
 * Pure resolver for CEO's runtime paths, argv, host, and launchd label.
 * Exported for the adapter round-trip test; `main()` calls this with `process.env`.
 */
export function resolveAdapterConfig(env: {
  CEO_VAULT?: string;
  HOME?: string;
  CEO_HOSTNAME?: string;
  CEO_CRON_BIN?: string;
}): AdapterConfig {
  const vault = env.CEO_VAULT ?? "";
  const home = env.HOME ?? "";
  const cronBin = env.CEO_CRON_BIN?.trim() || "ceo-cron.sh";
  const host = resolveHost(
    { CEO_HOSTNAME: env.CEO_HOSTNAME },
    hostname().split(".")[0] ?? "unknown",
  );
  return {
    registryPath: registryPath(home),
    heartbeatPath: heartbeatPath(home),
    swarmPath: swarmPath(vault),
    syncedHeartbeatPath: syncedHeartbeatPath(vault, host),
    dispatchArgv: (name: string) => dispatchArgv(cronBin, name),
    host,
    launchdLabel: LAUNCHD_LABEL,
  };
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (v === undefined || v.trim() === "") {
    throw new Error(`${name} must be set before starting ceo-schedulerd`);
  }
  return v;
}

function nowStamp(): string {
  return new Date().toISOString();
}

/**
 * Read a file, or return "" if it is absent. A missing enabled.json/swarm.json
 * must be treated as a torn/empty read (the parsers fail safe on "") — never a
 * crash. The registry uses readFileSync directly because a missing registry is
 * a fatal misconfiguration the loop's last-good logic surfaces via its catch.
 */
function readIfExists(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

async function main(): Promise<void> {
  const vault = requireEnv("CEO_VAULT");
  const _ = requireEnv("HOME"); // validated; actual value comes via resolveAdapterConfig
  void _;
  const cfg = resolveAdapterConfig(process.env as Record<string, string | undefined>);

  const { registryPath: regPath, heartbeatPath: hbPath, swarmPath: swPath, syncedHeartbeatPath: syncedHbPath, host } = cfg;
  const enPath = enabledPath(requireEnv("HOME"));

  let running = true;
  let wakeEarly: (() => void) | null = null;
  const stop = (sig: string) => {
    process.stderr.write(`[${nowStamp()}] ceo-schedulerd: ${sig} received, shutting down\n`);
    running = false;
    wakeEarly?.();
  };
  process.on("SIGTERM", () => stop("SIGTERM"));
  process.on("SIGINT", () => stop("SIGINT"));

  const log = (msg: string) => process.stderr.write(`[${nowStamp()}] ceo-schedulerd: ${msg}\n`);

  // Per-schedule derived look-back (#157), unless the host pins a fixed window.
  const matcher = createMatcher();
  const fixedLookback = resolveFixedLookbackMs(process.env.CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS);
  const resolveLookback = (schedule: string, now: Date): number =>
    fixedLookback ?? lookbackForSchedule(schedule, now, matcher, CATCHUP_LOOKBACK_FLOOR_MS, CATCHUP_LOOKBACK_CAP_MS);

  const deps: DaemonDeps = {
    now: () => new Date(),
    sleep: (ms) =>
      new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          wakeEarly = null;
          resolve();
        }, ms);
        // A shutdown signal cancels the sleep so exit is prompt, not up to 60s late.
        wakeEarly = () => {
          clearTimeout(timer);
          wakeEarly = null;
          resolve();
        };
      }),
    loadRegistry: () => parseRegistry(readFileSync(regPath, "utf8")),
    loadEnabled: () => parseEnabled(readIfExists(enPath)),
    loadTopology: () => parseSwarm(readIfExists(swPath)),
    dispatch: (name) => {
      // Bun.spawn throws synchronously on e.g. ENOENT (cronBin not on PATH).
      // Swallow + log so one bad dispatch can't crash-loop the daemon; the
      // guard is already persisted, so this playbook is simply skipped this
      // minute and fires again at its next slot.
      try {
        const proc = Bun.spawn(cfg.dispatchArgv(name), {
          env: { ...process.env, CEO_VAULT: vault },
          stdout: "ignore",
          stderr: "ignore",
          stdin: "ignore",
        });
        proc.unref();
        log(`dispatched ${name}`);
      } catch (err) {
        log(`dispatch failed for ${name}: ${err instanceof Error ? err.message : String(err)}`);
      }
    },
    readHeartbeat: () => readHeartbeatFile(hbPath),
    writeHeartbeat: (hb) =>
      writeHeartbeatWithSync(hb, {
        writeLocal: (h) => writeHeartbeatFile(hbPath, h),
        writeSynced: () => writeSyncedHeartbeat(syncedHbPath, host),
        log,
      }),
    log,
    host,
    matcher,
    maxSleepMs: MAX_SLEEP_MS,
    resolveLookback,
    shouldContinue: () => running,
  };

  log(`started — host=${host} vault=${vault} registry=${regPath}`);
  await runForever(deps);
  log("stopped");
}

// Only run when invoked directly (not when imported by tests).
if (import.meta.main) {
  main().catch((err) => {
    process.stderr.write(`[${nowStamp()}] ceo-schedulerd: fatal: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
}
