import { describe, expect, test } from "bun:test";
import { rollup } from "@/rollup";
import type { ClassifiedCall } from "@/types";

function cc(p: Partial<ClassifiedCall> & { toolName: string; bucket: ClassifiedCall["bucket"] }): ClassifiedCall {
  return {
    sessionId: "S",
    timestampMs: 0,
    turnIndex: 0,
    shortName: p.toolName.replace(/^mcp__gitnexus__/, ""),
    toolClass: p.toolClass ?? "decisionSupport",
    input: {},
    resultText: "",
    resultIsError: p.resultIsError ?? false,
    resultTokens: p.resultTokens ?? 0,
    msToNextTool: p.msToNextTool ?? 1000,
    bucketReason: "x",
    evidenceTurnIndex: null,
    ...p,
  };
}

describe("rollup", () => {
  test("counts buckets per tool, computes free signals", () => {
    const calls: ClassifiedCall[] = [
      cc({ toolName: "mcp__gitnexus__context", bucket: "plausibly-used", resultTokens: 200, msToNextTool: 5000 }),
      cc({ toolName: "mcp__gitnexus__context", bucket: "trivially-wasted", resultIsError: true, resultTokens: 0 }),
      cc({ toolName: "mcp__gitnexus__context", bucket: "unclear", resultTokens: 100 }),
      cc({ toolName: "mcp__gitnexus__cypher", bucket: "trivially-wasted", resultTokens: 10, toolClass: "exploratory" }),
    ];
    const rows = rollup(calls);
    const ctx = rows.find((r) => r.toolName === "mcp__gitnexus__context")!;
    expect(ctx.calls).toBe(3);
    expect(ctx.errorRate).toBeCloseTo(1 / 3);
    expect(ctx.buckets["plausibly-used"]).toBe(1);
    expect(ctx.buckets["trivially-wasted"]).toBe(1);
    expect(ctx.buckets.unclear).toBe(1);
    expect(ctx.meanResultTokens).toBeCloseTo(100);
    const cyph = rows.find((r) => r.toolName === "mcp__gitnexus__cypher")!;
    expect(cyph.toolClass).toBe("exploratory");
  });

  test("emptyRate counts results below 50 tokens", () => {
    const calls: ClassifiedCall[] = [
      cc({ toolName: "mcp__gitnexus__context", bucket: "unclear", resultTokens: 10 }),
      cc({ toolName: "mcp__gitnexus__context", bucket: "plausibly-used", resultTokens: 200 }),
    ];
    const r = rollup(calls)[0]!;
    expect(r.emptyRate).toBe(0.5);
  });
});
