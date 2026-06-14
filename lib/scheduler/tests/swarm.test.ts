import { describe, expect, test } from "bun:test";
import { parseSwarm } from "@/swarm";

test("parses hosts and owners", () => {
  const s = parseSwarm(JSON.stringify({ schema_version: 1, hosts: ["ml-1","mac"], owners: { "morning-brief": "ml-1" } }))!;
  expect(s.owners["morning-brief"]).toBe("ml-1");
  expect(s.hosts).toEqual(["ml-1","mac"]);
});

test("a malformed/half-synced read yields null (caller keeps last-good)", () => {
  expect(parseSwarm("{ partial")).toBeNull();
  expect(parseSwarm("")).toBeNull();
});

test("a non-object top-level yields null", () => {
  expect(parseSwarm("[]")).toBeNull();
  expect(parseSwarm("42")).toBeNull();
});

test("missing owners/hosts normalize to empty", () => {
  const s = parseSwarm(JSON.stringify({ schema_version: 1 }))!;
  expect(s.owners).toEqual({});
  expect(s.hosts).toEqual([]);
});

test("non-string hosts and blank/non-string owner values are dropped", () => {
  const s = parseSwarm(JSON.stringify({ hosts: ["ok", 3, ""], owners: { a: "ml-1", b: "", c: 5 } }))!;
  expect(s.hosts).toEqual(["ok"]);
  expect(s.owners).toEqual({ a: "ml-1" });
});
