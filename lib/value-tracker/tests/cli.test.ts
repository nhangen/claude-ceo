import { describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import { join } from "path";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");

describe("cli", () => {
  test("--help prints usage and exits 0", () => {
    const r = spawnSync("bun", [CLI, "--help"], { encoding: "utf8" });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("value-tracker");
    expect(r.stdout).toContain("--since");
  });

  test("--dry-run on fixture file produces terminal output", () => {
    const fixture = join(import.meta.dir, "fixtures", "tiny-session.jsonl");
    const r = spawnSync("bun", [CLI, "--session-file", fixture, "--dry-run"], { encoding: "utf8" });
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("value-tracker");
    expect(r.stdout).toContain("decisionSupport");
  });
});
