import { describe, expect, test } from "bun:test";
import { extractPathsAndSymbols } from "@/extract";

describe("extractPathsAndSymbols", () => {
  test("finds file paths with extensions", () => {
    const r = extractPathsAndSymbols("see src/foo/bar.ts and /abs/path/baz.php for details");
    expect(r.has("src/foo/bar.ts")).toBe(true);
    expect(r.has("/abs/path/baz.php")).toBe(true);
  });

  test("finds dotted symbol names", () => {
    const r = extractPathsAndSymbols("class AwesomeMotive\\OptinMonsterApp\\Util\\Stripe::refund() at line 42");
    expect(r.has("AwesomeMotive\\OptinMonsterApp\\Util\\Stripe")).toBe(true);
  });

  test("finds JSON-shaped path fields", () => {
    const json = JSON.stringify({ path: "src/cli.ts", calls: [{ symbol: "Foo::bar" }] });
    const r = extractPathsAndSymbols(json);
    expect(r.has("src/cli.ts")).toBe(true);
    expect(r.has("Foo::bar")).toBe(true);
  });

  test("ignores noise tokens", () => {
    const r = extractPathsAndSymbols("the result was OK. nothing here.");
    expect(r.size).toBe(0);
  });

  test("dedupes occurrences", () => {
    const r = extractPathsAndSymbols("src/cli.ts and src/cli.ts again");
    expect(r.size).toBe(1);
  });
});
