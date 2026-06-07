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

/**
 * Resolve the catch-up look-back from an optional env override
 * (`CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`), defaulting to {@link CATCHUP_LOOKBACK_MS}.
 * A non-numeric / zero / negative value falls back to the default rather than
 * silently installing a wrong window — a host with daily playbooks can raise it
 * (e.g. to several hours) without a registry/schema change. Per-playbook
 * look-back is the fuller fix, tracked separately.
 */
export function resolveCatchupLookbackMs(raw: string | undefined): number {
  if (raw === undefined) return CATCHUP_LOOKBACK_MS;
  const n = Number(raw.trim());
  return Number.isInteger(n) && n > 0 ? n : CATCHUP_LOOKBACK_MS;
}

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
