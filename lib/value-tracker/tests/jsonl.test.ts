import { describe, expect, test } from "bun:test";
import { readSession } from "@/jsonl";

describe("readSession", () => {
  test("parses tool_use+tool_result pairs in order", () => {
    const calls = readSession("tests/fixtures/tiny-session.jsonl");
    expect(calls.length).toBe(2);
    expect(calls[0]!.toolName).toBe("mcp__gitnexus__context");
    expect(calls[0]!.resultText).toBe("Foo lives in src/foo.ts:12");
    expect(calls[0]!.resultIsError).toBe(false);
    expect(calls[1]!.toolName).toBe("Edit");
    expect(calls[1]!.turnIndex).toBe(1);
  });

  test("computes msToNextTool", () => {
    const calls = readSession("tests/fixtures/tiny-session.jsonl");
    expect(calls[0]!.msToNextTool).toBe(10_000);
    expect(calls[1]!.msToNextTool).toBe(null);
  });
});
