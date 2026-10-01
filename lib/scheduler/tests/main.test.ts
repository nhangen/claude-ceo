import { describe, expect, test } from "bun:test";
import { FATAL_EXIT_CODE } from "cronbird/core";
import { PermanentHeartbeatWriteError } from "cronbird/cli";
import {
  clearSchedulerdAlert,
  createClearRunning,
  createJobDispatcher,
  formatSchedulerdAlert,
  parseAlertField,
  readStateDir,
  recordFatalInSyncedHeartbeat,
  recordFatalSchedulerdAlert,
  resolveFatalExitCode,
  SchedulerDispatchContext,
  trackCompletion,
  writeDoneRecordAtomic,
} from "@/main";
import { runningDir, doneDir } from "@/runtime";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  test.skipIf(isRoot)("exits with FATAL_EXIT_CODE (78) when heartbeat path is unwritable, writes firing alert, and clears on restart", async () => {
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
      // #589: single-host fallback alert in CEO/alerts/schedulerd-<host>.md
      const alertPath = join(fix.vault, "CEO", "alerts", "schedulerd-testhost.md");
      const alertContent = readFileSync(alertPath, "utf8");
      expect(parseAlertField(alertContent, "status")).toBe("firing");
      expect(parseAlertField(alertContent, "host")).toBe("testhost");
      expect(parseAlertField(alertContent, "code")).toBe("EACCES");

      // Fix the fault and restart daemon: alert must transition to clear (#589).
      chmodSync(fix.schedulerdDir, 0o755);
      const child = Bun.spawn(["bun", "run", "src/main.ts"], {
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
      try {
        let cleared = false;
        for (let i = 0; i < 50; i++) {
          await Bun.sleep(20);
          try {
            const updated = readFileSync(alertPath, "utf8");
            if (parseAlertField(updated, "status") === "clear") {
              cleared = true;
              break;
            }
          } catch {
            // retry until heartbeat completes
          }
        }
        expect(cleared).toBe(true);
      } finally {
        child.kill();
        await child.exited;
      }
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
      // Alert write can still succeed independently
      const alertPath = join(fix.vault, "CEO", "alerts", "schedulerd-testhost.md");
      const alertContent = readFileSync(alertPath, "utf8");
      expect(parseAlertField(alertContent, "status")).toBe("firing");
    } finally {
      fix.cleanup();
    }
  });

  test.skipIf(isRoot)("still exits 78 when the fallback alert cannot be written either", async () => {
    const fix = createFixture();
    try {
      chmodSync(fix.schedulerdDir, 0o555);
      // A file where the alerts directory should be makes the alert write fail too.
      writeFileSync(join(fix.vault, "CEO", "alerts"), "");
      const { exitCode, stderr } = await runDaemon(fix);
      expect(exitCode).toBe(FATAL_EXIT_CODE);
      expect(stderr).toContain("could not write fallback alert");
      // Synced heartbeat mark can still succeed independently
      const synced = JSON.parse(readFileSync(join(fix.vault, "CEO", "heartbeats", "testhost.json"), "utf8"));
      expect(synced.fatal.code).toBe("EACCES");
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

describe("schedulerd alert file handling", () => {
  const setup = () => {
    const dir = mkdtempSync(join(tmpdir(), "ceo-sched-alert-"));
    return { dir, path: join(dir, "CEO", "alerts", "schedulerd-mac.md") };
  };
  const now = new Date("2026-09-30T14:00:00.000Z");

  test("parseAlertField extracts frontmatter fields and ignores body text", () => {
    const doc = [
      "---",
      "status: firing",
      "since: 2026-09-30T13:00:00.000Z\r",
      "last_check: 2026-09-30T14:00:00.000Z",
      "host: mac",
      "---",
      "",
      "# Body with misleading keys",
      "",
      "status: clear",
      "host: otherhost",
    ].join("\n");

    expect(parseAlertField(doc, "status")).toBe("firing");
    expect(parseAlertField(doc, "since")).toBe("2026-09-30T13:00:00.000Z");
    expect(parseAlertField(doc, "last_check")).toBe("2026-09-30T14:00:00.000Z");
    expect(parseAlertField(doc, "host")).toBe("mac");
    expect(parseAlertField(doc, "nonexistent")).toBeNull();
    expect(parseAlertField("no frontmatter here", "status")).toBeNull();
  });

  test("recordFatalSchedulerdAlert writes firing alert when absent", () => {
    const { dir, path } = setup();
    try {
      expect(recordFatalSchedulerdAlert(path, "mac", "EACCES", now)).toBe("written");
      const content = readFileSync(path, "utf8");
      expect(parseAlertField(content, "status")).toBe("firing");
      expect(parseAlertField(content, "since")).toBe("2026-09-30T14:00:00.000Z");
      expect(parseAlertField(content, "last_check")).toBe("2026-09-30T14:00:00.000Z");
      expect(parseAlertField(content, "host")).toBe("mac");
      expect(parseAlertField(content, "code")).toBe("EACCES");
      expect(content).toContain("permanent local-write fault (code: EACCES)");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("recordFatalSchedulerdAlert does not rewrite if already firing (churn prevention)", () => {
    const { dir, path } = setup();
    try {
      expect(recordFatalSchedulerdAlert(path, "mac", "EACCES", now)).toBe("written");
      const before = readFileSync(path, "utf8");
      const later = new Date("2026-09-30T14:00:10.000Z");
      expect(recordFatalSchedulerdAlert(path, "mac", "EACCES", later)).toBe("unchanged");
      expect(readFileSync(path, "utf8")).toBe(before);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("recordFatalSchedulerdAlert overwrites if status was clear", () => {
    const { dir, path } = setup();
    try {
      mkdirSync(join(dir, "CEO", "alerts"), { recursive: true });
      writeFileSync(path, formatSchedulerdAlert("mac", "clear", "2026-09-30T13:00:00.000Z", "2026-09-30T13:00:00.000Z"));
      expect(recordFatalSchedulerdAlert(path, "mac", "EROFS", now)).toBe("written");
      const content = readFileSync(path, "utf8");
      expect(parseAlertField(content, "status")).toBe("firing");
      expect(parseAlertField(content, "code")).toBe("EROFS");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("clearSchedulerdAlert does nothing if file does not exist (no phantom creation)", () => {
    const { dir, path } = setup();
    try {
      expect(clearSchedulerdAlert(path, "mac", now)).toBe("unchanged");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("clearSchedulerdAlert does nothing if file is already clear (churn prevention)", () => {
    const { dir, path } = setup();
    try {
      mkdirSync(join(dir, "CEO", "alerts"), { recursive: true });
      writeFileSync(path, formatSchedulerdAlert("mac", "clear", "2026-09-30T13:00:00.000Z", "2026-09-30T13:00:00.000Z"));
      const before = readFileSync(path, "utf8");
      expect(clearSchedulerdAlert(path, "mac", now)).toBe("unchanged");
      expect(readFileSync(path, "utf8")).toBe(before);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("clearSchedulerdAlert transitions from firing to clear", () => {
    const { dir, path } = setup();
    try {
      recordFatalSchedulerdAlert(path, "mac", "EACCES", now);
      const clearTime = new Date("2026-09-30T14:15:00.000Z");
      expect(clearSchedulerdAlert(path, "mac", clearTime)).toBe("written");
      const content = readFileSync(path, "utf8");
      expect(parseAlertField(content, "status")).toBe("clear");
      expect(parseAlertField(content, "since")).toBe("2026-09-30T14:15:00.000Z");
      expect(parseAlertField(content, "host")).toBe("mac");
      expect(content).toContain("running normally");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("readStateDir", () => {
  test("skips a tempfile left by a daemon that died between write and rename", () => {
    const dir = mkdtempSync(join(tmpdir(), "ceo-state-dir-"));
    try {
      writeFileSync(join(dir, "real-job"), "1000 4242");
      writeFileSync(join(dir, "real-job.tmp.4242.1700000000000.abc123"), "1000 4242");
      expect(readStateDir(dir)).toEqual({ "real-job": "1000 4242" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("writeDoneRecordAtomic", () => {
  const setup = () => {
    const dir = mkdtempSync(join(tmpdir(), "ceo-done-atomic-"));
    return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
  };

  test("writes a valid completion record atomically", () => {
    const { dir, cleanup } = setup();
    try {
      writeDoneRecordAtomic(dir, "my-job", 1000, 2000, 0);
      const record = JSON.parse(readFileSync(join(dir, "my-job"), "utf8"));
      expect(record).toEqual({ ts: 2000, durationMs: 1000, exitCode: 0 });
    } finally {
      cleanup();
    }
  });

  test("leaves existing done record intact when the write fails mid-flight", () => {
    const { dir, cleanup } = setup();
    try {
      const dest = join(dir, "my-job");
      writeFileSync(dest, JSON.stringify({ ts: 600, durationMs: 100, exitCode: 0 }));
      // Real ENOSPC/EIO: bytes are partly written before the fault.
      const tornWrite = (path: string, content: string) => {
        writeFileSync(path, content.slice(0, 5));
        throw new Error("EIO: i/o error, write");
      };
      expect(() => writeDoneRecordAtomic(dir, "my-job", 1000, 2000, 1, tornWrite)).toThrow("EIO");
      expect(JSON.parse(readFileSync(dest, "utf8"))).toEqual({ ts: 600, durationMs: 100, exitCode: 0 });
      expect(readdirSync(dir)).toEqual(["my-job"]);
    } finally {
      cleanup();
    }
  });

  test("cleans up torn tempfile if rename fails", () => {
    const { dir, cleanup } = setup();
    try {
      // Create a directory where the dest file would be to cause rename to throw EISDIR
      mkdirSync(join(dir, "is-dir"), { recursive: true });
      expect(() => writeDoneRecordAtomic(dir, "is-dir", 1000, 2000, 0)).toThrow();

      // Ensure no dangling .tmp files remain in dir
      const entries = readdirSync(dir);
      expect(entries).toEqual(["is-dir"]);
    } finally {
      cleanup();
    }
  });
});

describe("createClearRunning", () => {
  const setup = () => {
    const dir = mkdtempSync(join(tmpdir(), "ceo-clearrun-"));
    return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
  };

  test("removes running marker cleanly without logging", () => {
    const { dir, cleanup } = setup();
    try {
      const marker = join(dir, "job");
      writeFileSync(marker, "12345");
      const logs: string[] = [];
      const clear = createClearRunning(marker, (m) => logs.push(m));
      clear();
      expect(existsSync(marker)).toBe(false);
      expect(logs).toEqual([]);
    } finally {
      cleanup();
    }
  });

  test("ignores ENOENT silently when marker does not exist", () => {
    const { dir, cleanup } = setup();
    try {
      const marker = join(dir, "nonexistent");
      const logs: string[] = [];
      const clear = createClearRunning(marker, (m) => logs.push(m));
      clear();
      expect(logs).toEqual([]);
    } finally {
      cleanup();
    }
  });

  test.skipIf(isRoot)("logs when removal fails with non-ENOENT (e.g. EACCES)", () => {
    const { dir, cleanup } = setup();
    try {
      const marker = join(dir, "job");
      writeFileSync(marker, "12345");
      chmodSync(dir, 0o555);
      const logs: string[] = [];
      const clear = createClearRunning(marker, (m) => logs.push(m));
      clear();
      expect(logs).toHaveLength(1);
      expect(logs[0]).toContain("failed to clear running marker");
    } finally {
      try {
        chmodSync(dir, 0o755);
      } catch {
        // ignore
      }
      cleanup();
    }
  });
});

describe("createJobDispatcher", () => {
  const setup = () => {
    const root = mkdtempSync(join(tmpdir(), "ceo-dispatch-test-"));
    const runDir = join(root, "running");
    const dDir = join(root, "done");
    const vault = join(root, "vault");
    mkdirSync(runDir, { recursive: true });
    mkdirSync(dDir, { recursive: true });
    mkdirSync(vault, { recursive: true });
    return {
      root,
      runDir,
      dDir,
      vault,
      cleanup: () => rmSync(root, { recursive: true, force: true }),
    };
  };

  const waitFor = async (cond: () => boolean) => {
    for (let i = 0; i < 200 && !cond(); i++) await new Promise((r) => setTimeout(r, 5));
  };

  test("a torn PID rewrite keeps the in-flight marker and still tracks completion", async () => {
    const { runDir, dDir, vault, cleanup } = setup();
    try {
      const logs: string[] = [];
      let exitResolve: (code: number) => void;
      const exitedPromise = new Promise<number>((r) => {
        exitResolve = r;
      });
      const mockSpawn = () =>
        ({ pid: 99999, unref: () => {}, exited: exitedPromise }) as unknown as ReturnType<typeof Bun.spawn>;
      // Fails only the PID rewrite, after truncating and partly writing, as ENOSPC/EIO do.
      const rawWrite = (path: string, content: string) => {
        if (content.includes("99999")) {
          writeFileSync(path, content.slice(0, 2));
          throw new Error("EIO: i/o error, write");
        }
        writeFileSync(path, content);
      };

      const dispatch = createJobDispatcher({
        runDir,
        dDir,
        vault,
        dispatchContext: new SchedulerDispatchContext(),
        dispatchArgv: (name) => ["fake-bin", name],
        log: (m) => logs.push(m),
        spawn: mockSpawn,
        rawWrite,
        now: () => 1000,
      });

      dispatch("test-job");

      expect(logs.some((l) => l.includes("could not record PID 99999"))).toBe(true);
      expect(logs.some((l) => l.includes("dispatch failed"))).toBe(false);
      const markerPath = join(runDir, "test-job");
      // Still parses as in flight, so the MAX_CONCURRENT=1 gate stays shut.
      expect(readFileSync(markerPath, "utf8")).toBe("1000");
      expect(Object.keys(readStateDir(runDir))).toEqual(["test-job"]);

      exitResolve!(0);
      const donePath = join(dDir, "test-job");
      await waitFor(() => !existsSync(markerPath));
      expect(JSON.parse(readFileSync(donePath, "utf8"))).toEqual({ ts: 1000, durationMs: 0, exitCode: 0 });
      expect(existsSync(markerPath)).toBe(false);
    } finally {
      cleanup();
    }
  });

  test("a torn completion write leaves the previous done record in place", async () => {
    const { runDir, dDir, vault, cleanup } = setup();
    try {
      const logs: string[] = [];
      const donePath = join(dDir, "test-job");
      writeFileSync(donePath, JSON.stringify({ ts: 500, durationMs: 10, exitCode: 0 }));
      const rawWrite = (path: string, content: string) => {
        if (content.includes("exitCode")) {
          writeFileSync(path, content.slice(0, 3));
          throw new Error("ENOSPC: no space left on device, write");
        }
        writeFileSync(path, content);
      };
      const dispatch = createJobDispatcher({
        runDir,
        dDir,
        vault,
        dispatchContext: new SchedulerDispatchContext(),
        dispatchArgv: (name) => ["fake-bin", name],
        log: (m) => logs.push(m),
        spawn: () =>
          ({ pid: 4242, unref: () => {}, exited: Promise.resolve(3) }) as unknown as ReturnType<typeof Bun.spawn>,
        rawWrite,
        now: () => 1000,
      });

      dispatch("test-job");
      await waitFor(() => !existsSync(join(runDir, "test-job")));

      expect(JSON.parse(readFileSync(donePath, "utf8"))).toEqual({ ts: 500, durationMs: 10, exitCode: 0 });
      expect(readdirSync(dDir)).toEqual(["test-job"]);
      expect(logs.some((l) => l.includes("could not record exit 3 for test-job"))).toBe(true);
    } finally {
      cleanup();
    }
  });

  test("clears running marker and logs 'dispatch failed' when spawn fails synchronously", () => {
    const { runDir, dDir, vault, cleanup } = setup();
    try {
      const logs: string[] = [];
      const context = new SchedulerDispatchContext();
      const mockSpawn = () => {
        throw new Error("ENOENT: binary not found");
      };

      const dispatch = createJobDispatcher({
        runDir,
        dDir,
        vault,
        dispatchContext: context,
        dispatchArgv: (name) => ["nonexistent", name],
        log: (m) => logs.push(m),
        spawn: mockSpawn,
      });

      dispatch("failed-job");

      expect(logs.some((l) => l.includes("dispatch failed for failed-job: ENOENT: binary not found"))).toBe(true);
      expect(existsSync(join(runDir, "failed-job"))).toBe(false);
    } finally {
      cleanup();
    }
  });
});
