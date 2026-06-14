import { describe, expect, test } from "bun:test";
import { parseEnabled } from "@/enabled";

test("parses a string array into a Set", () => {
  const s = parseEnabled(JSON.stringify(["a", "b"]));
  expect(s).toEqual(new Set(["a", "b"]));
});

test("malformed or empty input yields an empty set (fail-safe: nothing enabled)", () => {
  expect(parseEnabled("{ partial")).toEqual(new Set());
  expect(parseEnabled("")).toEqual(new Set());
});

test("a non-array top-level yields an empty set", () => {
  expect(parseEnabled(JSON.stringify({ a: 1 }))).toEqual(new Set());
  expect(parseEnabled("42")).toEqual(new Set());
});

test("non-string and blank elements are dropped", () => {
  expect(parseEnabled(JSON.stringify(["ok", 3, "", null]))).toEqual(new Set(["ok"]));
});
