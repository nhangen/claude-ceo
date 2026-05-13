import { describe, expect, test } from "bun:test";
import { formatTerminal, formatObsidian } from "@/format";
import type { RunSnapshot } from "@/types";

function snap(): RunSnapshot {
  return {
    schemaVersion: 1,
    generatedAt: "2026-05-09T12:00:00Z",
    windowSinceMs: Date.parse("2026-05-02T00:00:00Z"),
    serversAnalysed: ["gitnexus"],
    sessionCount: 3,
    callCount: 7,
    unclassifiedCalls: 0,
    rows: [
      {
        toolName: "mcp__gitnexus__context", shortName: "context", toolClass: "decisionSupport",
        calls: 5, errorRate: 0.2, emptyRate: 0.4, meanResultTokens: 120, meanMsToNextTool: 4500,
        buckets: { "trivially-wasted": 1, "plausibly-used": 3, "unclear": 1 },
      },
      {
        toolName: "mcp__gitnexus__cypher", shortName: "cypher", toolClass: "exploratory",
        calls: 2, errorRate: 0, emptyRate: 0, meanResultTokens: 800, meanMsToNextTool: 3000,
        buckets: { "trivially-wasted": 0, "plausibly-used": 1, "unclear": 1 },
      },
    ],
  };
}

describe("formatTerminal", () => {
  test("renders rows grouped by class", () => {
    const out = formatTerminal(snap());
    expect(out).toContain("exploratory");
    expect(out).toContain("decisionSupport");
    expect(out).toContain("context");
    expect(out).toContain("cypher");
    expect(out).toContain("3");  // plausibly-used count for context
  });
});

describe("formatObsidian", () => {
  test("emits markdown with frontmatter and headers", () => {
    const out = formatObsidian(snap());
    expect(out.startsWith("---\n")).toBe(true);
    expect(out).toContain("date: 2026-05-09");
    expect(out).toContain("## Decision-support tools");
    expect(out).toContain("| context |");
    expect(out).toContain("Sessions analysed: 3");
  });
});

describe("empty-result banner", () => {
  function emptySnap(): RunSnapshot {
    return {
      schemaVersion: 1,
      generatedAt: "2026-05-10T12:00:00Z",
      windowSinceMs: Date.parse("2026-05-09T00:00:00Z"),
      serversAnalysed: ["gitnexus"],
      sessionCount: 0,
      callCount: 0,
      unclassifiedCalls: 0,
      rows: [],
    };
  }

  test("formatTerminal includes the disclaimer when callCount is 0", () => {
    const out = formatTerminal(emptySnap());
    expect(out).toContain("Claude Code session JSONLs only");
    expect(out).toContain("Cursor SQLite");
    expect(out).toContain("v1-blind-spots");
  });

  test("formatObsidian includes the disclaimer when callCount is 0", () => {
    const out = formatObsidian(emptySnap());
    expect(out).toContain("Claude Code session JSONLs only");
    expect(out).toContain("v1-blind-spots");
  });

  test("non-empty snapshots do NOT include the disclaimer", () => {
    const out = formatTerminal(snap());
    expect(out).not.toContain("Claude Code session JSONLs only");
  });
});
