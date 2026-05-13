import type { RunSnapshot, SignalRow, ToolClass } from "@/types";

const CLASS_LABEL: Record<ToolClass, string> = {
  exploratory: "Exploratory tools",
  decisionSupport: "Decision-support tools",
  sideEffecting: "Side-effecting tools",
  maintenance: "Maintenance tools",
  meta: "Meta tools",
};

const CLASS_ORDER: ToolClass[] = ["exploratory", "decisionSupport", "sideEffecting", "maintenance", "meta"];

function pct(n: number): string {
  return `${(n * 100).toFixed(0)}%`;
}

function ms(n: number | null): string {
  return n === null ? "—" : `${(n / 1000).toFixed(1)}s`;
}

function rowLine(r: SignalRow): string {
  return [
    r.shortName.padEnd(16),
    String(r.calls).padStart(4),
    String(r.buckets["plausibly-used"]).padStart(5),
    String(r.buckets.unclear).padStart(5),
    String(r.buckets["trivially-wasted"]).padStart(5),
    pct(r.errorRate).padStart(5),
    pct(r.emptyRate).padStart(5),
    String(Math.round(r.meanResultTokens)).padStart(6),
    ms(r.meanMsToNextTool).padStart(6),
  ].join("  ");
}

const HEADER = ["tool".padEnd(16), "n".padStart(4), "used".padStart(5), "?".padStart(5), "waste".padStart(5),
                "err".padStart(5), "empty".padStart(5), "tokens".padStart(6), "next".padStart(6)].join("  ");

function emptyResultBanner(): string[] {
  return [
    "Note: this report covers Claude Code session JSONLs only.",
    "Cursor SQLite (cursorDiskKV bubbles), claude-mem observations, and",
    "non-Bash CLI usage are not yet ingested. A 0-call result here does",
    "not mean the server is unused — see",
    "docs/superpowers/findings/2026-05-10-v1-blind-spots.md.",
    "",
  ];
}

export function formatTerminal(s: RunSnapshot): string {
  const lines: string[] = [];
  lines.push(`mcp-value-tracker — ${s.serversAnalysed.join(", ")}`);
  lines.push(`window from ${new Date(s.windowSinceMs).toISOString().slice(0, 10)} | sessions: ${s.sessionCount} | calls: ${s.callCount}`);
  lines.push("");
  if (s.callCount === 0) {
    lines.push(...emptyResultBanner());
  }
  for (const klass of CLASS_ORDER) {
    const rows = s.rows.filter((r) => r.toolClass === klass);
    if (rows.length === 0) continue;
    lines.push(`[${CLASS_LABEL[klass]}] (${klass})`);
    lines.push(HEADER);
    for (const r of rows) lines.push(rowLine(r));
    lines.push("");
  }
  if (s.unclassifiedCalls > 0) {
    lines.push(`Unclassified MCP calls (other servers): ${s.unclassifiedCalls}`);
  }
  return lines.join("\n");
}

export function formatObsidian(s: RunSnapshot): string {
  const date = s.generatedAt.slice(0, 10);
  const lines: string[] = [];
  lines.push("---");
  lines.push(`date: ${date}`);
  lines.push(`tags: [mcp-value-tracker, ${s.serversAnalysed.join(", ")}]`);
  lines.push("---");
  lines.push("");
  lines.push(`# mcp-value-tracker — ${date}`);
  lines.push("");
  lines.push(`Window: from ${new Date(s.windowSinceMs).toISOString().slice(0, 10)}`);
  lines.push(`Sessions analysed: ${s.sessionCount}`);
  lines.push(`Total calls: ${s.callCount}`);
  lines.push("");
  if (s.callCount === 0) {
    lines.push(...emptyResultBanner());
  }
  for (const klass of CLASS_ORDER) {
    const rows = s.rows.filter((r) => r.toolClass === klass);
    if (rows.length === 0) continue;
    lines.push(`## ${CLASS_LABEL[klass]}`);
    lines.push("");
    lines.push("| tool | n | used | unclear | wasted | err | empty | tokens | next |");
    lines.push("|---|---:|---:|---:|---:|---:|---:|---:|---:|");
    for (const r of rows) {
      lines.push(`| ${r.shortName} | ${r.calls} | ${r.buckets["plausibly-used"]} | ${r.buckets.unclear} | ${r.buckets["trivially-wasted"]} | ${pct(r.errorRate)} | ${pct(r.emptyRate)} | ${Math.round(r.meanResultTokens)} | ${ms(r.meanMsToNextTool)} |`);
    }
    lines.push("");
  }
  if (s.unclassifiedCalls > 0) {
    lines.push(`Unclassified MCP calls (other servers): ${s.unclassifiedCalls}`);
    lines.push("");
  }
  return lines.join("\n");
}
