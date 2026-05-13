import { registry } from "@/servers";
import type { ServerSpec, ToolClass } from "@/types";

export interface CliMatch {
  serverPrefix: string;       // e.g. "mcp__gitnexus__"
  shortName: string;          // e.g. "analyze"
  toolClass: ToolClass;
  syntheticToolName: string;  // e.g. "cli__gitnexus__analyze"
}

const COMMAND_HEAD_RE = /(?:^|[\n;()]|&&|\|\||\|)\s*(?:[A-Z_][A-Z0-9_]*=\S+\s+)*"?([\w./-]+)"?\s+(\w[\w-]*)/g;

function lookupClass(spec: ServerSpec, shortName: string): ToolClass | null {
  for (const [klass, members] of Object.entries(spec.partition) as [ToolClass, string[]][]) {
    if (members.includes(shortName)) return klass;
  }
  return null;
}

export function detectCliInvocations(command: string): CliMatch[] {
  const out: CliMatch[] = [];
  if (!command) return out;
  const stripped = command.replace(/^\s*#.*$/gm, "");

  for (const spec of registry.values()) {
    if (!spec.cliBinary) continue;
    const binary = spec.cliBinary;
    for (const m of stripped.matchAll(COMMAND_HEAD_RE)) {
      const cmd = m[1] ?? "";
      const sub = m[2] ?? "";
      if (!cmd || !sub) continue;
      const isBinary = cmd === binary || cmd.endsWith(`/${binary}`);
      if (!isBinary) continue;
      const klass = lookupClass(spec, sub);
      if (!klass) continue;
      const serverName = spec.serverPrefix.replace(/^mcp__/, "").replace(/__$/, "");
      out.push({
        serverPrefix: spec.serverPrefix,
        shortName: sub,
        toolClass: klass,
        syntheticToolName: `cli__${serverName}__${sub}`,
      });
    }
  }
  return out;
}
