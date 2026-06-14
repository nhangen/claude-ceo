/**
 * Swarm reader for the ceo-schedulerd daemon.
 *
 * `$CEO_VAULT/CEO/swarm.json` holds the swarm topology (`hosts`) and per-playbook
 * owners for `scope: single` playbooks (`owners`). The file lives in a
 * Syncthing-synced vault, so a read can land on a half-written/partial file. This
 * is a pure parser (mirroring `parseRegistry`): it returns `null` on any malformed
 * input — never throws, never returns a half-parsed object — so the caller can fall
 * back to its last-good copy instead of acting on a torn read.
 */

export interface Swarm {
  hosts: string[];
  owners: Record<string, string>;
}

export function parseSwarm(text: string): Swarm | null {
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) return null;
  const d = doc as Record<string, unknown>;
  const hosts = Array.isArray(d.hosts)
    ? d.hosts.filter((h): h is string => typeof h === "string" && h.trim() !== "")
    : [];
  const ownersRaw =
    typeof d.owners === "object" && d.owners !== null && !Array.isArray(d.owners)
      ? (d.owners as Record<string, unknown>)
      : {};
  const owners: Record<string, string> = {};
  for (const [k, v] of Object.entries(ownersRaw)) {
    if (typeof v === "string" && v.trim() !== "") owners[k] = v;
  }
  return { hosts, owners };
}
