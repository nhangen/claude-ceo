import { describe, expect, test } from "bun:test";
import { STALE_EXIT_CODE } from "cronbird/core";
import {
  fmtRelative,
  fmtTs,
  parseDuration,
  parseFlags,
  runCeoStatusCommand,
  table,
  type StatusCliDeps,
} from "@/status";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

describe("parseDuration", () => {
  test("parses valid seconds, minutes, hours, days", () => {
    expect(parseDuration("30s")).toBe(30_000);
    expect(parseDuration("10m")).toBe(600_000);
    expect(parseDuration("2h")).toBe(7_200_000);
    expect(parseDuration("1d")).toBe(86_400_000);
  });

  test("returns null for malformed or missing duration", () => {
    expect(parseDuration(undefined)).toBeNull();
    expect(parseDuration("")).toBeNull();
    expect(parseDuration("10x")).toBeNull();
    expect(parseDuration("abc")).toBeNull();
    expect(parseDuration("-5m")).toBeNull();
  });
});

describe("parseFlags", () => {
  const makeDeps = (): StatusCliDeps & { stdout: string[]; stderr: string[] } => {
    const stdout: string[] = [];
    const stderr: string[] = [];
    return {
      now: () => new Date("2026-06-07T12:00:00Z"),
      out: (s) => stdout.push(s),
      err: (s) => stderr.push(s),
      env: {},
      stdout,
      stderr,
    };
  };

  test("parses --json and --within for next-runs", () => {
    const deps = makeDeps();
    const res = parseFlags("next-runs", ["--json", "--within", "30m"], deps);
    expect(res).toEqual({ json: true, withinMs: 1_800_000 });
  });

  test("rejects invalid --within value", () => {
    const deps = makeDeps();
    const res = parseFlags("next-runs", ["--within", "bad"], deps);
    expect(res).toBe(2);
    expect(deps.stderr.join("")).toContain("invalid --within duration");
  });

  test("rejects --within on status subcommand", () => {
    const deps = makeDeps();
    const res = parseFlags("status", ["--within", "30m"], deps);
    expect(res).toBe(2);
    expect(deps.stderr.join("")).toContain("--within is only valid for next-runs");
  });

  test("rejects unknown flags", () => {
    const deps = makeDeps();
    const res = parseFlags("status", ["--unknown"], deps);
    expect(res).toBe(2);
    expect(deps.stderr.join("")).toContain("unknown flag: --unknown");
  });

  test("handles --help", () => {
    const deps = makeDeps();
    const res = parseFlags("status", ["--help"], deps);
    expect(res).toBe(0);
    expect(deps.stdout.join("")).toContain("Usage: ceo status");
  });
});

describe("fmtTs & fmtRelative & table", () => {
  test("fmtTs formats timestamp or -", () => {
    expect(fmtTs(null)).toBe("-");
    expect(fmtTs(1780833600000)).toBe(new Date(1780833600000).toISOString());
  });

  test("fmtRelative formats future and past", () => {
    expect(fmtRelative(0)).toBe("now");
    expect(fmtRelative(30_000)).toBe("in <1m");
    expect(fmtRelative(120_000)).toBe("in 2m");
    expect(fmtRelative(3_720_000)).toBe("in 1h 2m");
    expect(fmtRelative(-120_000)).toBe("2m ago");
  });

  test("table formats aligned columns", () => {
    const rendered = table([
      ["A", "BC"],
      ["123", "4"],
    ]);
    expect(rendered).toBe("A    BC\n123  4\n");
  });
});

describe("runCeoStatusCommand", () => {
  const NOW = new Date("2026-06-07T12:00:00Z");

  const setupFixture = () => {
    const testDir = `${tmpdir()}/ceo-status-test-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const home = `${testDir}/home`;
    const vault = `${testDir}/vault`;
    mkdirSync(`${home}/.ceo`, { recursive: true });
    mkdirSync(`${vault}/CEO`, { recursive: true });
    return {
      testDir,
      home,
      vault,
      cleanup: () => rmSync(testDir, { recursive: true, force: true }),
    };
  };

  test("fails if registry is missing", () => {
    const fix = setupFixture();
    try {
      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("status", [], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(1);
      expect(stderr.join("")).toContain("No registry found");
    } finally {
      fix.cleanup();
    }
  });

  test("renders status table with jobs and heartbeat", () => {
    const fix = setupFixture();
    try {
      const reg = {
        schema_version: 3,
        generated: "2026-06-07T00:00:00Z",
        playbooks: [
          {
            name: "morning-scan",
            schedule: "0 9 * * *",
            status: "active",
            trigger: "cron",
            scope: "single",
          },
          {
            name: "pr-review",
            schedule: "*/30 * * * *",
            status: "active",
            trigger: "cron",
            scope: "each",
          },
        ],
      };
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(reg));
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["pr-review"]));
      writeFileSync(
        `${fix.vault}/CEO/swarm.json`,
        JSON.stringify({ hosts: ["testhost"], owners: { "morning-scan": "testhost" } })
      );
      mkdirSync(`${fix.home}/.ceo/schedulerd`, { recursive: true });
      writeFileSync(
        `${fix.home}/.ceo/schedulerd/heartbeat.json`,
        JSON.stringify({ ts: NOW.getTime() - 60_000, host: "testhost", last_fired: {}, dispatched_minute: {} })
      );

      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("status", [], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(0);
      const out = stdout.join("");
      expect(out).toContain("host=testhost");
      expect(out).toContain("heartbeat 1m ago");
      expect(out).toContain("morning-scan");
      expect(out).toContain("pr-review");
      expect(out).toContain("NAME");
      expect(out).toContain("NEXT FIRE");
      expect(out).toContain("HEALTH");
      // Check that both single-scope (owned) and each-scope (enabled) are runnable
      expect(out).toMatch(/morning-scan\s+single\s+yes/);
      expect(out).toMatch(/pr-review\s+each\s+yes/);
    } finally {
      fix.cleanup();
    }
  });

  test("status --json outputs structured json", () => {
    const fix = setupFixture();
    try {
      const reg = {
        schema_version: 3,
        playbooks: [
          {
            name: "p1",
            schedule: "0 9 * * *",
            status: "active",
            trigger: "cron",
            scope: "each",
          },
        ],
      };
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(reg));
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["p1"]));

      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("status", ["--json"], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(0);
      const json = JSON.parse(stdout.join(""));
      expect(json.host).toBe("testhost");
      expect(json.jobs).toHaveLength(1);
      expect(json.jobs[0].name).toBe("p1");
      expect(json.jobs[0].runnable).toBe(true);
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs renders upcoming runs filtered by window", () => {
    const fix = setupFixture();
    try {
      const reg = {
        schema_version: 3,
        playbooks: [
          {
            name: "p-soon",
            schedule: "10 12 * * *", // in 10 minutes (12:10)
            status: "active",
            trigger: "cron",
            scope: "each",
          },
          {
            name: "p-later",
            schedule: "0 18 * * *", // in 6 hours (18:00)
            status: "active",
            trigger: "cron",
            scope: "each",
          },
        ],
      };
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(reg));
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["p-soon", "p-later"]));

      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("next-runs", ["--within", "30m"], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(0);
      const out = stdout.join("");
      expect(out).toContain("p-soon");
      expect(out).not.toContain("p-later");
      expect(out).toContain("NEXT FIRE");
      expect(out).toContain("IN");
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs --json emits structured json", () => {
    const fix = setupFixture();
    try {
      const reg = {
        schema_version: 3,
        playbooks: [
          {
            name: "p-soon",
            schedule: "10 12 * * *",
            status: "active",
            trigger: "cron",
            scope: "each",
          },
        ],
      };
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(reg));
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["p-soon"]));

      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("next-runs", ["--json"], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(0);
      const json = JSON.parse(stdout.join(""));
      expect(json.nextRuns).toHaveLength(1);
      expect(json.nextRuns[0].name).toBe("p-soon");
      expect(json.nextRuns[0].nextFireIso).toBeDefined();
    } finally {
      fix.cleanup();
    }
  });

  test("status exits with STALE_EXIT_CODE when daemon is stale", () => {
    const fix = setupFixture();
    try {
      const reg = {
        schema_version: 3,
        playbooks: [
          {
            name: "p1",
            schedule: "0 9 * * *",
            status: "active",
            trigger: "cron",
            scope: "each",
          },
        ],
      };
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(reg));
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["p1"]));
      // Heartbeat older than HEARTBEAT_STALE_MS (600_000ms = 10m)
      mkdirSync(`${fix.home}/.ceo/schedulerd`, { recursive: true });
      writeFileSync(
        `${fix.home}/.ceo/schedulerd/heartbeat.json`,
        JSON.stringify({ ts: NOW.getTime() - 900_000, host: "testhost", last_fired: {}, dispatched_minute: {} })
      );

      const stdout: string[] = [];
      const stderr: string[] = [];
      const rc = runCeoStatusCommand("status", [], {
        now: () => NOW,
        out: (s) => stdout.push(s),
        err: (s) => stderr.push(s),
        env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
      });
      expect(rc).toBe(STALE_EXIT_CODE);
      expect(stderr.join("")).toContain("ALERT: daemon heartbeat stale");
      expect(stdout.join("")).toContain("STALE — heartbeat 15m ago");
    } finally {
      fix.cleanup();
    }
  });
});
