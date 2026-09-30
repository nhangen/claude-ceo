import { describe, expect, test } from "bun:test";
import { FATAL_EXIT_CODE } from "cronbird/core";
import { PermanentHeartbeatWriteError } from "cronbird/cli";
import { recordFatalInSyncedHeartbeat, resolveFatalExitCode, trackCompletion } from "@/main";
import { runningDir, doneDir } from "@/runtime";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("resolveFatalExitCode", () => {
  test("returns FATAL_EXIT_CODE (78) for PermanentHeartbeatWriteError instance", () => {
    const err = new PermanentHeartbeatWriteError(Object.assign(new Error("EACCES"), { code: "EACCES" }));
    expect(resolveFatalExitCode(err)).toBe(FATAL_EXIT_CODE);
  });

  test("returns 1 for generic Error", () => {
    expect(resolveFatalExitCode(new Error("Generic crash"))).toBe(1);
    expect(resolveFatalExitCode(new TypeError("Invalid argument"))).toBe(1);
  });

  test("returns 1 for raw errno exception without PermanentHeartbeatWriteError wrapper", () => {
    const rawFsError = Object.assign(new Error("permission denied"), { code: "EACCES" });
    expect(resolveFatalExitCode(rawFsError)).toBe(1);
  });

  test("returns 1 for non-error or falsy values", () => {
    expect(resolveFatalExitCode(null)).toBe(1);
    expect(resolveFatalExitCode(undefined)).toBe(1);
    expect(resolveFatalExitCode("string error")).toBe(1);
    expect(resolveFatalExitCode(42)).toBe(1);
  });
});

// Root ignores mode bits, so the unwritable-directory fixtures cannot fail there.
const isRoot = process.getuid?.() === 0;
// Below bun's 5s default test timeout, so a daemon that loops instead of exiting
// is killed and cleaned up rather than orphaned.
const KILL_AFTER_MS = 4000;

describe("main entrypoint process exit", () => {
  const rootDir = join(import.meta.dir, "..");

  interface Fixture {
    root: string;
    home: string;
    vault: string;
    schedulerdDir: string;
    cleanup: () => void;
  }

  const createFixture = ({ precreateRunState = true } = {}): Fixture => {
    const root = mkdtempSync(join(tmpdir(), "ceo-sched-test-"));
    const home = join(root, "home");
    const vault = join(root, "vault");
    const schedulerdDir = join(home, ".ceo", "schedulerd");

    mkdirSync(schedulerdDir, { recursive: true });
    if (precreateRunState) {
      mkdirSync(runningDir(home), { recursive: true });
      mkdirSync(doneDir(home), { recursive: true });
    }
    mkdirSync(join(vault, "CEO"), { recursive: true });

    // Minimal valid configs
    writeFileSync(join(home, ".ceo", "registry.json"), JSON.stringify({ version: 1, playbooks: [] }));
    writeFileSync(join(vault, "CEO", "swarm.json"), JSON.stringify({ hosts: { testhost: { single: [] } } }));
    writeFileSync(join(vault, "CEO", "settings.json"), JSON.stringify({ cooldown_seconds: 1800 }));

    return {
      root,
      home,
      vault,
      schedulerdDir,
      cleanup: () => {
        try {
          chmodSync(schedulerdDir, 0o755);
        } catch {
          // ignore
        }
        rmSync(root, { recursive: true, force: true });
      },
    };
  };

  const runDaemon = async (fix: Fixture) => {
    const proc = Bun.spawn(["bun", "run", "src/main.ts"], {
      cwd: rootDir,
      env: {
        ...process.env,
        HOME: fix.home,
        CEO_VAULT: fix.vault,
        CEO_HOSTNAME: "testhost",
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const killTimeout = setTimeout(() => proc.kill(), KILL_AFTER_MS);
    const exitCode = await proc.exited;
    clearTimeout(killTimeout);
    return { exitCode, stderr: await new Response(proc.stderr).text() };
  };

  test.skipIf(isRoot)("exits with FATAL_EXIT_CODE (78) when heartbeat path is unwritable", async () => {
    // The run-state directories survive from an earlier healthy run, so the
    // heartbeat write is the first write that fails.
    const fix = createFixture();
    try {
      chmodSync(fix.schedulerdDir, 0o555);
      const { exitCode, stderr } = await runDaemon(fix);
      expect(exitCode).toBe(FATAL_EXIT_CODE);
      expect(stderr).toContain("ceo-schedulerd: fatal:");
      expect(stderr).toContain("permanent local heartbeat-write failure");
      // #562: a peer's owners-health reads this to reach the operator.
      const synced = JSON.parse(readFileSync(join(fix.vault, "CEO", "heartbeats", "testhost.json"), "utf8"));
      expect(synced.fatal.code).toBe("EACCES");
    } finally {
      fix.cleanup();
    }
  });

  test.skipIf(isRoot)("still exits 78 when the synced heartbeat cannot be marked either", async () => {
    const fix = createFixture();
    try {
      chmodSync(fix.schedulerdDir, 0o555);
      // A file where the heartbeats directory should be makes the mark fail too.
      writeFileSync(join(fix.vault, "CEO", "heartbeats"), "");
      const { exitCode, stderr } = await runDaemon(fix);
      expect(exitCode).toBe(FATAL_EXIT_CODE);
      expect(stderr).toContain("could not mark the synced heartbeat fatal");
    } finally {
      fix.cleanup();
    }
  });

  test.skipIf(isRoot)("exits with FATAL_EXIT_CODE (78) on a fresh host whose schedulerd dir is unwritable", async () => {
    // No run-state directories yet, so the startup mkdir is the first write that fails.
    const fix = createFixture({ precreateRunState: false });
    try {
      chmodSync(fix.schedulerdDir, 0o555);
      const { exitCode, stderr } = await runDaemon(fix);
      expect(exitCode).toBe(FATAL_EXIT_CODE);
      expect(stderr).toContain("run-state");
      const synced = JSON.parse(readFileSync(join(fix.vault, "CEO", "heartbeats", "testhost.json"), "utf8"));
      expect(synced.fatal.code).toBe("EACCES");
    } finally {
      fix.cleanup();
    }
  });

  test("exits with code 1 on generic startup error (e.g. missing environment variables)", async () => {
    const proc = Bun.spawn(["bun", "run", "src/main.ts"], {
      cwd: rootDir,
      env: {
        ...process.env,
        HOME: "",
        CEO_VAULT: "",
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    const killTimeout = setTimeout(() => proc.kill(), KILL_AFTER_MS);
    const exitCode = await proc.exited;
    clearTimeout(killTimeout);

    const stderr = await new Response(proc.stderr).text();
    expect(exitCode).toBe(1);
    expect(stderr).toContain("must be set before starting ceo-schedulerd");
  });
});

describe("trackCompletion", () => {
  const harness = () => {
    const calls: string[] = [];
    return {
      calls,
      clearRunning: () => calls.push("clear"),
      log: (msg: string) => calls.push(`log:${msg}`),
    };
  };
  const enospc = () => {
    throw new Error("ENOSPC: no space left on device");
  };

  test("records the exit code and clears the marker", async () => {
    const h = harness();
    await trackCompletion("job", Promise.resolve(0), (code) => h.calls.push(`write:${code}`), h.clearRunning, h.log);
    expect(h.calls).toEqual(["write:0", "clear"]);
  });

  test("a failed exit wait records exit 1 and logs why", async () => {
    const h = harness();
    await trackCompletion("job", Promise.reject(new Error("wait failed")), (code) => h.calls.push(`write:${code}`), h.clearRunning, h.log);
    expect(h.calls).toEqual(["clear", "log:completion tracking failed for job: wait failed", "write:1"]);
  });

  test("a failed write of a known exit code logs that code and does not record exit 1", async () => {
    const h = harness();
    let attempts = 0;
    const flaky = (code: number) => {
      attempts += 1;
      if (attempts === 1) enospc();
      h.calls.push(`write:${code}`);
    };
    await trackCompletion("job", Promise.resolve(0), flaky, h.clearRunning, h.log);
    expect(h.calls).toEqual(["log:could not record exit 0 for job: ENOSPC: no space left on device", "clear"]);
  });

  test("a wait failure whose fallback write also fails settles, clears, and logs both", async () => {
    const h = harness();
    await trackCompletion("job", Promise.reject(new Error("wait failed")), enospc, h.clearRunning, h.log);
    expect(h.calls).toEqual([
      "clear",
      "log:completion tracking failed for job: wait failed",
      "log:could not record the failed completion for job: ENOSPC: no space left on device",
    ]);
  });

  test("a voided call whose writes throw raises no unhandled rejection", async () => {
    const h = harness();
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      // Voided, as the dispatch site calls it: a rejection here is only
      // observable through the unhandledRejection event.
      void trackCompletion("job", Promise.resolve(0), enospc, h.clearRunning, h.log);
      void trackCompletion("job", Promise.reject(new Error("wait failed")), enospc, h.clearRunning, h.log);
      await new Promise((r) => setTimeout(r, 20));
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    expect(unhandled).toEqual([]);
    expect(h.calls.filter((c) => c === "clear")).toHaveLength(2);
  });
});

describe("recordFatalInSyncedHeartbeat", () => {
  const setup = () => {
    const dir = mkdtempSync(join(tmpdir(), "ceo-fatal-hb-"));
    return { dir, path: join(dir, "CEO", "heartbeats", "mac.json") };
  };
  const now = new Date("2026-09-29T02:00:00.000Z");

  test("keeps the last good ts and records the fault", () => {
    const { dir, path } = setup();
    try {
      mkdirSync(join(dir, "CEO", "heartbeats"), { recursive: true });
      writeFileSync(path, JSON.stringify({ host: "mac", ts: "2026-09-29T01:00:00.000Z" }));
      expect(recordFatalInSyncedHeartbeat(path, "mac", "EACCES", now)).toBe("written");
      expect(JSON.parse(readFileSync(path, "utf8"))).toEqual({
        host: "mac",
        ts: "2026-09-29T01:00:00.000Z",
        fatal: { code: "EACCES", since: "2026-09-29T02:00:00.000Z" },
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("does not rewrite an unchanged code, so the respawn loop does not churn sync", () => {
    const { dir, path } = setup();
    try {
      recordFatalInSyncedHeartbeat(path, "mac", "ENOSPC", now);
      const before = readFileSync(path, "utf8");
      const later = new Date("2026-09-29T02:00:10.000Z");
      expect(recordFatalInSyncedHeartbeat(path, "mac", "ENOSPC", later)).toBe("unchanged");
      expect(readFileSync(path, "utf8")).toBe(before);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a new code replaces the old one", () => {
    const { dir, path } = setup();
    try {
      mkdirSync(join(dir, "CEO", "heartbeats"), { recursive: true });
      writeFileSync(path, JSON.stringify({ host: "mac", ts: "2026-09-29T01:00:00.000Z", fatal: { code: "ENOSPC", since: "x" } }));
      recordFatalInSyncedHeartbeat(path, "mac", "EROFS", now);
      expect(JSON.parse(readFileSync(path, "utf8")).fatal).toEqual({ code: "EROFS", since: "2026-09-29T02:00:00.000Z" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("with no prior heartbeat it records the fault with a null ts", () => {
    const { dir, path } = setup();
    try {
      recordFatalInSyncedHeartbeat(path, "mac", "EACCES", now);
      const hb = JSON.parse(readFileSync(path, "utf8"));
      expect(hb.ts).toBeNull();
      expect(hb.fatal.code).toBe("EACCES");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
