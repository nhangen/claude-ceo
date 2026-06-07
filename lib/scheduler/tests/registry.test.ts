import { describe, expect, test } from "bun:test";
import { parseRegistry, RegistryParseError } from "@/registry";

const ENTRY = {
  name: "morning-scan",
  description: "scan inbox",
  trigger: "cron",
  schedule: "50 8 * * 1-5",
  model: "mistral-small3.2:24b",
  tier: "read",
  status: "active",
  runner: "ollama",
  hosts: ["ml-1"],
  file: "playbooks/morning-scan.md",
};

const registry = (...playbooks: unknown[]) =>
  JSON.stringify({ schema_version: 3, generated: "2026-06-07T00:00:00Z", playbooks });

describe("parseRegistry", () => {
  test("maps the daemon-relevant fields from a well-formed entry", () => {
    const { playbooks, warnings } = parseRegistry(registry(ENTRY));
    expect(warnings).toEqual([]);
    expect(playbooks).toEqual([
      { name: "morning-scan", schedule: "50 8 * * 1-5", status: "active", trigger: "cron", hosts: ["ml-1"] },
    ]);
  });

  test("tolerates unknown extra fields", () => {
    const { playbooks } = parseRegistry(registry({ ...ENTRY, future_field: 42 }));
    expect(playbooks).toHaveLength(1);
    expect(playbooks[0]!.name).toBe("morning-scan");
  });

  test("missing playbooks key yields an empty list, no throw", () => {
    expect(parseRegistry(JSON.stringify({ schema_version: 3 }))).toEqual({ playbooks: [], warnings: [] });
  });

  test("throws RegistryParseError on invalid JSON (loop keeps last-good)", () => {
    expect(() => parseRegistry("{not json")).toThrow(RegistryParseError);
  });

  test("throws RegistryParseError when playbooks is not an array", () => {
    expect(() => parseRegistry(JSON.stringify({ playbooks: "nope" }))).toThrow(RegistryParseError);
  });

  test("skips an entry missing a required field, keeps the rest, and warns", () => {
    const noSchedule = { ...ENTRY, name: "broken" };
    delete (noSchedule as Record<string, unknown>).schedule;
    const { playbooks, warnings } = parseRegistry(registry(ENTRY, noSchedule));
    expect(playbooks.map((p) => p.name)).toEqual(["morning-scan"]);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("broken");
  });

  test("absent or null hosts normalizes to ['*']", () => {
    const noHosts = { ...ENTRY, name: "a" };
    delete (noHosts as Record<string, unknown>).hosts;
    const nullHosts = { ...ENTRY, name: "b", hosts: null };
    const { playbooks } = parseRegistry(registry(noHosts, nullHosts));
    expect(playbooks[0]!.hosts).toEqual(["*"]);
    expect(playbooks[1]!.hosts).toEqual(["*"]);
  });

  test("malformed hosts (scalar / empty / blank element) normalizes to ['*'] with a warning", () => {
    const scalar = { ...ENTRY, name: "s", hosts: "ml-1" };
    const empty = { ...ENTRY, name: "e", hosts: [] };
    const blank = { ...ENTRY, name: "k", hosts: ["ml-1", "  "] };
    const { playbooks, warnings } = parseRegistry(registry(scalar, empty, blank));
    expect(playbooks.map((p) => p.hosts)).toEqual([["*"], ["*"], ["*"]]);
    expect(warnings).toHaveLength(3);
  });
});
