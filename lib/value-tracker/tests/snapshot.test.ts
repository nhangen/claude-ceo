import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { writeSnapshot } from "@/snapshot";
import type { RunSnapshot } from "@/types";

describe("writeSnapshot", () => {
  test("writes JSON and returns path", () => {
    const dir = mkdtempSync(join(tmpdir(), "mvt-"));
    const snap: RunSnapshot = {
      schemaVersion: 1, generatedAt: "2026-05-09T12:00:00Z",
      windowSinceMs: 0, serversAnalysed: ["gitnexus"],
      sessionCount: 0, callCount: 0, rows: [], unclassifiedCalls: 0,
    };
    const path = writeSnapshot(snap, dir);
    expect(existsSync(path)).toBe(true);
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    expect(parsed.schemaVersion).toBe(1);
    rmSync(dir, { recursive: true });
  });
});
