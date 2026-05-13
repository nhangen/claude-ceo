import { mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import type { RunSnapshot } from "@/types";

export function defaultSnapshotDir(): string {
  return join(homedir(), ".local", "share", "claude-ceo", "value-tracker", "runs");
}

export function writeSnapshot(snap: RunSnapshot, dir: string = defaultSnapshotDir()): string {
  mkdirSync(dir, { recursive: true });
  const stamp = snap.generatedAt.replace(/[-:]/g, "").replace(/\..*$/, "").replace("T", "-").slice(0, 13);
  const path = join(dir, `${stamp}.json`);
  writeFileSync(path, JSON.stringify(snap, null, 2));
  return path;
}
