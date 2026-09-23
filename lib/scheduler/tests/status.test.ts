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

describe("runCeoStatusCommand — degraded inputs", () => {
  const NOW = new Date("2026-06-07T12:00:00Z");

  const fixture = () => {
    const testDir = `${tmpdir()}/ceo-status-degraded-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const home = `${testDir}/home`;
    const vault = `${testDir}/vault`;
    mkdirSync(`${home}/.ceo`, { recursive: true });
    mkdirSync(`${vault}/CEO`, { recursive: true });
    return { home, vault, cleanup: () => rmSync(testDir, { recursive: true, force: true }) };
  };

  const REGISTRY = {
    schema_version: 3,
    playbooks: [
      { name: "single-job", schedule: "0 9 * * *", status: "active", trigger: "cron", scope: "single" },
      { name: "each-job", schedule: "10 12 * * *", status: "active", trigger: "cron", scope: "each" },
    ],
  };

  const run = (
    fix: { home: string; vault: string },
    sub: "status" | "next-runs",
    args: string[] = []
  ) => {
    const stdout: string[] = [];
    const stderr: string[] = [];
    const rc = runCeoStatusCommand(sub, args, {
      now: () => NOW,
      out: (s) => stdout.push(s),
      err: (s) => stderr.push(s),
      env: { HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
    });
    return { rc, out: stdout.join(""), err: stderr.join("") };
  };

  const seed = (fix: { home: string; vault: string }) => {
    writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify(REGISTRY));
    writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["each-job"]));
    writeFileSync(
      `${fix.vault}/CEO/swarm.json`,
      JSON.stringify({ hosts: ["testhost"], owners: { "single-job": "testhost" } })
    );
  };

  const staleHeartbeat = (fix: { home: string }) => {
    mkdirSync(`${fix.home}/.ceo/schedulerd`, { recursive: true });
    writeFileSync(
      `${fix.home}/.ceo/schedulerd/heartbeat.json`,
      JSON.stringify({ ts: NOW.getTime() - 900_000, host: "testhost", last_fired: {}, dispatched_minute: {} })
    );
  };

  test("next-runs alerts and exits STALE_EXIT_CODE on a dead daemon", () => {
    const fix = fixture();
    try {
      seed(fix);
      staleHeartbeat(fix);
      const r = run(fix, "next-runs");
      expect(r.rc).toBe(STALE_EXIT_CODE);
      expect(r.err).toContain("ALERT: daemon heartbeat stale");
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs --json carries the daemon state a caller needs to distrust the projection", () => {
    const fix = fixture();
    try {
      seed(fix);
      staleHeartbeat(fix);
      const r = run(fix, "next-runs", ["--json"]);
      const json = JSON.parse(r.out);
      expect(json.daemonStale).toBe(true);
      expect(json.heartbeatAgeMs).toBe(900_000);
      expect(json.heartbeatState).toBe("ok");
      expect(json.host).toBe("testhost");
    } finally {
      fix.cleanup();
    }
  });

  test("an unparseable enabled.json is named, not silently read as nothing enabled", () => {
    const fix = fixture();
    try {
      seed(fix);
      writeFileSync(`${fix.home}/.ceo/enabled.json`, "{oops");
      const r = run(fix, "status");
      expect(r.err).toContain("enabled file present but unparseable");
      expect(r.out).toMatch(/each-job\s+each\s+no/);
    } finally {
      fix.cleanup();
    }
  });

  test("an enabled.json that is not an array is named", () => {
    const fix = fixture();
    try {
      seed(fix);
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify({ "each-job": true }));
      const r = run(fix, "status");
      expect(r.err).toContain("enabled file is not a JSON array");
    } finally {
      fix.cleanup();
    }
  });

  test("an absent swarm.json is named, since it flips every single-scope job", () => {
    const fix = fixture();
    try {
      seed(fix);
      rmSync(`${fix.vault}/CEO/swarm.json`);
      const r = run(fix, "status");
      expect(r.err).toContain("no swarm file at");
      expect(r.err).toContain("single-scope playbook will report not-runnable");
      expect(r.out).toMatch(/single-job\s+single\s+no/);
    } finally {
      fix.cleanup();
    }
  });

  test("an unparseable swarm.json is named", () => {
    const fix = fixture();
    try {
      seed(fix);
      writeFileSync(`${fix.vault}/CEO/swarm.json`, "{torn");
      const r = run(fix, "status");
      expect(r.err).toContain("swarm file present but unparseable");
    } finally {
      fix.cleanup();
    }
  });

  test("a corrupt heartbeat is not reported as an absent one", () => {
    const fix = fixture();
    try {
      seed(fix);
      mkdirSync(`${fix.home}/.ceo/schedulerd`, { recursive: true });
      writeFileSync(`${fix.home}/.ceo/schedulerd/heartbeat.json`, "{trunc");
      const r = run(fix, "status");
      expect(r.err).toContain("heartbeat file present but unparseable");
      expect(r.out).toContain("daemon: heartbeat file unreadable");
      expect(r.out).not.toContain("never checked in");
    } finally {
      fix.cleanup();
    }
  });

  test("an absent heartbeat reads as never checked in", () => {
    const fix = fixture();
    try {
      seed(fix);
      const r = run(fix, "status");
      expect(r.out).toContain("daemon: never checked in");
    } finally {
      fix.cleanup();
    }
  });

  test("a registry with no playbooks key is not reported as an empty fleet", () => {
    const fix = fixture();
    try {
      seed(fix);
      writeFileSync(`${fix.home}/.ceo/registry.json`, JSON.stringify({ schema_version: 3, jobs: [] }));
      const r = run(fix, "status");
      expect(r.err).toContain("no playbooks in registry at");
      expect(r.err).toContain("ceo playbook scan");
    } finally {
      fix.cleanup();
    }
  });

  test("an unparseable registry fails loudly for both subcommands", () => {
    const fix = fixture();
    try {
      seed(fix);
      writeFileSync(`${fix.home}/.ceo/registry.json`, "{not json");
      expect(run(fix, "status").rc).toBe(1);
      const r = run(fix, "next-runs");
      expect(r.rc).toBe(1);
      expect(r.err).toContain("registry error");
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs fails on a missing registry, as status does", () => {
    const fix = fixture();
    try {
      const r = run(fix, "next-runs");
      expect(r.rc).toBe(1);
      expect(r.err).toContain("No registry found");
    } finally {
      fix.cleanup();
    }
  });

  test("status --json emits a projected shape, not cronbird's report verbatim", () => {
    const fix = fixture();
    try {
      seed(fix);
      const json = JSON.parse(run(fix, "status", ["--json"]).out);
      expect(Object.keys(json).sort()).toEqual(
        ["daemonStale", "heartbeatAgeMs", "heartbeatState", "host", "jobs", "now"].sort()
      );
      expect(Object.keys(json.jobs[0]).sort()).toEqual(
        ["health", "isActive", "lastFired", "name", "nextFire", "runnable", "schedule", "scope"].sort()
      );
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs says so when the window is empty, and emits an empty list in json", () => {
    const fix = fixture();
    try {
      seed(fix);
      const text = run(fix, "next-runs", ["--within", "1m"]);
      expect(text.out).toContain("no upcoming runs in window");
      const json = JSON.parse(run(fix, "next-runs", ["--within", "1m", "--json"]).out);
      expect(json.nextRuns).toEqual([]);
    } finally {
      fix.cleanup();
    }
  });

  test("next-runs orders by next fire time", () => {
    const fix = fixture();
    try {
      writeFileSync(
        `${fix.home}/.ceo/registry.json`,
        JSON.stringify({
          schema_version: 3,
          playbooks: [
            { name: "later", schedule: "0 18 * * *", status: "active", trigger: "cron", scope: "each" },
            { name: "sooner", schedule: "10 12 * * *", status: "active", trigger: "cron", scope: "each" },
          ],
        })
      );
      writeFileSync(`${fix.home}/.ceo/enabled.json`, JSON.stringify(["later", "sooner"]));
      const json = JSON.parse(run(fix, "next-runs", ["--json"]).out);
      expect(json.nextRuns.map((j: { name: string }) => j.name)).toEqual(["sooner", "later"]);
    } finally {
      fix.cleanup();
    }
  });

  test("an empty HOME is refused rather than resolved to /.ceo", () => {
    const stderr: string[] = [];
    const rc = runCeoStatusCommand("status", [], {
      now: () => NOW,
      out: () => {},
      err: (s) => stderr.push(s),
      env: { CEO_HOSTNAME: "testhost" },
    });
    expect(rc).toBe(1);
    expect(stderr.join("")).toContain("HOME is not set");
  });
});

describe("parseFlags — argument strictness", () => {
  const deps = () => {
    const stdout: string[] = [];
    const stderr: string[] = [];
    return {
      now: () => new Date("2026-06-07T12:00:00Z"),
      out: (s: string) => stdout.push(s),
      err: (s: string) => stderr.push(s),
      env: {},
      stdout,
      stderr,
    };
  };

  test("rejects a positional argument instead of ignoring it", () => {
    const d = deps();
    expect(parseFlags("next-runs", ["30m"], d)).toBe(2);
    expect(d.stderr.join("")).toContain("unexpected argument: 30m");
  });

  test("rejects a short flag", () => {
    const d = deps();
    expect(parseFlags("status", ["-j"], d)).toBe(2);
    expect(d.stderr.join("")).toContain("unknown flag: -j");
  });

  test("--within with no value says what it wants, not 'undefined'", () => {
    const d = deps();
    expect(parseFlags("next-runs", ["--within"], d)).toBe(2);
    const err = d.stderr.join("");
    expect(err).toContain("--within requires a duration");
    expect(err).not.toContain("undefined");
  });
});

describe("table sanitization", () => {
  test("neutralizes control characters in registry-sourced cells", () => {
    const esc = String.fromCharCode(27);
    expect(table([[`a${esc}[31mb`], ["c\nd"]])).toBe("a?[31mb\nc?d\n");
  });

  test("widths cover rows longer than the header", () => {
    expect(table([["A"], ["1", "22", "x"], ["3", "4", "yy"]])).toBe("A\n1  22  x\n3  4   yy\n");
  });
});

// The shell suite stubs `bun`, so nothing else covers the file's own argv
// dispatch. This arm runs under the scheduler CI job, which has bun + cronbird.
describe("src/status.ts entry point", () => {
  const scriptDir = `${import.meta.dir}/..`;

  const fixture = () => {
    const testDir = `${tmpdir()}/ceo-status-e2e-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const home = `${testDir}/home`;
    const vault = `${testDir}/vault`;
    mkdirSync(`${home}/.ceo`, { recursive: true });
    mkdirSync(`${vault}/CEO`, { recursive: true });
    writeFileSync(
      `${home}/.ceo/registry.json`,
      JSON.stringify({
        schema_version: 3,
        playbooks: [
          { name: "each-job", schedule: "*/30 * * * *", status: "active", trigger: "cron", scope: "each" },
        ],
      })
    );
    writeFileSync(`${home}/.ceo/enabled.json`, JSON.stringify(["each-job"]));
    writeFileSync(`${vault}/CEO/swarm.json`, JSON.stringify({ hosts: ["testhost"], owners: {} }));
    return { home, vault, cleanup: () => rmSync(testDir, { recursive: true, force: true }) };
  };

  const spawn = (fix: { home: string; vault: string }, args: string[]) =>
    Bun.spawnSync({
      cmd: ["bun", "run", "src/status.ts", ...args],
      cwd: scriptDir,
      env: { ...process.env, HOME: fix.home, CEO_VAULT: fix.vault, CEO_HOSTNAME: "testhost" },
    });

  test("runs the subcommand named on argv, not the default one", () => {
    const fix = fixture();
    try {
      const proc = spawn(fix, ["next-runs", "--json"]);
      expect(proc.exitCode).toBe(0);
      const json = JSON.parse(new TextDecoder().decode(proc.stdout));
      expect(json.nextRuns).toBeDefined();
      expect(json.jobs).toBeUndefined();
    } finally {
      fix.cleanup();
    }
  });

  test("an unrecognized subcommand is rejected, not read as a status flag", () => {
    const fix = fixture();
    try {
      const proc = spawn(fix, ["bogus"]);
      expect(proc.exitCode).toBe(2);
      expect(new TextDecoder().decode(proc.stderr)).toContain("unexpected argument: bogus");
    } finally {
      fix.cleanup();
    }
  });
});
