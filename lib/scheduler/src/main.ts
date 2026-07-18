#!/usr/bin/env bun
/**
 * ceo-schedulerd entrypoint (#142). Composition root: resolves the environment,
 * wires real clock / spawn / filesystem into the tested {@link runForever} loop,
 * and shuts down cleanly on SIGINT/SIGTERM. All scheduling logic lives in the
 * unit-tested modules; this file is intentionally thin.
 *
 * Required env: `CEO_VAULT` (swarm.json + synced-heartbeat root), `HOME`
 * (host-local registry `~/.ceo/registry.json` + local heartbeat dir).
 * Optional env: `CEO_HOSTNAME` (host id override), `CEO_CRON_BIN` (dispatch
 * binary, default `ceo-cron.sh` on PATH).
 *
 * Schedules evaluate in the host's local timezone (the matcher is created with
 * no timezone, matching `new Date()`); registry schedules carry no per-entry tz.
 */
import { readFileSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import {
  createMatcher,
  runForever,
  lookbackForSchedule,
  CATCHUP_LOOKBACK_FLOOR_MS,
  CATCHUP_LOOKBACK_CAP_MS,
  MAX_SLEEP_MS,
  type DaemonDeps,
} from "cronbird/core";
import {
  readHeartbeatFile,
  writeHeartbeatFile,
  writeHeartbeatWithSync,
  writeSyncedHeartbeat,
} from "cronbird/cli";
import { parseRegistry } from "@/registry";
import { parseEnabled } from "@/enabled";
import { parseSwarm } from "@/swarm";
import {
  buildCompletions,
  completionRecord,
  dispatchArgv,
  doneDir,
  enabledPath,
  heartbeatPath,
  isSafeSegment,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
  runningDir,
  runningMarker,
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

/**
 * Read every file in a run-state dir as {basename: contents}; {} when the dir is
 * absent. A file that vanishes between listing and read (a completion cleared its
 * running marker mid-scan) is skipped — fail-safe, matching cronbird's torn-read
 * contract for `readCompletions`.
 */
function readStateDir(dir: string): Record<string, string> {
  if (!existsSync(dir)) return {};
  const out: Record<string, string> = {};
  for (const name of readdirSync(dir)) {
    if (!isSafeSegment(name)) continue; // defensive: never read a name we'd refuse to write
    try {
      out[name] = readFileSync(`${dir}/${name}`, "utf8");
    } catch {
      // entry removed between readdir and read — treat as absent
    }
  }
  return out;
}

/** Is a process alive? `kill(pid, 0)` probes without signalling; ESRCH ⇒ gone. */
function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function main(): Promise<void> {
  const vault = requireEnv("CEO_VAULT");
  const home = requireEnv("HOME");
  const cfg = resolveAdapterConfig(process.env as Record<string, string | undefined>);

  const { registryPath: regPath, heartbeatPath: hbPath, swarmPath: swPath, syncedHeartbeatPath: syncedHbPath, host } = cfg;
  const enPath = enabledPath(home);
  // Dispatch-completion state (cronbird #9 queue): the dispatch wrapper below
  // writes running/done here; readCompletions reassembles it each tick.
  const runDir = runningDir(home);
  const dDir = doneDir(home);
  mkdirSync(runDir, { recursive: true });
  mkdirSync(dDir, { recursive: true });

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
      // A job name is used as a run-state filename; refuse anything that isn't a
      // single safe path segment rather than write outside the run-state dir.
      if (!isSafeSegment(name)) {
        log(`refusing to dispatch unsafe job name: ${JSON.stringify(name)}`);
        return;
      }
      const startedTs = Date.now();
      const runMarker = `${runDir}/${name}`;
      const clearRunning = () => {
        try {
          rmSync(runMarker, { force: true });
        } catch {
          // already gone
        }
      };
      try {
        // Mark in-flight BEFORE spawn so a completion can never race ahead of it.
        writeFileSync(runMarker, runningMarker(startedTs));
        const proc = Bun.spawn(cfg.dispatchArgv(name), {
          env: { ...process.env, CEO_VAULT: vault },
          stdout: "ignore",
          stderr: "ignore",
          stdin: "ignore",
        });
        proc.unref();
        // Rewrite with the PID now that it's known, so a crashed daemon's orphaned
        // marker is dropped by liveness (dead PID) instead of stalling the queue
        // for RUN_STATE_STALE_MS.
        writeFileSync(runMarker, runningMarker(startedTs, proc.pid));
        log(`dispatched ${name}`);
        // Record completion so cronbird's queue advances (the MAX_CONCURRENT=1
        // gate drains the next job only once this one is observed done). Runs on
        // the daemon's own event loop, so it never races readCompletions.
        void proc.exited
          .then((exitCode) => {
            writeFileSync(`${dDir}/${name}`, JSON.stringify(completionRecord(startedTs, Date.now(), exitCode)));
            clearRunning();
          })
          .catch((err) => {
            // Exit tracking itself failed: record a failure and clear the marker
            // so an unobservable run can never wedge the queue.
            writeFileSync(`${dDir}/${name}`, JSON.stringify(completionRecord(startedTs, Date.now(), 1)));
            clearRunning();
            log(`completion tracking failed for ${name}: ${err instanceof Error ? err.message : String(err)}`);
          });
      } catch (err) {
        clearRunning(); // spawn failed at start — don't leave a phantom in-flight marker
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
    // cronbird #9 queue inputs. CEO wires no priority / dependency / cooldown
    // source yet, so these are the documented defaults: all-equal FIFO ordering,
    // no upstreams (the dependency gate is a no-op), no cooldown. Wiring real
    // resolvers from registry metadata is a later, deliberate step.
    priority: () => 0,
    dependencies: () => [],
    cooldownSeconds: () => 0,
    // Real run-state read — the dispatch wrapper above writes running/done, so
    // the loop observes completions and drains the queue instead of stranding
    // every job behind the first (which would silently drop same-minute
    // collisions like morning + morning-brief at 03:20).
    readCompletions: () => buildCompletions(readStateDir(runDir), readStateDir(dDir), Date.now(), { isAlive: pidAlive }),
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
