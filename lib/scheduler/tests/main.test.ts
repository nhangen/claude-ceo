import { describe, expect, test } from "bun:test";
import { FATAL_EXIT_CODE } from "cronbird/core";
import { PermanentHeartbeatWriteError } from "cronbird/cli";
import { resolveFatalExitCode } from "@/main";
import { runningDir, doneDir } from "@/runtime";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("resolveFatalExitCode", () => {
  test("returns FATAL_EXIT_CODE (78) for PermanentHeartbeatWriteError instance", () => {
    const err = new PermanentHeartbeatWriteError(Object.assign(new Error("EACCES"), { code: "EACCES" }));
    expect(resolveFatalExitCode(err)).toBe(FATAL_EXIT_CODE);
    expect(resolveFatalExitCode(err)).toBe(78);
  });

  test("returns FATAL_EXIT_CODE (78) for duck-typed PermanentHeartbeatWriteError", () => {
    const duckTyped = { name: "PermanentHeartbeatWriteError", message: "disk read-only" };
    expect(resolveFatalExitCode(duckTyped)).toBe(FATAL_EXIT_CODE);
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

describe("main entrypoint process exit", () => {
  const rootDir = join(__dirname, "..");

  interface Fixture {
    root: string;
    home: string;
    vault: string;
    schedulerdDir: string;
    cleanup: () => void;
  }

  const createFixture = (): Fixture => {
    const root = mkdtempSync(join(tmpdir(), "ceo-sched-test-"));
    const home = join(root, "home");
    const vault = join(root, "vault");
    const schedulerdDir = join(home, ".ceo", "schedulerd");

    mkdirSync(join(home, ".ceo"), { recursive: true });
    mkdirSync(runningDir(home), { recursive: true });
    mkdirSync(doneDir(home), { recursive: true });
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

  test("exits with FATAL_EXIT_CODE (78) when heartbeat path is unwritable", async () => {
    const fix = createFixture();
    try {
      // Make schedulerd directory non-writable so writing heartbeat.json (and temp file) fails with EACCES.
      // running and done directories are pre-created, so mkdirSync succeeds.
      chmodSync(fix.schedulerdDir, 0o555);

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

      const killTimeout = setTimeout(() => proc.kill(), 10000);
      const exitCode = await proc.exited;
      clearTimeout(killTimeout);

      const stderr = await new Response(proc.stderr).text();
      expect(exitCode).toBe(FATAL_EXIT_CODE);
      expect(exitCode).toBe(78);
      expect(stderr).toContain("ceo-schedulerd: fatal:");
      expect(stderr).toContain("permanent local heartbeat-write failure");
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

    const killTimeout = setTimeout(() => proc.kill(), 10000);
    const exitCode = await proc.exited;
    clearTimeout(killTimeout);

    const stderr = await new Response(proc.stderr).text();
    expect(exitCode).toBe(1);
    expect(stderr).toContain("must be set before starting ceo-schedulerd");
  });
});
