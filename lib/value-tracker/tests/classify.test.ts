import { describe, expect, test } from "bun:test";
import { classifyCall } from "@/classify";
import type { ToolCall } from "@/types";

function call(p: Partial<ToolCall> & { turnIndex: number; toolName: string }): ToolCall {
  return {
    sessionId: "S",
    timestampMs: p.turnIndex * 1000,
    shortName: p.toolName.replace(/^mcp__gitnexus__/, ""),
    toolClass: "decisionSupport",
    input: p.input ?? {},
    resultText: p.resultText ?? "",
    resultIsError: p.resultIsError ?? false,
    resultTokens: p.resultTokens ?? Math.ceil((p.resultText ?? "").length / 4),
    msToNextTool: null,
    ...p,
  };
}

describe("classifyCall", () => {
  test("error result → trivially-wasted", () => {
    const calls = [call({ turnIndex: 0, toolName: "mcp__gitnexus__context", resultIsError: true })];
    const c = classifyCall(calls, 0);
    expect(c.bucket).toBe("trivially-wasted");
    expect(c.bucketReason).toBe("is_error");
  });

  test("empty result, no downstream evidence → trivially-wasted", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__query", resultText: "" }),
      call({ turnIndex: 1, toolName: "Read", input: { file: "unrelated.ts" } }),
    ];
    expect(classifyCall(calls, 0).bucket).toBe("trivially-wasted");
  });

  test("plausibly-used: result path appears in later tool input", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__context", resultText: "see src/foo.ts:12" }),
      call({ turnIndex: 1, toolName: "Edit", input: { file_path: "src/foo.ts" } }),
    ];
    const c = classifyCall(calls, 0);
    expect(c.bucket).toBe("plausibly-used");
    expect(c.evidenceTurnIndex).toBe(1);
  });

  test("evidence outside window → unclear", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__context", resultText: "see src/foo.ts" }),
      ...Array.from({ length: 11 }, (_, i) =>
        call({ turnIndex: i + 1, toolName: "Read", input: { file: "other.ts" } })),
      call({ turnIndex: 12, toolName: "Edit", input: { file_path: "src/foo.ts" } }),
    ];
    expect(classifyCall(calls, 0).bucket).toBe("unclear");
  });

  test("side-effecting tool: success → plausibly-used regardless of downstream", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__rename", toolClass: "sideEffecting", resultText: "renamed", resultIsError: false }),
    ];
    const c = classifyCall(calls, 0);
    expect(c.bucket).toBe("plausibly-used");
    expect(c.bucketReason).toBe("side-effect-success");
  });

  test("side-effecting tool: error → trivially-wasted", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__rename", toolClass: "sideEffecting", resultIsError: true }),
    ];
    expect(classifyCall(calls, 0).bucket).toBe("trivially-wasted");
  });

  test("maintenance tool: success → plausibly-used", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__analyze", toolClass: "maintenance", resultText: "indexed 1234 symbols" }),
    ];
    const c = classifyCall(calls, 0);
    expect(c.bucket).toBe("plausibly-used");
    expect(c.bucketReason).toBe("maintenance-success");
  });

  test("maintenance tool: error → trivially-wasted", () => {
    const calls = [
      call({ turnIndex: 0, toolName: "mcp__gitnexus__analyze", toolClass: "maintenance", resultIsError: true }),
    ];
    expect(classifyCall(calls, 0).bucket).toBe("trivially-wasted");
  });
});
