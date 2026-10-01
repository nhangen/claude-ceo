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
import { readFileSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { hostname } from "node:os";
import {
  createMatcher,
  runForever,
  lookbackForSchedule,
  CATCHUP_LOOKBACK_FLOOR_MS,
  CATCHUP_LOOKBACK_CAP_MS,
  MAX_SLEEP_MS,
  FATAL_EXIT_CODE,
  type DaemonDeps,
  type Heartbeat,
} from "cronbird/core";
import {
  readHeartbeatFile,
  writeHeartbeatFile,
  writeHeartbeatWithSync,
  writeSyncedHeartbeat,
  PermanentHeartbeatWriteError,
  isPermanentLocalWriteError,
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
  parseCooldownSeconds,
  registryPath,
  resolveCooldownSeconds,
  resolveFixedLookbackMs,
  resolveHost,
  runningDir,
  resolveAdapterConfig,
  runningMarker,
  settingsPath,
  swarmPath,
  syncedHeartbeatPath,
} from "@/runtime";

const NORX_BOOKKEEPING = "norx-bookkeeping";
// Mirrors cronbird MAX_ATTEMPTS; update this adapter alongside any retry-policy change.
const MAX_ATTEMPTS = 3;

export class SchedulerDispatchContext {
  private persistedHeartbeat: Heartbeat | null = null;

  retain(heartbeat: Heartbeat): void {
    this.persistedHeartbeat = heartbeat;
  }

  persist(heartbeat: Heartbeat, write: () => void): void {
    write();
    this.retain(heartbeat);
  }

  envFor(name: string, inheritedEnv: NodeJS.ProcessEnv): NodeJS.ProcessEnv | null {
    const env = { ...inheritedEnv };
    delete env.CEO_SCHEDULER_ATTEMPT;
    delete env.CEO_SCHEDULER_MAX_ATTEMPTS;

    if (name !== NORX_BOOKKEEPING) return env;

    const persistedAttempt = this.persistedHeartbeat?.attempts[name];
    if (
      typeof persistedAttempt !== "number" ||
      !Number.isInteger(persistedAttempt) ||
      persistedAttempt < 0 ||
      persistedAttempt >= MAX_ATTEMPTS
    ) {
      return null;
    }

    env.CEO_SCHEDULER_ATTEMPT = String(persistedAttempt + 1);
    env.CEO_SCHEDULER_MAX_ATTEMPTS = String(MAX_ATTEMPTS);
    return env;
  }
}

export { resolveAdapterConfig, LAUNCHD_LABEL, type AdapterConfig } from "@/runtime";

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
export function readStateDir(dir: string): Record<string, string> {
  if (!existsSync(dir)) return {};
  const out: Record<string, string> = {};
  for (const name of readdirSync(dir)) {
    if (!isSafeSegment(name)) continue; // defensive: never read a name we'd refuse to write
    // A tempfile left by a daemon that died between write and rename is not a
    // record; read as one it would be a phantom completion or in-flight job.
    if (name.includes(ATOMIC_TMP_INFIX)) continue;
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

  const { registryPath: regPath, heartbeatPath: hbPath, swarmPath: swPath, syncedHeartbeatPath: syncedHbPath, schedulerdAlertPath: alertPath, host } = cfg;
  const enPath = enabledPath(home);
  const setPath = settingsPath(vault);
  // Dispatch-completion state (cronbird #9 queue): the dispatch wrapper below
  // writes running/done here; readCompletions reassembles it each tick.
  const runDir = runningDir(home);
  const dDir = doneDir(home);
  // On a fresh host these are the daemon's first writes under ~/.ceo/schedulerd,
  // so a permanent fault here must exit 78 like the heartbeat write would (#496).
  try {
    mkdirSync(runDir, { recursive: true });
    mkdirSync(dDir, { recursive: true });
  } catch (err) {
    if (isPermanentLocalWriteError(err)) throw new PermanentHeartbeatWriteError(err as NodeJS.ErrnoException);
    throw err;
  }

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
  const dispatchContext = new SchedulerDispatchContext();

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
    dispatch: createJobDispatcher({
      runDir,
      dDir,
      vault,
      dispatchContext,
      dispatchArgv: cfg.dispatchArgv,
      log,
    }),
    readHeartbeat: () => readHeartbeatFile(hbPath),
    writeHeartbeat: (hb) =>
      dispatchContext.persist(hb, () => {
        writeHeartbeatWithSync(hb, {
          writeLocal: (h) => writeHeartbeatFile(hbPath, h),
          writeSynced: () => writeSyncedHeartbeat(syncedHbPath, host),
          log,
        });
        clearSchedulerdAlertOrLog(alertPath, host, new Date(), log);
      }),
    log,
    host,
    matcher,
    maxSleepMs: MAX_SLEEP_MS,
    resolveLookback,
    shouldContinue: () => running,
    // cronbird #9 queue inputs, resolved in #300.
    //
    // priority: all-equal FIFO, deliberately. Ordering only matters for jobs due
    // in the same minute, and the queue *drains* rather than dropping, so a tie
    // costs sequencing, not a run. The one same-minute pair in the registry
    // (morning + morning-brief) is both-disabled and produces independent notes.
    //
    // dependencies: none exist. Audited every playbook in docs/playbooks: each
    // one writes its own artifact and no one reads another's — the only
    // cross-references are each playbook's own report dir. What look like
    // upstreams are not: the `inputs:` frontmatter names data ceo-gather.sh
    // collects live from git/gh/the vault, not another playbook's output, and
    // value-tracker (06:00) reads nothing from token-intake (08:45) — it would
    // already be ordered wrong if it did. cron-failure-digest is the interesting
    // case and argues the other way: it reads log/cron-runs-<host>.log, so gating it on
    // its "upstreams" succeeding would suppress exactly the digest of their
    // failures. So the dependency gate stays a no-op by decision, not by
    // omission; revisit only when a playbook genuinely consumes another's file.
    priority: () => 0,
    dependencies: () => [],
    // cooldown: cronbird owns this gate, per its own contract — "a job is never
    // dispatched into a downstream cooldown-skip that would look like a clean
    // success". ceo-cron.sh used to enforce it too, and its skip path exits 0,
    // which cronbird reads as success: attempt counter reset, lastSuccess
    // stamped. That is what let a failing playbook's retry launder itself into a
    // daemon-level success (#298), and why ceo-cron.sh now defers the gate to us
    // on --scheduled runs. Settings are re-read per resolver call so a
    // cooldown_seconds edit lands without a daemon restart, matching how the
    // registry, enabled set, and topology are already re-read each tick.
    cooldownSeconds: (job) =>
      resolveCooldownSeconds(
        parseCooldownSeconds(readIfExists(setPath)),
        job.cronSchedule,
        new Date(),
        matcher,
      ),
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

const errText = (err: unknown): string => (err instanceof Error ? err.message : String(err));

/**
 * Removes the running marker file for a job.
 * rmSync with force: true suppresses ENOENT; any non-ENOENT error (EACCES, EROFS)
 * is logged so operators know if permissions or read-only filesystems prevented
 * marker removal (#586).
 */
export function createClearRunning(runMarker: string, log: (msg: string) => void): () => void {
  return () => {
    try {
      rmSync(runMarker, { force: true });
    } catch (err) {
      const code = (err as NodeJS.ErrnoException)?.code;
      if (code !== "ENOENT") {
        log(`failed to clear running marker ${runMarker}: ${errText(err)}`);
      }
    }
  };
}

export const ATOMIC_TMP_INFIX = ".tmp.";

/**
 * Replaces `dest` via a same-directory tempfile + rename, so an ENOSPC/IO fault
 * mid-write leaves the previous contents in place rather than a truncated file.
 * Both run-state writers need that: a torn done record loses cronbird's cooldown,
 * and a torn running marker parses as "not running" and reopens the
 * MAX_CONCURRENT=1 gate while the child is still alive (#586). Any torn tempfile
 * is removed before rethrowing. `rawWrite` is the seam tests fail at.
 */
export function writeFileAtomic(
  dest: string,
  body: string,
  rawWrite: (path: string, content: string) => void = writeFileSync,
): void {
  const rand = Math.random().toString(36).slice(2, 8);
  const tmp = `${dest}${ATOMIC_TMP_INFIX}${process.pid}.${Date.now()}.${rand}`;
  try {
    rawWrite(tmp, body);
    renameSync(tmp, dest);
  } catch (err) {
    try {
      rmSync(tmp, { force: true });
    } catch {
      // ignore secondary error on cleanup
    }
    throw err;
  }
}

export function writeDoneRecordAtomic(
  dDir: string,
  name: string,
  startedTs: number,
  endedTs: number,
  exitCode: number,
  rawWrite?: (path: string, content: string) => void,
): void {
  writeFileAtomic(`${dDir}/${name}`, JSON.stringify(completionRecord(startedTs, endedTs, exitCode)), rawWrite);
}

export interface JobDispatcherDeps {
  runDir: string;
  dDir: string;
  vault: string;
  dispatchContext: SchedulerDispatchContext;
  dispatchArgv: (name: string) => string[];
  log: (msg: string) => void;
  spawn?: typeof Bun.spawn;
  rawWrite?: (path: string, content: string) => void;
  now?: () => number;
}

export function createJobDispatcher(deps: JobDispatcherDeps): (name: string) => void {
  const {
    runDir,
    dDir,
    vault,
    dispatchContext,
    dispatchArgv,
    log,
    spawn = Bun.spawn,
    rawWrite = writeFileSync,
    now = Date.now,
  } = deps;
  const writeRunningMarker = (path: string, content: string) => writeFileAtomic(path, content, rawWrite);

  return (name: string) => {
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
    const dispatchEnv = dispatchContext.envFor(name, process.env);
    if (dispatchEnv === null) {
      log(`refusing to dispatch ${name}: persisted retry attempt is missing or invalid`);
      return;
    }
    const startedTs = now();
    const runMarker = `${runDir}/${name}`;
    const clearRunning = createClearRunning(runMarker, log);

    try {
      // Mark in-flight BEFORE spawn so a completion can never race ahead of it.
      writeRunningMarker(runMarker, runningMarker(startedTs));
      const proc = spawn(dispatchArgv(name), {
        env: { ...dispatchEnv, CEO_VAULT: vault },
        stdout: "ignore",
        stderr: "ignore",
        stdin: "ignore",
      });
      proc.unref();

      // Record completion so cronbird's queue advances (the MAX_CONCURRENT=1
      // gate drains the next job only once this one is observed done). Runs on
      // the daemon's own event loop, so it never races readCompletions.
      // Attached immediately after spawn/unref so a PID-rewrite failure never leaves
      // the running child untracked (#586).
      void trackCompletion(
        name,
        proc.exited,
        (exitCode) => writeDoneRecordAtomic(dDir, name, startedTs, now(), exitCode, rawWrite),
        clearRunning,
        log,
      );

      // Rewrite with the PID now that it's known, so a crashed daemon's orphaned
      // marker is dropped by liveness (dead PID) instead of stalling the queue
      // for RUN_STATE_STALE_MS. Isolated in its own try/catch so a write failure
      // here does not clear the run marker or drop completion tracking (#586).
      try {
        writeRunningMarker(runMarker, runningMarker(startedTs, proc.pid));
      } catch (pidErr) {
        log(`could not record PID ${proc.pid} in ${runMarker}: ${errText(pidErr)}`);
      }
      log(`dispatched ${name}`);
    } catch (err) {
      clearRunning(); // spawn failed at start — don't leave a phantom in-flight marker
      log(`dispatch failed for ${name}: ${errText(err)}`);
    }
  };
}

/**
 * Settles on every path, including completion writes that throw (ENOSPC or
 * EROFS between ticks), so the voided promise never becomes an unhandled
 * rejection that kills the daemon with exit 1 (#563). The run marker is always
 * cleared. A failed write of a known exit code is logged with that code rather
 * than recorded as exit 1, since cronbird would re-run a job that succeeded.
 */
export async function trackCompletion(
  name: string,
  exited: Promise<number>,
  writeCompletion: (exitCode: number) => void,
  clearRunning: () => void,
  log: (msg: string) => void,
): Promise<void> {
  let exitCode: number;
  try {
    exitCode = await exited;
  } catch (err) {
    clearRunning();
    log(`completion tracking failed for ${name}: ${errText(err)}`);
    try {
      writeCompletion(1);
    } catch (writeErr) {
      log(`could not record the failed completion for ${name}: ${errText(writeErr)}`);
    }
    return;
  }
  try {
    writeCompletion(exitCode);
  } catch (writeErr) {
    log(`could not record exit ${exitCode} for ${name}: ${errText(writeErr)}`);
  } finally {
    clearRunning();
  }
}

/**
 * A permanent local-write fault (cronbird's isPermanentLocalWriteError set) exits
 * FATAL_EXIT_CODE (78, EX_CONFIG); anything else exits 1 (#496). systemd stops on
 * it via RestartPreventExitStatus=78. launchd has no per-exit-code KeepAlive, so
 * it keeps respawning (throttled) but logs the exit as EX_CONFIG.
 */
export function resolveFatalExitCode(err: unknown): number {
  return err instanceof PermanentHeartbeatWriteError ? FATAL_EXIT_CODE : 1;
}

/**
 * Marks this host's synced heartbeat with the fault a permanent-write exit hit,
 * so a peer's owners-health reaches the operator: launchd respawns an exit-78
 * daemon forever and only the unified log says why (#562). The local and synced
 * heartbeats are separate paths, so this usually still lands. The last good `ts`
 * is kept, so the respawn loop never makes the host look alive, and an unchanged
 * code is not rewritten, so the loop does not churn Syncthing. The next healthy
 * heartbeat overwrites the whole file and drops the field. The {host, ts} shape
 * and the tmp-then-rename write mirror cronbird's writeSyncedHeartbeat; keep
 * them in step if that format changes.
 */
export function recordFatalInSyncedHeartbeat(
  path: string,
  host: string,
  code: string,
  now: Date,
): "written" | "unchanged" {
  let prevTs: string | null = null;
  try {
    const prev = JSON.parse(readFileSync(path, "utf8"));
    if (typeof prev?.ts === "string") prevTs = prev.ts;
    if (prev?.fatal?.code === code) return "unchanged";
  } catch {
    // No prior heartbeat, or an unreadable one: record the fault with no ts.
  }
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify({ host, ts: prevTs, fatal: { code, since: now.toISOString() } }, null, 2));
  renameSync(tmp, path);
  return "written";
}

/**
 * Reads a frontmatter field from YAML-frontmatter markdown content.
 * Restricts matching to between the opening and closing `---` markers.
 */
export function parseAlertField(content: string, field: string): string | null {
  const fmMatch = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  const fmBody = fmMatch?.[1];
  if (!fmBody) return null;
  const match = fmBody.match(new RegExp(`^${field}:[ \t]*(.*)$`, "m"));
  const value = match?.[1];
  return value !== undefined ? value.trim() : null;
}

export function formatSchedulerdAlert(
  host: string,
  status: "firing" | "clear",
  since: string,
  lastCheck: string,
  code?: string,
): string {
  const lines = [
    "---",
    `status: ${status}`,
    `since: ${since}`,
    `last_check: ${lastCheck}`,
    `host: ${host}`,
  ];
  if (status === "firing" && code) {
    lines.push(`code: ${code}`);
  }
  lines.push("---", "", `# Scheduler Alert — ${host}`, "");
  if (status === "firing") {
    lines.push(`ceo-schedulerd stopped on a permanent local-write fault (code: ${code || "unknown"}).`);
  } else {
    lines.push("ceo-schedulerd is running normally.");
  }
  lines.push("");
  return lines.join("\n");
}

/**
 * Writes CEO/alerts/schedulerd-<host>.md on fatal exit (status: firing).
 * If the alert is already firing with the same code, returns "unchanged" without
 * rewriting to prevent Syncthing churn during a launchd respawn loop (#589). A new
 * code is rewritten so the alert agrees with the synced heartbeat.
 */
export function recordFatalSchedulerdAlert(
  path: string,
  host: string,
  code: string,
  now: Date,
): "written" | "unchanged" {
  try {
    const prev = readFileSync(path, "utf8");
    if (parseAlertField(prev, "status") === "firing" && parseAlertField(prev, "code") === code) return "unchanged";
  } catch {
    // No prior alert file or unreadable: record the fault.
  }
  mkdirSync(dirname(path), { recursive: true });
  const iso = now.toISOString();
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, formatSchedulerdAlert(host, "firing", iso, iso, code), "utf8");
  renameSync(tmp, path);
  return "written";
}

/**
 * Resets CEO/alerts/schedulerd-<host>.md to status: clear after a successful
 * local heartbeat write (#589). The synced write's failure is logged but not
 * propagated by cronbird, so clear does not imply the synced heartbeat is fresh.
 * A missing file or one already clear returns "unchanged"; any other read
 * error is thrown so the caller can log it rather than leave the alert firing.
 */
export function clearSchedulerdAlert(
  path: string,
  host: string,
  now: Date,
): "written" | "unchanged" {
  try {
    const prev = readFileSync(path, "utf8");
    if (parseAlertField(prev, "status") === "clear") return "unchanged";
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === "ENOENT") return "unchanged";
    throw err;
  }
  mkdirSync(dirname(path), { recursive: true });
  const iso = now.toISOString();
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, formatSchedulerdAlert(host, "clear", iso, iso), "utf8");
  renameSync(tmp, path);
  return "written";
}

/**
 * Clears the alert from the heartbeat path without letting a failure escape:
 * a throw there would skip the retry-state retain and take down a daemon whose
 * local heartbeat is healthy.
 */
export function clearSchedulerdAlertOrLog(
  path: string,
  host: string,
  now: Date,
  log: (msg: string) => void,
): void {
  try {
    clearSchedulerdAlert(path, host, now);
  } catch (err) {
    log(`could not clear schedulerd alert: ${errText(err)}`);
  }
}

// Only run when invoked directly (not when imported by tests).
if (import.meta.main) {
  main().catch((err) => {
    process.stderr.write(`[${nowStamp()}] ceo-schedulerd: fatal: ${errText(err)}\n`);
    if (err instanceof PermanentHeartbeatWriteError) {
      try {
        const { syncedHeartbeatPath: path, host } = resolveAdapterConfig(process.env as Record<string, string | undefined>);
        recordFatalInSyncedHeartbeat(path, host, err.code || "unknown", new Date());
      } catch (markErr) {
        process.stderr.write(`[${nowStamp()}] ceo-schedulerd: could not mark the synced heartbeat fatal: ${errText(markErr)}\n`);
      }
      try {
        const { schedulerdAlertPath: alertPath, host } = resolveAdapterConfig(process.env as Record<string, string | undefined>);
        recordFatalSchedulerdAlert(alertPath, host, err.code || "unknown", new Date());
      } catch (alertErr) {
        process.stderr.write(`[${nowStamp()}] ceo-schedulerd: could not write fallback alert: ${errText(alertErr)}\n`);
      }
    }
    process.exit(resolveFatalExitCode(err));
  });
}
