/**
 * Host-local enabled-playbook reader for the ceo-schedulerd daemon.
 *
 * `~/.ceo/enabled.json` is a plain JSON array of playbook names — the per-host
 * selection of which `scope: each` playbooks THIS machine runs (the analogue of
 * Claude's enabled-plugins list). It is host-local, not synced. This is a pure
 * parser (mirroring `parseSwarm` / `parseRegistry`): on any malformed or absent
 * input it returns an empty Set rather than throwing. The fail-safe direction is
 * deliberate — an unreadable host-local selection means "nothing enabled here",
 * never "run everything", so a torn or missing file can't accidentally promote
 * playbooks this host wasn't selected for.
 */

export function parseEnabled(text: string): Set<string> {
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch {
    return new Set();
  }
  if (!Array.isArray(doc)) return new Set();
  return new Set(doc.filter((x): x is string => typeof x === "string" && x.trim() !== ""));
}
