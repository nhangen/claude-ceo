import type { ServerSpec, ToolClass } from "@/types";
import { gitnexus } from "@/servers/gitnexus";

export const registry: Map<string, ServerSpec> = new Map([
  [gitnexus.serverPrefix, gitnexus],
]);

export function resolveServer(toolName: string): ServerSpec | null {
  for (const spec of registry.values()) {
    if (toolName.startsWith(spec.serverPrefix)) return spec;
    const cliPrefix = "cli__" + spec.serverPrefix.replace(/^mcp__/, "");
    if (toolName.startsWith(cliPrefix)) return spec;
  }
  return null;
}

export function classifyTool(toolName: string): { shortName: string; toolClass: ToolClass } | null {
  const spec = resolveServer(toolName);
  if (!spec) return null;
  const shortName = toolName.slice(spec.serverPrefix.length);
  for (const [klass, members] of Object.entries(spec.partition) as [ToolClass, string[]][]) {
    if (members.includes(shortName)) return { shortName, toolClass: klass };
  }
  return { shortName, toolClass: "meta" };
}
