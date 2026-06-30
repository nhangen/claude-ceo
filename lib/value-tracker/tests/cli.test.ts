import { describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import { existsSync, mkdtempSync } from "fs";
import { tmpdir } from "os";
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

  test("--host suffixes the obsidian note filename; omitting it does not", () => {
    const fixture = join(import.meta.dir, "fixtures", "tiny-session.jsonl");
    const today = new Date().toISOString().slice(0, 10);

    const vaultWith = mkdtempSync(join(tmpdir(), "vt-host-"));
    const rWith = spawnSync(
      "bun",
      [CLI, "--session-file", fixture, "--obsidian-vault", vaultWith, "--host", "myhost", "--no-snapshot"],
      { encoding: "utf8" },
    );
    expect(rWith.status).toBe(0);
    expect(existsSync(join(vaultWith, "CEO", "reports", "value-tracker", `${today}-myhost.md`))).toBe(true);

    const vaultWithout = mkdtempSync(join(tmpdir(), "vt-nohost-"));
    spawnSync(
      "bun",
      [CLI, "--session-file", fixture, "--obsidian-vault", vaultWithout, "--no-snapshot"],
      { encoding: "utf8" },
    );
    expect(existsSync(join(vaultWithout, "CEO", "reports", "value-tracker", `${today}.md`))).toBe(true);
  });
});
