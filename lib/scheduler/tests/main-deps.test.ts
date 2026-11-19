import { describe, expect, test } from "bun:test";
import { createHeartbeatReader } from "@/main";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function withDir(fn: (dir: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "schedulerd-deps-"));
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("createHeartbeatReader (#656)", () => {
  test("restores the prior heartbeat itself, not cronbird's { value, warnings } wrapper", () => {
    withDir((dir) => {
      const path = join(dir, "heartbeat.json");
      writeFileSync(path, JSON.stringify({ ts: 1, dispatched_minute: { morning: 29000000 } }));
      const logged: string[] = [];
      const hb = createHeartbeatReader(path, (m) => logged.push(m))();
      expect(hb?.dispatched_minute).toEqual({ morning: 29000000 });
      expect(logged).toEqual([]);
    });
  });

  test("logs the loader's warning when the heartbeat is corrupt, so an emptied guard is visible", () => {
    withDir((dir) => {
      const path = join(dir, "heartbeat.json");
      writeFileSync(path, "{not json");
      const logged: string[] = [];
      expect(createHeartbeatReader(path, (m) => logged.push(m))()).toBeNull();
      expect(logged).toHaveLength(1);
      expect(logged[0]).toContain(`heartbeat file present but unparseable: ${path}`);
    });
  });

  test("a missing heartbeat is a quiet first boot", () => {
    withDir((dir) => {
      const logged: string[] = [];
      expect(createHeartbeatReader(join(dir, "absent.json"), (m) => logged.push(m))()).toBeNull();
      expect(logged).toEqual([]);
    });
  });
});
