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
    const { jobs, warnings } = parseRegistry(registry(ENTRY));
    expect(warnings).toEqual([]);
    expect(jobs).toEqual([
      {
        name: "morning-scan",
        cronSchedule: "50 8 * * 1-5",
        isActive: true,
        hosts: ["ml-1"],
        scope: "single",
        metadata: {
          trigger: "cron",
          model: "mistral-small3.2:24b",
          tier: "read",
          runner: "ollama",
          file: "playbooks/morning-scan.md",
          description: "scan inbox",
        },
      },
    ]);
  });

  test("projects scope, defaulting absent scope to 'single' (safe: off until owned)", () => {
    const { jobs, warnings } = parseRegistry(JSON.stringify({
      playbooks: [
        { name: "a", schedule: "0 9 * * *", status: "active", trigger: "cron", scope: "each" },
        { name: "b", schedule: "0 9 * * *", status: "active", trigger: "cron" },
      ],
    }));
    expect(jobs.map((p) => [p.name, p.scope])).toEqual([["a", "each"], ["b", "single"]]);
    expect(warnings).toHaveLength(0);
  });

  test("an unknown scope value skips the entry (no silent default)", () => {
    const { jobs, warnings } = parseRegistry(JSON.stringify({
      playbooks: [{ name: "bad", schedule: "0 9 * * *", status: "active", trigger: "cron", scope: "all" }],
    }));
    expect(jobs).toHaveLength(0);
    expect(warnings[0]).toContain("scope");
  });

  test("tolerates unknown extra fields", () => {
    const { jobs } = parseRegistry(registry({ ...ENTRY, future_field: 42 }));
    expect(jobs).toHaveLength(1);
    expect(jobs[0]!.name).toBe("morning-scan");
  });

  test("missing playbooks key yields an empty list, no throw", () => {
    expect(parseRegistry(JSON.stringify({ schema_version: 3 }))).toEqual({ jobs: [], warnings: [] });
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
    const { jobs, warnings } = parseRegistry(registry(ENTRY, noSchedule));
    expect(jobs.map((p) => p.name)).toEqual(["morning-scan"]);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("broken");
  });

  test("absent or null hosts normalizes to ['*']", () => {
    const noHosts = { ...ENTRY, name: "a" };
    delete (noHosts as Record<string, unknown>).hosts;
    const nullHosts = { ...ENTRY, name: "b", hosts: null };
    const { jobs } = parseRegistry(registry(noHosts, nullHosts));
    expect(jobs[0]!.hosts).toEqual(["*"]);
    expect(jobs[1]!.hosts).toEqual(["*"]);
  });

  test("malformed hosts (scalar / empty / blank element) normalizes to ['*'] with a warning", () => {
    const scalar = { ...ENTRY, name: "s", hosts: "ml-1" };
    const empty = { ...ENTRY, name: "e", hosts: [] };
    const blank = { ...ENTRY, name: "k", hosts: ["ml-1", "  "] };
    const { jobs, warnings } = parseRegistry(registry(scalar, empty, blank));
    expect(jobs.map((p) => p.hosts)).toEqual([["*"], ["*"], ["*"]]);
    expect(warnings).toHaveLength(3);
  });

  test("inactive status maps to isActive: false", () => {
    const { jobs } = parseRegistry(registry({ ...ENTRY, status: "draft" }));
    expect(jobs[0]!.isActive).toBe(false);
  });
});
