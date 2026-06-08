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
import { readFileSync } from "node:fs";
import { hostname } from "node:os";
import { createMatcher } from "@/cron";
import { type DaemonDeps, runForever } from "@/daemon";
import { readHeartbeatFile, writeHeartbeatFile } from "@/heartbeat-store";
import { parseRegistry } from "@/registry";
import { lookbackForSchedule } from "@/catchup";
import {
  CATCHUP_LOOKBACK_CAP_MS,
  CATCHUP_LOOKBACK_FLOOR_MS,
  dispatchArgv,
  heartbeatPath,
  MAX_SLEEP_MS,
  registryPath,
  resolveFixedLookbackMs,
  resolveHost,
} from "@/runtime";

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

async function main(): Promise<void> {
  const vault = requireEnv("CEO_VAULT");
  const home = requireEnv("HOME");
  const cronBin = process.env.CEO_CRON_BIN?.trim() || "ceo-cron.sh";
  const host = resolveHost({ CEO_HOSTNAME: process.env.CEO_HOSTNAME }, hostname().split(".")[0] ?? "unknown");
  const regPath = registryPath(vault);
  const hbPath = heartbeatPath(home);

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
    dispatch: (name) => {
      // Bun.spawn throws synchronously on e.g. ENOENT (cronBin not on PATH).
      // Swallow + log so one bad dispatch can't crash-loop the daemon; the
      // guard is already persisted, so this playbook is simply skipped this
      // minute and fires again at its next slot.
      try {
        const proc = Bun.spawn(dispatchArgv(cronBin, name), {
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
    writeHeartbeat: (hb) => writeHeartbeatFile(hbPath, hb),
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

main().catch((err) => {
  process.stderr.write(`[${nowStamp()}] ceo-schedulerd: fatal: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
