/**
 * Real-environment helpers for ceo-schedulerd, kept pure so they are unit-tested
 * without touching the filesystem. `main.ts` composes them with Bun's spawn/fs.
 */

/**
 * How long without a heartbeat before `ceo doctor` reports the daemon stale.
 * Comfortably larger than {@link MAX_SLEEP_MS} so a single missed wake never
 * trips it. Keep in sync with the threshold in `ceo doctor` (scripts/ceo).
 */
export const HEARTBEAT_STALE_MS = 600_000; // 10 minutes

// Single source of truth — cronbird/core owns the wake cap and the catch-up
// look-back bounds. The daemon uses these exact values, so the staleness
// invariant (HEARTBEAT_STALE_MS >= 5 * MAX_SLEEP_MS) is checked against them.
export { MAX_SLEEP_MS, CATCHUP_LOOKBACK_FLOOR_MS, CATCHUP_LOOKBACK_CAP_MS } from "cronbird/core";

/**
 * Optional per-host override (`CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`) that pins a
 * single fixed look-back for every playbook, bypassing the per-schedule derived
 * default. Returns the parsed value when set to a positive integer, else `null`
 * — absent, non-numeric, zero, and negative all fall through to the derived
 * look-back rather than silently installing a wrong window. The env override
 * survives from #143 as an escape hatch; the derived default is the #157 fix.
 */
export function resolveFixedLookbackMs(raw: string | undefined): number | null {
  if (raw === undefined) return null;
  const n = Number(raw.trim());
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** Host-local — the registry is now generated per host under `~/.ceo`, not synced via the vault, so concurrent hosts no longer write-conflict on it. */
export function registryPath(home: string): string {
  return `${home}/.ceo/registry.json`;
}

export function swarmPath(vault: string): string {
  return `${vault}/CEO/swarm.json`;
}

export function enabledPath(home: string): string {
  return `${home}/.ceo/enabled.json`;
}

export function heartbeatPath(home: string): string {
  return `${home}/.ceo/schedulerd/heartbeat.json`;
}

/**
 * Synced per-host liveness heartbeat in the shared vault, namespaced by host so
 * two hosts never write the same file (no Syncthing conflict). Consumed by the
 * offline-owner alert (E2): a host whose synced heartbeat goes stale is
 * presumed offline and its single-scope playbooks unowned.
 */
export function syncedHeartbeatPath(vault: string, host: string): string {
  return `${vault}/CEO/heartbeats/${host}.json`;
}

export function resolveHost(env: { CEO_HOSTNAME?: string }, osHost: string): string {
  const override = env.CEO_HOSTNAME?.trim();
  return override ? override : osHost;
}

/**
 * Argv for one scheduled dispatch. Spawned without a shell (no `bash -lc`) so
 * there is no quoting/injection surface and no profile-sourcing surprise under
 * systemd; `CEO_VAULT`/`PATH` are passed via the spawn environment instead.
 */
export function dispatchArgv(cronBin: string, name: string): string[] {
  return [cronBin, name, "--scheduled"];
}
