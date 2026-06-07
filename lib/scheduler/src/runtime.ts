/**
 * Real-environment helpers for ceo-schedulerd, kept pure so they are unit-tested
 * without touching the filesystem. `main.ts` composes them with Bun's spawn/fs.
 */

/** Cap on a single sleep: the loop re-reads the registry at least this often. */
export const MAX_SLEEP_MS = 60_000;

/**
 * How long without a heartbeat before `ceo doctor` reports the daemon stale.
 * Comfortably larger than {@link MAX_SLEEP_MS} so a single missed wake never
 * trips it. Keep in sync with the threshold in `ceo doctor` (scripts/ceo).
 */
export const HEARTBEAT_STALE_MS = 600_000; // 10 minutes

/**
 * Missed-slot catch-up look-back (#143). On wake after a downtime/suspend gap,
 * a missed slot older than this is too stale to replay. One hour: long enough to
 * cover a brief outage, short enough that an hours-old slot isn't run late.
 */
export const CATCHUP_LOOKBACK_MS = 3_600_000; // 1 hour

export function registryPath(vault: string): string {
  return `${vault}/CEO/registry.json`;
}

export function heartbeatPath(home: string): string {
  return `${home}/.ceo/schedulerd/heartbeat.json`;
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
