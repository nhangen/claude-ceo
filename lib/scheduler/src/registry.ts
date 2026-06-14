/**
 * Registry reader for the ceo-schedulerd daemon (#136 Phase 1.5).
 *
 * The on-disk registry (`$CEO_VAULT/CEO/registry.json`, schema v3) is written by
 * `ceo playbook scan`. This module projects each entry down to the fields the
 * daemon needs and normalizes `hosts` the same way the bash scanner does
 * (absent / null / malformed → `["*"]`). Entries missing a required field are
 * skipped with a warning rather than failing the whole load — one bad hand-edit
 * shouldn't take the scheduler down.
 */

/** A playbook projected to the fields the daemon's scheduling logic consumes. */
export interface Playbook {
  name: string;
  schedule: string;
  status: string;
  trigger: string;
  hosts: string[];
  scope: "each" | "single";
}

export interface ParsedRegistry {
  playbooks: Playbook[];
  warnings: string[];
}

/** Thrown when the registry text is unparseable or structurally wrong. */
export class RegistryParseError extends Error {
  constructor(message: string) {
    super(`invalid registry: ${message}`);
    this.name = "RegistryParseError";
  }
}

function normalizeHosts(raw: unknown, name: string, warnings: string[]): string[] {
  if (raw === undefined || raw === null) return ["*"];
  if (
    !Array.isArray(raw) ||
    raw.length === 0 ||
    !raw.every((h) => typeof h === "string" && h.trim() !== "")
  ) {
    warnings.push(`${name}: 'hosts' must be a non-empty array of host names — defaulting to ["*"]`);
    return ["*"];
  }
  return raw as string[];
}

function normalizeScope(raw: unknown, name: string, warnings: string[]): "each" | "single" | null {
  if (raw === undefined || raw === null) return "single";
  if (raw === "each" || raw === "single") return raw;
  warnings.push(`${name}: 'scope' must be 'each' or 'single' — entry skipped`);
  return null;
}

export function parseRegistry(text: string): ParsedRegistry {
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch (cause) {
    throw new RegistryParseError(cause instanceof Error ? cause.message : "JSON parse failed");
  }
  if (typeof doc !== "object" || doc === null) {
    throw new RegistryParseError("top-level value is not an object");
  }
  const rawPlaybooks = (doc as Record<string, unknown>).playbooks;
  if (rawPlaybooks === undefined) return { playbooks: [], warnings: [] };
  if (!Array.isArray(rawPlaybooks)) {
    throw new RegistryParseError("'playbooks' is not an array");
  }

  const playbooks: Playbook[] = [];
  const warnings: string[] = [];
  for (const entry of rawPlaybooks) {
    if (typeof entry !== "object" || entry === null) {
      warnings.push("skipped a non-object playbook entry");
      continue;
    }
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === "string" ? e.name : undefined;
    const label = name ?? "<unnamed>";
    if (
      name === undefined ||
      typeof e.schedule !== "string" ||
      typeof e.status !== "string" ||
      typeof e.trigger !== "string"
    ) {
      warnings.push(`${label}: missing a required field (name/schedule/status/trigger) — skipped`);
      continue;
    }
    const scope = normalizeScope(e.scope, name, warnings);
    if (scope === null) continue;
    playbooks.push({
      name,
      schedule: e.schedule,
      status: e.status,
      trigger: e.trigger,
      hosts: normalizeHosts(e.hosts, name, warnings),
      scope,
    });
  }
  return { playbooks, warnings };
}
