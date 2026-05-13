import type { ServerSpec } from "@/types";

export const gitnexus: ServerSpec = {
  serverPrefix: "mcp__gitnexus__",
  partition: {
    exploratory:     ["query", "cypher"],
    decisionSupport: ["context", "impact", "route_map", "api_impact", "detect_changes", "shape_check", "tool_map"],
    sideEffecting:   ["rename", "group_sync"],
    maintenance:     ["analyze", "status", "clean", "index", "list", "wiki", "setup", "serve"],
    meta:            ["list_repos", "group_list"],
  },
  windowOverrides: { sideEffecting: 0, maintenance: 0 },
  cliBinary: "gitnexus",
};
