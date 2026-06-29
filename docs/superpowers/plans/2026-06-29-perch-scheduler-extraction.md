# Perch Scheduler Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the generic scheduling engine from `claude-ceo/lib/scheduler/` (`ceo-schedulerd`) into a standalone repo `perch`, leaving CEO as a thin adapter, with no observable behavior change for CEO and no disruption to the live ML-1/MacBook daemons. Closes nhangen/claude-ceo#224.

**Architecture:** The existing daemon is already dependency-injected (`runForever(deps: DaemonDeps)` takes `loadRegistry`/`loadEnabled`/`loadSwarm`/`dispatch`/`readHeartbeat`/`writeHeartbeat` as functions). Extraction is therefore (1) generalize the CEO-named types (`Playbook` → `Job<T>`, `Swarm` → `Topology`) in a new `perch` package's `core` export, (2) ship a generic file-config runner as `perch/cli` (config parser + file providers + `ShellDispatcher` + file heartbeat store), and (3) rewrite CEO's `lib/scheduler` as an adapter importing from `perch/core`, deleting the now-duplicated modules in the same commit.

**Tech Stack:** Bun, TypeScript, `croner` ^9 (runtime dep), `bun test`, GitHub Actions CI.

## Global Constraints

- Standalone **private** repo `nhangen/perch`; **single package** named `perch` with subpath exports `perch/core` and `perch/cli` (no two-package split in v1).
- `croner` ^9 in the package's **runtime** `dependencies` (not devDependencies) — consumers must not hit a missing-croner crash-loop.
- The new repo has its **own `tsconfig.json`**; migrated source's `@/*` path aliases are rewritten to **package-relative** imports (no `@/*` aliases in `perch`).
- Dispatch is a **shell command** (argv template), never an in-process function in the generic path. `ShellDispatcher` spawns `[...dispatchCommand, ...argsTemplate-with-{job}-substituted]` with NO shell (`Bun.spawn` of an argv array), matching the existing `dispatchArgv` contract.
- A dispatch error must be **caught and logged, never thrown** out of the loop (preserves the at-most-once-over-double-fire invariant).
- The guard + `last_fired` are persisted in the heartbeat **before** any dispatch — do not reorder.
- CEO consumes `perch` via a **path dependency** (`"perch": "file:../perch"`); `perch` is checked out side-by-side with `claude-ceo` on every daemon host and in CI. No git-URL/private-auth dependency in v1.
- CEO's adapter keeps its on-disk paths, env (`CEO_VAULT`/`HOME`/`CEO_HOSTNAME`/`CEO_CRON_BIN`/`CEO_SCHEDULERD_CATCHUP_LOOKBACK_MS`), dispatch argv, resolved hostname, and the `com.ceo.schedulerd` launchd label **byte-for-byte unchanged**.
- No commits say "claude", "co-authored", or "anthropic".
- Test before every commit; pushing requires explicit user approval.

---

### Task 1: Scaffold the `perch` repo

**Files:**
- Create: `~/code/perch/package.json`
- Create: `~/code/perch/tsconfig.json`
- Create: `~/code/perch/.gitignore`
- Create: `~/code/perch/README.md`
- Create: `~/code/perch/.github/workflows/ci.yml`
- Create: `~/code/perch/src/core/.gitkeep`, `~/code/perch/src/cli/.gitkeep`, `~/code/perch/tests/.gitkeep`

**Interfaces:**
- Consumes: nothing (greenfield repo).
- Produces: the `perch` package skeleton with `exports` map `{"./core": "./src/core/index.ts", "./cli": "./src/cli/index.ts"}`, a `bun test` script, and `bun run typecheck` (`tsc --noEmit`). Later tasks fill `src/core/` and `src/cli/`.

- [ ] **Step 1: Create the repo directory and init git**

```bash
mkdir -p ~/code/perch/src/core ~/code/perch/src/cli ~/code/perch/tests ~/code/perch/.github/workflows ~/code/perch/deploy
cd ~/code/perch && git init -q && touch src/core/.gitkeep src/cli/.gitkeep tests/.gitkeep
```

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "perch",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "exports": {
    "./core": "./src/core/index.ts",
    "./cli": "./src/cli/index.ts"
  },
  "scripts": {
    "test": "bun test",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "croner": "^9.1.0"
  },
  "devDependencies": {
    "typescript": "^5.4.0",
    "@types/bun": "latest"
  }
}
```

- [ ] **Step 3: Write `tsconfig.json` (no `@/*` aliases)**

```json
{
  "compilerOptions": {
    "lib": ["ESNext"],
    "module": "ESNext",
    "target": "ESNext",
    "moduleResolution": "bundler",
    "types": ["bun-types"],
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src", "tests"]
}
```

- [ ] **Step 4: Write `.gitignore`**

```
node_modules/
*.log
.DS_Store
```

- [ ] **Step 5: Write a stub `README.md`** (filled out fully in Task 3 once the config + CLI exist)

```markdown
# perch

A host-aware cron scheduler daemon. Matches 5-field cron schedules, decides which jobs are due on this host, replays the newest missed slot after an outage, and guarantees at-most-once dispatch via a persisted double-fire guard.

- `perch/core` — the engine (zero deps beyond croner).
- `perch/cli` — a generic file-config runner: point it at a registry JSON + a dispatch command and run it under launchd/systemd, no code required.

Status: under construction (extracted from claude-ceo's ceo-schedulerd).
```

- [ ] **Step 6: Write CI workflow `.github/workflows/ci.yml`**

```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: latest
      - run: bun install
      - run: bun run typecheck
      - run: bun test
```

- [ ] **Step 7: Install deps and verify the skeleton builds**

Run: `cd ~/code/perch && bun install && bun run typecheck`
Expected: `bun install` succeeds (creates `node_modules/croner`); `tsc --noEmit` exits 0 (no source yet, nothing to typecheck).

- [ ] **Step 8: Commit**

```bash
cd ~/code/perch
git add -A
git commit -m "chore: scaffold perch package (exports, tsconfig, CI, README stub)"
```

---

### Task 2: Move the engine into `perch/core`

Move the already-generic + CEO-typed engine modules from `claude-ceo/lib/scheduler/src/` into `~/code/perch/src/core/`, generalize the CEO-named types (`Playbook` → `Job<T>`, `Swarm` → `Topology`), rewrite `@/*` imports to relative, and migrate the engine tests. The logic does not change — only type names, import paths, and the addition of a `metadata: T` passthrough.

**Files:**
- Create: `~/code/perch/src/core/types.ts`
- Create: `~/code/perch/src/core/cron.ts` (moved from `lib/scheduler/src/cron.ts`, imports rewritten)
- Create: `~/code/perch/src/core/select.ts` (moved from `lib/scheduler/src/select.ts`)
- Create: `~/code/perch/src/core/catchup.ts` (moved from `lib/scheduler/src/catchup.ts`)
- Create: `~/code/perch/src/core/daemon.ts` (moved from `lib/scheduler/src/daemon.ts`)
- Create: `~/code/perch/src/core/index.ts` (barrel: re-exports the public core surface)
- Create: `~/code/perch/tests/{cron,select,catchup,daemon}.test.ts` (moved from `lib/scheduler/tests/`)

**Interfaces:**
- Consumes: nothing from earlier tasks (uses croner from Task 1's deps).
- Produces, in `perch/core`:
  - `interface Job<T = unknown> { name: string; cronSchedule: string; isActive: boolean; hosts: string[]; scope: "each" | "single"; metadata: T }`
  - `interface Topology { hosts: string[]; owners: Record<string, string> }`
  - `interface Heartbeat { ts: number; host: string; runnable_count: number; next_wake_ts: number; last_dispatch: { name: string; ts: number }[]; dispatched_minute: Record<string, number>; last_fired: Record<string, number> }`
  - `interface DaemonDeps<T = unknown>` — same shape as today's `DaemonDeps` but `loadRegistry()` returns `{ jobs: Job<T>[]; warnings: string[] }`, `loadTopology()` returns `Topology | null` (renamed from `loadSwarm`), and `dispatch(name: string): void`.
  - `function runForever<T>(deps: DaemonDeps<T>): Promise<void>`
  - `createMatcher`, `CronMatcher`, `selectRunnable`, `dueAt`, `nextWake`, `catchUpFires`, `lookbackForSchedule` (re-exported from their modules, generalized to `Job<T>`).

- [ ] **Step 1: Inspect the source modules to be moved**

Run: `ls -la ~/code/claude-ceo/lib/scheduler/src/ && wc -l ~/code/claude-ceo/lib/scheduler/src/{cron,select,catchup,daemon,registry,swarm}.ts`
Expected: lists `cron.ts select.ts catchup.ts daemon.ts registry.ts swarm.ts enabled.ts heartbeat-store.ts runtime.ts main.ts` with line counts. Read `select.ts`, `catchup.ts`, `cron.ts` in full before moving — you must preserve their logic exactly and only change `Playbook`→`Job<T>` / `Swarm`→`Topology` type references and `@/*`→relative imports.

- [ ] **Step 2: Write `src/core/types.ts`** (the generalized types that replace `Playbook` from `registry.ts` and `Swarm` from `swarm.ts`)

```typescript
export interface Job<T = unknown> {
  name: string;
  /** 5-field cron expression, evaluated in the host's local timezone. */
  cronSchedule: string;
  /** Only active jobs fire. */
  isActive: boolean;
  /** ["*"] = every host; ["ml-1"] = this host only. */
  hosts: string[];
  /** "each" → fires where enabled; "single" → fires on its topology owner. */
  scope: "each" | "single";
  /** Product-specific fields the engine ignores (model, tier, runner, ...). */
  metadata: T;
}

export interface Topology {
  hosts: string[];
  /** jobName → owning host (for scope:"single"). */
  owners: Record<string, string>;
}

export interface DispatchRecord {
  name: string;
  ts: number;
}

export interface Heartbeat {
  ts: number;
  host: string;
  runnable_count: number;
  next_wake_ts: number;
  last_dispatch: DispatchRecord[];
  /** jobName → epoch-minute last dispatched (durable double-fire guard). */
  dispatched_minute: Record<string, number>;
  /** jobName → epoch-ms of the newest slot fired (drives catch-up). */
  last_fired: Record<string, number>;
}
```

- [ ] **Step 3: Move `cron.ts` and rewrite its imports**

```bash
git -C ~/code/claude-ceo mv lib/scheduler/src/cron.ts /dev/null 2>/dev/null || true
cp ~/code/claude-ceo/lib/scheduler/src/cron.ts ~/code/perch/src/core/cron.ts
```
Then edit `~/code/perch/src/core/cron.ts`: replace any `from "@/..."` import with the relative equivalent (e.g. `from "@/runtime"` → `from "./runtime-consts"` if needed; `cron.ts` has no CEO imports per research, so likely only self-contained croner usage — verify and leave logic untouched).

- [ ] **Step 4: Move `select.ts`, `catchup.ts`, `daemon.ts`; rewrite types + imports**

```bash
cp ~/code/claude-ceo/lib/scheduler/src/select.ts   ~/code/perch/src/core/select.ts
cp ~/code/claude-ceo/lib/scheduler/src/catchup.ts  ~/code/perch/src/core/catchup.ts
cp ~/code/claude-ceo/lib/scheduler/src/daemon.ts   ~/code/perch/src/core/daemon.ts
```
In each: rewrite `import ... from "@/cron"` → `from "./cron"`, `from "@/select"` → `from "./select"`, `from "@/catchup"` → `from "./catchup"`. Replace `import type { Playbook } from "@/registry"` → `import type { Job } from "./types"` and substitute `Playbook` → `Job<T>` (add `<T = unknown>` generic to `selectRunnable`, `dueAt`, `nextWake`, `catchUpFires`, `DaemonDeps`, `runForever`). Replace `import type { Swarm } from "@/swarm"` → `import type { Topology, Heartbeat } from "./types"` and rename the dep `loadSwarm()` → `loadTopology()` returning `Topology | null`; update the one call site in `daemon.ts` (`const swarm = deps.loadSwarm()` → `const topology = deps.loadTopology()`, `if (topology !== null) lastGoodOwners = topology.owners`). Move the `Heartbeat`/`DispatchRecord` interface definitions out of `daemon.ts` (they now live in `types.ts`) and import them. **Do not change any control-flow, guard ordering, or arithmetic.**

- [ ] **Step 5: Write the `src/core/index.ts` barrel**

```typescript
export type { Job, Topology, Heartbeat, DispatchRecord } from "./types";
export { createMatcher } from "./cron";
export type { CronMatcher } from "./cron";
export { selectRunnable, dueAt, nextWake } from "./select";
export { catchUpFires, lookbackForSchedule } from "./catchup";
export { runForever } from "./daemon";
export type { DaemonDeps } from "./daemon";
```

- [ ] **Step 6: Move the engine tests and rewrite their imports/types**

```bash
cp ~/code/claude-ceo/lib/scheduler/tests/cron.test.ts    ~/code/perch/tests/cron.test.ts
cp ~/code/claude-ceo/lib/scheduler/tests/select.test.ts  ~/code/perch/tests/select.test.ts
cp ~/code/claude-ceo/lib/scheduler/tests/catchup.test.ts ~/code/perch/tests/catchup.test.ts
cp ~/code/claude-ceo/lib/scheduler/tests/daemon.test.ts  ~/code/perch/tests/daemon.test.ts
```
Rewrite test imports `@/cron`→`../src/core/cron` (etc.), and any test fixture that builds a `Playbook` literal `{name, schedule, status, trigger, hosts, scope}` → a `Job` literal `{name, cronSchedule, isActive, hosts, scope, metadata: {}}`. The field renames are: `schedule`→`cronSchedule`, `status: "active"`→`isActive: true`, drop `trigger` (the engine no longer reads it — host/scope/isActive are the only gates), add `metadata`. Update every fixture; do not change any assertion's expected values.

- [ ] **Step 7: Run the migrated engine tests and typecheck**

Run: `cd ~/code/perch && bun run typecheck && bun test`
Expected: typecheck exits 0; all migrated `cron`/`select`/`catchup`/`daemon` tests PASS with the same counts as in claude-ceo (the logic is unchanged). If a daemon test fails, the cause is a type-rename slip in Step 4/6, not a logic change — fix the rename.

- [ ] **Step 8: Commit**

```bash
cd ~/code/perch
git add -A
git commit -m "feat(core): engine extracted from ceo-schedulerd, generalized to Job<T>/Topology"
```

---

### Task 3: Build the generic `perch/cli` runner

Ship the product-agnostic runtime: a validated config parser, file-backed providers (registry/enabled/topology JSON), a file heartbeat store (with optional synced dual-write), a `ShellDispatcher`, and a `main.ts` that wires them into `runForever`. This is what lets a non-TS project run perch with zero code.

**Files:**
- Create: `~/code/perch/src/cli/config.ts`
- Create: `~/code/perch/src/cli/providers.ts`
- Create: `~/code/perch/src/cli/heartbeat-file.ts`
- Create: `~/code/perch/src/cli/shell-dispatcher.ts`
- Create: `~/code/perch/src/cli/main.ts`
- Create: `~/code/perch/src/cli/index.ts`
- Create: `~/code/perch/tests/{config,providers,heartbeat-file,shell-dispatcher}.test.ts`
- Create: `~/code/perch/deploy/perch.plist.template`, `~/code/perch/deploy/perch.service.template`
- Modify: `~/code/perch/README.md` (full config reference + quickstart)

**Interfaces:**
- Consumes from `perch/core` (Task 2): `Job`, `Topology`, `Heartbeat`, `DaemonDeps`, `runForever`, `createMatcher`, `lookbackForSchedule`.
- Produces:
  - `interface PerchConfig { hostname: string; registryPath: string; enabledPath: string | null; topologyPath: string | null; heartbeatPath: string; syncedHeartbeatDir: string | null; dispatchCommand: string[]; dispatchArgsTemplate: string[]; maxSleepMs: number; catchupLookbackFloorMs: number; catchupLookbackCapMs: number }`
  - `function parseConfig(raw: string, env: Record<string,string|undefined>): PerchConfig` (throws `ConfigError` on invalid; resolves `"auto"` hostname to `os.hostname().split(".")[0]`; `~`-expands paths).
  - `class ShellDispatcher { constructor(command: string[], argsTemplate: string[], log: (m: string) => void); dispatch(jobName: string): void }`
  - `function fileJobProvider(registryPath: string): () => { jobs: Job[]; warnings: string[] }` and matching `fileEnabledProvider`, `fileTopologyProvider`.

- [ ] **Step 1: Write the failing test for `ShellDispatcher` argv contract**

`~/code/perch/tests/shell-dispatcher.test.ts`:

```typescript
import { describe, expect, test } from "bun:test";
import { ShellDispatcher } from "../src/cli/shell-dispatcher";

describe("ShellDispatcher", () => {
  test("builds argv as [...command, ...template with {job} substituted]", () => {
    const calls: string[][] = [];
    const d = new ShellDispatcher(["ceo-cron.sh"], ["{job}", "--scheduled"], () => {}, (argv) => {
      calls.push(argv);
    });
    d.dispatch("morning-scan");
    expect(calls).toEqual([["ceo-cron.sh", "morning-scan", "--scheduled"]]);
  });

  test("a spawn error is caught and logged, never thrown", () => {
    const logs: string[] = [];
    const d = new ShellDispatcher(["x"], ["{job}"], (m) => logs.push(m), () => {
      throw new Error("ENOENT");
    });
    expect(() => d.dispatch("job1")).not.toThrow();
    expect(logs.some((l) => l.includes("dispatch failed") && l.includes("job1"))).toBe(true);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ~/code/perch && bun test tests/shell-dispatcher.test.ts`
Expected: FAIL — `Cannot find module '../src/cli/shell-dispatcher'`.

- [ ] **Step 3: Implement `ShellDispatcher`** with an injectable spawn so the argv contract is testable without a real process

`~/code/perch/src/cli/shell-dispatcher.ts`:

```typescript
export type SpawnFn = (argv: string[]) => void;

const defaultSpawn: SpawnFn = (argv) => {
  const proc = Bun.spawn(argv, { stdout: "ignore", stderr: "ignore", stdin: "ignore" });
  proc.unref();
};

export class ShellDispatcher {
  constructor(
    private command: string[],
    private argsTemplate: string[],
    private log: (msg: string) => void,
    private spawn: SpawnFn = defaultSpawn,
  ) {}

  private argv(jobName: string): string[] {
    return [...this.command, ...this.argsTemplate.map((a) => (a === "{job}" ? jobName : a))];
  }

  dispatch(jobName: string): void {
    try {
      this.spawn(this.argv(jobName));
      this.log(`dispatched ${jobName}`);
    } catch (err) {
      this.log(`dispatch failed for ${jobName}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/code/perch && bun test tests/shell-dispatcher.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing test for `parseConfig`** (validation per the `enum-config-typo-fallback` rule — reject invalid, don't default-coerce)

`~/code/perch/tests/config.test.ts`:

```typescript
import { describe, expect, test } from "bun:test";
import { parseConfig, ConfigError } from "../src/cli/config";

const base = {
  registryPath: "/r.json", enabledPath: null, topologyPath: null,
  heartbeatPath: "/hb.json", syncedHeartbeatDir: null,
  dispatchCommand: ["run.sh"], dispatchArgsTemplate: ["{job}"],
  maxSleepMs: 60000, catchupLookbackFloorMs: 3600000, catchupLookbackCapMs: 21600000,
};

describe("parseConfig", () => {
  test("resolves hostname 'auto' to the short os hostname", () => {
    const c = parseConfig(JSON.stringify({ ...base, hostname: "auto" }), {});
    expect(c.hostname).not.toBe("auto");
    expect(c.hostname.length).toBeGreaterThan(0);
  });

  test("a literal hostname is kept verbatim", () => {
    const c = parseConfig(JSON.stringify({ ...base, hostname: "ml-1" }), {});
    expect(c.hostname).toBe("ml-1");
  });

  test("missing dispatchCommand throws ConfigError, not a silent default", () => {
    const bad = { ...base, hostname: "ml-1" } as Record<string, unknown>;
    delete bad.dispatchCommand;
    expect(() => parseConfig(JSON.stringify(bad), {})).toThrow(ConfigError);
  });

  test("~-prefixed paths expand against env.HOME", () => {
    const c = parseConfig(JSON.stringify({ ...base, hostname: "ml-1", registryPath: "~/.perch/r.json" }), { HOME: "/home/x" });
    expect(c.registryPath).toBe("/home/x/.perch/r.json");
  });
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd ~/code/perch && bun test tests/config.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 7: Implement `config.ts`**

`~/code/perch/src/cli/config.ts`:

```typescript
import { hostname as osHostname } from "node:os";

export class ConfigError extends Error {}

export interface PerchConfig {
  hostname: string;
  registryPath: string;
  enabledPath: string | null;
  topologyPath: string | null;
  heartbeatPath: string;
  syncedHeartbeatDir: string | null;
  dispatchCommand: string[];
  dispatchArgsTemplate: string[];
  maxSleepMs: number;
  catchupLookbackFloorMs: number;
  catchupLookbackCapMs: number;
}

function expandTilde(p: string, home: string | undefined): string {
  if (!p.startsWith("~")) return p;
  if (!home) throw new ConfigError(`cannot expand '~' in path without HOME: ${p}`);
  return p.replace(/^~/, home);
}

function reqString(o: Record<string, unknown>, k: string): string {
  const v = o[k];
  if (typeof v !== "string" || v.length === 0) throw new ConfigError(`config.${k} must be a non-empty string`);
  return v;
}

function optString(o: Record<string, unknown>, k: string): string | null {
  const v = o[k];
  if (v === null || v === undefined) return null;
  if (typeof v !== "string" || v.length === 0) throw new ConfigError(`config.${k} must be a non-empty string or null`);
  return v;
}

function reqStringArray(o: Record<string, unknown>, k: string): string[] {
  const v = o[k];
  if (!Array.isArray(v) || v.length === 0 || v.some((x) => typeof x !== "string")) {
    throw new ConfigError(`config.${k} must be a non-empty array of strings`);
  }
  return v as string[];
}

function reqPosInt(o: Record<string, unknown>, k: string): number {
  const v = o[k];
  if (typeof v !== "number" || !Number.isInteger(v) || v <= 0) throw new ConfigError(`config.${k} must be a positive integer`);
  return v;
}

export function parseConfig(raw: string, env: Record<string, string | undefined>): PerchConfig {
  let o: Record<string, unknown>;
  try {
    o = JSON.parse(raw) as Record<string, unknown>;
  } catch (e) {
    throw new ConfigError(`config is not valid JSON: ${e instanceof Error ? e.message : String(e)}`);
  }
  const home = env.HOME;
  const rawHost = reqString(o, "hostname");
  const hostname = rawHost === "auto" ? (osHostname().split(".")[0] ?? "unknown") : rawHost;
  return {
    hostname,
    registryPath: expandTilde(reqString(o, "registryPath"), home),
    enabledPath: optString(o, "enabledPath") ? expandTilde(o.enabledPath as string, home) : null,
    topologyPath: optString(o, "topologyPath") ? expandTilde(o.topologyPath as string, home) : null,
    heartbeatPath: expandTilde(reqString(o, "heartbeatPath"), home),
    syncedHeartbeatDir: optString(o, "syncedHeartbeatDir") ? expandTilde(o.syncedHeartbeatDir as string, home) : null,
    dispatchCommand: reqStringArray(o, "dispatchCommand"),
    dispatchArgsTemplate: reqStringArray(o, "dispatchArgsTemplate"),
    maxSleepMs: reqPosInt(o, "maxSleepMs"),
    catchupLookbackFloorMs: reqPosInt(o, "catchupLookbackFloorMs"),
    catchupLookbackCapMs: reqPosInt(o, "catchupLookbackCapMs"),
  };
}
```

- [ ] **Step 8: Run the config test to verify it passes**

Run: `cd ~/code/perch && bun test tests/config.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 9: Write file providers + their tests, then implement**

`~/code/perch/tests/providers.test.ts`:

```typescript
import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseJobsJson, parseEnabledJson, parseTopologyJson } from "../src/cli/providers";

describe("providers", () => {
  test("parseJobsJson maps registry entries to Job and collects warnings for bad rows", () => {
    const text = JSON.stringify({ jobs: [
      { name: "a", cronSchedule: "0 6 * * *", isActive: true, hosts: ["*"], scope: "each", metadata: {} },
      { name: "", cronSchedule: "0 6 * * *", isActive: true, hosts: ["*"], scope: "each", metadata: {} },
    ]});
    const r = parseJobsJson(text);
    expect(r.jobs.map((j) => j.name)).toEqual(["a"]);
    expect(r.warnings.length).toBe(1);
  });

  test("parseEnabledJson returns empty set on malformed input (fail-safe)", () => {
    expect(parseEnabledJson("not json").size).toBe(0);
    expect([...parseEnabledJson(JSON.stringify(["x", "y"]))].sort()).toEqual(["x", "y"]);
  });

  test("parseTopologyJson returns null on malformed input (reuse last-good)", () => {
    expect(parseTopologyJson("not json")).toBeNull();
    expect(parseTopologyJson(JSON.stringify({ hosts: ["h"], owners: { j: "h" } }))?.owners.j).toBe("h");
  });
});
```

Implement `~/code/perch/src/cli/providers.ts`:

```typescript
import { existsSync, readFileSync } from "node:fs";
import type { Job, Topology } from "../core/index";

export function parseJobsJson(text: string): { jobs: Job[]; warnings: string[] } {
  const warnings: string[] = [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { jobs: [], warnings: ["registry is not valid JSON"] };
  }
  const rows = (parsed as { jobs?: unknown }).jobs;
  if (!Array.isArray(rows)) return { jobs: [], warnings: ["registry.jobs is not an array"] };
  const jobs: Job[] = [];
  for (const r of rows) {
    const o = r as Record<string, unknown>;
    if (typeof o.name !== "string" || o.name.length === 0) { warnings.push("skipped job with missing name"); continue; }
    if (typeof o.cronSchedule !== "string") { warnings.push(`skipped ${o.name}: missing cronSchedule`); continue; }
    jobs.push({
      name: o.name,
      cronSchedule: o.cronSchedule,
      isActive: o.isActive === true,
      hosts: Array.isArray(o.hosts) && o.hosts.every((h) => typeof h === "string") && o.hosts.length > 0 ? (o.hosts as string[]) : ["*"],
      scope: o.scope === "each" ? "each" : "single",
      metadata: (o.metadata ?? {}) as unknown,
    });
  }
  return { jobs, warnings };
}

export function parseEnabledJson(text: string): Set<string> {
  try {
    const a = JSON.parse(text);
    if (Array.isArray(a)) return new Set(a.filter((x) => typeof x === "string"));
  } catch { /* fall through */ }
  return new Set();
}

export function parseTopologyJson(text: string): Topology | null {
  try {
    const o = JSON.parse(text) as Record<string, unknown>;
    const hosts = o.hosts, owners = o.owners;
    if (!Array.isArray(hosts) || typeof owners !== "object" || owners === null) return null;
    const cleanOwners: Record<string, string> = {};
    for (const [k, v] of Object.entries(owners)) if (typeof v === "string") cleanOwners[k] = v;
    return { hosts: hosts.filter((h) => typeof h === "string") as string[], owners: cleanOwners };
  } catch {
    return null;
  }
}

function readIfExists(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

export function fileJobProvider(path: string): () => { jobs: Job[]; warnings: string[] } {
  return () => parseJobsJson(readFileSync(path, "utf8"));
}
export function fileEnabledProvider(path: string | null): () => Set<string> {
  return () => (path ? parseEnabledJson(readIfExists(path)) : new Set());
}
export function fileTopologyProvider(path: string | null): () => Topology | null {
  return () => (path ? parseTopologyJson(readIfExists(path)) : null);
}
```

Run: `cd ~/code/perch && bun test tests/providers.test.ts` → Expected: PASS (3 tests).

- [ ] **Step 10: Port the heartbeat store as `heartbeat-file.ts` + migrate its test**

Copy `~/code/claude-ceo/lib/scheduler/src/heartbeat-store.ts` → `~/code/perch/src/cli/heartbeat-file.ts`; rewrite its `@/*` imports to `../core/index`; keep the read/write/atomic-rename/corruption-null logic verbatim; export the same functions (`readHeartbeatFile`, `writeHeartbeatFile`, `writeSyncedHeartbeat`, `writeHeartbeatWithSync`). Copy `tests/heartbeat-store.test.ts` → `~/code/perch/tests/heartbeat-file.test.ts`, rewrite imports.

Run: `cd ~/code/perch && bun test tests/heartbeat-file.test.ts` → Expected: PASS (same count as in claude-ceo).

- [ ] **Step 11: Write `main.ts` (generic runner) and `cli/index.ts`**

`~/code/perch/src/cli/main.ts`:

```typescript
#!/usr/bin/env bun
import { readFileSync } from "node:fs";
import { createMatcher, lookbackForSchedule, runForever, type DaemonDeps } from "../core/index";
import { parseConfig } from "./config";
import { fileJobProvider, fileEnabledProvider, fileTopologyProvider } from "./providers";
import { ShellDispatcher } from "./shell-dispatcher";
import { readHeartbeatFile, writeHeartbeatFile, writeSyncedHeartbeat, writeHeartbeatWithSync } from "./heartbeat-file";

function nowStamp(): string { return new Date().toISOString(); }

async function main(): Promise<void> {
  const configPath = process.argv[2] ?? process.env.PERCH_CONFIG;
  if (!configPath) throw new Error("usage: perch <config.json> (or set PERCH_CONFIG)");
  const cfg = parseConfig(readFileSync(configPath, "utf8"), process.env);
  const log = (m: string) => process.stderr.write(`[${nowStamp()}] perch: ${m}\n`);

  let running = true;
  let wakeEarly: (() => void) | null = null;
  const stop = (sig: string) => { log(`${sig} received, shutting down`); running = false; wakeEarly?.(); };
  process.on("SIGTERM", () => stop("SIGTERM"));
  process.on("SIGINT", () => stop("SIGINT"));

  const matcher = createMatcher();
  const dispatcher = new ShellDispatcher(cfg.dispatchCommand, cfg.dispatchArgsTemplate, log);
  const syncedHbPath = cfg.syncedHeartbeatDir ? `${cfg.syncedHeartbeatDir}/${cfg.hostname}.json` : null;

  const deps: DaemonDeps = {
    now: () => new Date(),
    sleep: (ms) => new Promise<void>((resolve) => {
      const t = setTimeout(() => { wakeEarly = null; resolve(); }, ms);
      wakeEarly = () => { clearTimeout(t); wakeEarly = null; resolve(); };
    }),
    loadRegistry: fileJobProvider(cfg.registryPath),
    loadEnabled: fileEnabledProvider(cfg.enabledPath),
    loadTopology: fileTopologyProvider(cfg.topologyPath),
    dispatch: (name) => dispatcher.dispatch(name),
    readHeartbeat: () => readHeartbeatFile(cfg.heartbeatPath),
    writeHeartbeat: (hb) => writeHeartbeatWithSync(hb, {
      writeLocal: (h) => writeHeartbeatFile(cfg.heartbeatPath, h),
      writeSynced: syncedHbPath ? () => writeSyncedHeartbeat(syncedHbPath, cfg.hostname) : () => {},
      log,
    }),
    log,
    host: cfg.hostname,
    matcher,
    maxSleepMs: cfg.maxSleepMs,
    resolveLookback: (schedule, now) => lookbackForSchedule(schedule, now, matcher, cfg.catchupLookbackFloorMs, cfg.catchupLookbackCapMs),
    shouldContinue: () => running,
  };

  log(`started — host=${cfg.hostname} registry=${cfg.registryPath}`);
  await runForever(deps);
  log("stopped");
}

main().catch((err) => {
  process.stderr.write(`[${nowStamp()}] perch: fatal: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
```

`~/code/perch/src/cli/index.ts`:

```typescript
export { parseConfig, ConfigError } from "./config";
export type { PerchConfig } from "./config";
export { ShellDispatcher } from "./shell-dispatcher";
export type { SpawnFn } from "./shell-dispatcher";
export { fileJobProvider, fileEnabledProvider, fileTopologyProvider, parseJobsJson, parseEnabledJson, parseTopologyJson } from "./providers";
export { readHeartbeatFile, writeHeartbeatFile, writeSyncedHeartbeat, writeHeartbeatWithSync } from "./heartbeat-file";
```

- [ ] **Step 12: Write deploy templates**

`~/code/perch/deploy/perch.plist.template` (launchd) and `perch.service.template` (systemd) — parameterized `__LABEL__`, `__BUN__`, `__MAIN__`, `__CONFIG__`, `__WORKDIR__` placeholders, KeepAlive on non-zero exit only, logs to `/tmp/__LABEL__.{out,err}.log`. Model them on `~/code/claude-ceo/lib/scheduler/deploy/com.ceo.schedulerd.plist` and `ceo-schedulerd.service` (read those for the exact key set), replacing `CEO_*` env with a single `PERCH_CONFIG` env pointing at the config file, and the label/paths with placeholders.

- [ ] **Step 13: Fill out `README.md`** with: engine overview, the full `perch.config.json` field reference (every field from `PerchConfig`, with the `null` = single-host-mode note), a single-host quickstart (write a registry JSON + config, run `bun perch/cli <config>`), a multi-host/topology section (`scope`/`owners`/synced heartbeat), and a deploy section pointing at the templates.

- [ ] **Step 14: Full test + typecheck**

Run: `cd ~/code/perch && bun run typecheck && bun test`
Expected: typecheck 0; ALL tests pass (engine from Task 2 + cli: shell-dispatcher 2, config 4, providers 3, heartbeat-file N).

- [ ] **Step 15: Commit**

```bash
cd ~/code/perch
git add -A
git commit -m "feat(cli): generic file-config runner — config, providers, ShellDispatcher, heartbeat, deploy templates, README"
```

---

### Task 4: CEO adapter — atomic cutover

Rewrite `claude-ceo/lib/scheduler` as a thin adapter on `perch/core`, deleting the now-duplicated generic modules **in the same commit** as the import rewrite, gated by a round-trip test proving CEO's resolved paths/argv/hostname/label are byte-identical to today. Do this on a branch in a claude-ceo worktree (per the worktree + PR rules).

**Files:**
- Modify: `~/code/claude-ceo/lib/scheduler/src/main.ts` (import `runForever`, `createMatcher`, `lookbackForSchedule` from `perch/core`; build the CEO `Job` mapping + `Topology` from the existing `parseRegistry`/`parseSwarm`)
- Modify: `~/code/claude-ceo/lib/scheduler/src/registry.ts` (its `parseRegistry` now returns `{ jobs: Job<CeoMeta>[]; warnings }` — maps CEO registry rows to `Job`, putting `model/tier/runner/file/description` into `metadata`)
- Modify: `~/code/claude-ceo/lib/scheduler/src/swarm.ts` (return `Topology` from `perch/core` instead of the local `Swarm` type)
- Delete: `~/code/claude-ceo/lib/scheduler/src/{cron,select,catchup,daemon}.ts` and `lib/scheduler/src/heartbeat-store.ts` (now in `perch`)
- Delete: the corresponding migrated tests under `lib/scheduler/tests/` that now live in `perch` (`cron/select/catchup/daemon/heartbeat-store`)
- Keep: `lib/scheduler/src/{runtime.ts, enabled.ts}` (CEO path helpers + the enabled parser stay CEO-side; or re-export enabled parsing from `perch/cli` — prefer re-export to avoid drift)
- Modify: `~/code/claude-ceo/package.json` (add `"perch": "file:../perch"` dependency)
- Create: `~/code/claude-ceo/lib/scheduler/tests/adapter-roundtrip.test.ts`

**Interfaces:**
- Consumes from `perch/core`: `runForever`, `createMatcher`, `lookbackForSchedule`, `Job`, `Topology`, `DaemonDeps`.
- Produces: a CEO `main.ts` whose injected `DaemonDeps` are byte-identical in behavior to today's — same `registryPath`/`heartbeatPath`/`swarmPath`/`syncedHeartbeatPath`, same `dispatchArgv(cronBin, name) = [cronBin, name, "--scheduled"]`, same resolved host, same `com.ceo.schedulerd` plist (untouched).

- [ ] **Step 1: Verify claude-ceo main parity and create the cutover worktree**

```bash
cd ~/code/claude-ceo && git fetch origin main -q
[ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] && echo PARITY || echo STALE
git worktree add -b nh/feat/perch-adapter-cutover ../claude-ceo-perch-cutover main
```
Expected: `PARITY`; worktree created. Do all remaining steps in `../claude-ceo-perch-cutover`.

- [ ] **Step 2: Write the failing round-trip test** (the cutover gate)

`~/code/claude-ceo-perch-cutover/lib/scheduler/tests/adapter-roundtrip.test.ts`:

```typescript
import { describe, expect, test } from "bun:test";
import { resolveAdapterConfig } from "../src/main";

describe("CEO adapter round-trip (byte-identical to pre-extraction)", () => {
  const env = { CEO_VAULT: "/vault", HOME: "/home/u", CEO_HOSTNAME: "ml-1", CEO_CRON_BIN: "ceo-cron.sh" };
  test("resolves the exact pre-extraction paths, argv, host, and label", () => {
    const c = resolveAdapterConfig(env);
    expect(c.registryPath).toBe("/home/u/.ceo/registry.json");
    expect(c.heartbeatPath).toBe("/home/u/.ceo/schedulerd/heartbeat.json");
    expect(c.swarmPath).toBe("/vault/CEO/swarm.json");
    expect(c.syncedHeartbeatPath).toBe("/vault/CEO/heartbeats/ml-1.json");
    expect(c.dispatchArgv("morning-scan")).toEqual(["ceo-cron.sh", "morning-scan", "--scheduled"]);
    expect(c.host).toBe("ml-1");
    expect(c.launchdLabel).toBe("com.ceo.schedulerd");
  });
  test("hostname falls back to short os hostname when CEO_HOSTNAME is unset", () => {
    const c = resolveAdapterConfig({ CEO_VAULT: "/v", HOME: "/h" });
    expect(c.host.length).toBeGreaterThan(0);
    expect(c.host).not.toContain(".");
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd ~/code/claude-ceo-perch-cutover && bun test lib/scheduler/tests/adapter-roundtrip.test.ts`
Expected: FAIL — `resolveAdapterConfig` not exported from `main.ts`.

- [ ] **Step 4: Add the perch path dependency**

In `~/code/claude-ceo-perch-cutover/package.json`, add `"perch": "file:../perch"` under `dependencies`. Run `bun install`.
Expected: `bun install` links `perch`; `node_modules/perch` resolves to the sibling checkout.

- [ ] **Step 5: Delete the duplicated generic modules + their tests (same commit as the rewrite)**

```bash
cd ~/code/claude-ceo-perch-cutover
git rm lib/scheduler/src/cron.ts lib/scheduler/src/select.ts lib/scheduler/src/catchup.ts lib/scheduler/src/daemon.ts lib/scheduler/src/heartbeat-store.ts
git rm lib/scheduler/tests/cron.test.ts lib/scheduler/tests/select.test.ts lib/scheduler/tests/catchup.test.ts lib/scheduler/tests/daemon.test.ts lib/scheduler/tests/heartbeat-store.test.ts
```

- [ ] **Step 6: Rewrite `registry.ts` to emit `Job<CeoMeta>` and `swarm.ts` to emit `Topology`**

In `registry.ts`: keep the file-parse + per-row validation; change the row mapping to produce `perch/core`'s `Job` shape — `cronSchedule` from the registry `schedule`, `isActive` from `status === "active"`, `hosts`/`scope` normalized as today, and `metadata: { model, tier, runner, file, description, trigger }`. Return `{ jobs, warnings }`. Define `export interface CeoMeta { model?: string; tier?: string; runner?: string; file?: string; description?: string; trigger?: string }` and import `Job` from `perch/core`.
In `swarm.ts`: import `Topology` from `perch/core`; `parseSwarm` now returns `Topology | null` (the shape is already `{ hosts, owners }`, so this is a type-import swap).

- [ ] **Step 7: Rewrite `main.ts` to import the engine from `perch/core` and expose `resolveAdapterConfig`**

Replace the `@/cron`/`@/daemon`/`@/heartbeat-store` imports with `import { runForever, createMatcher, lookbackForSchedule, type DaemonDeps } from "perch/core"` and the heartbeat helpers with `import { ... } from "perch/cli"` (CEO reuses perch's file heartbeat store). Extract a pure `export function resolveAdapterConfig(env)` that returns `{ registryPath, heartbeatPath, swarmPath, syncedHeartbeatPath, dispatchArgv, host, launchdLabel: "com.ceo.schedulerd" }` using the existing `runtime.ts` helpers and `resolveHost`. `main()` calls `resolveAdapterConfig(process.env)` and wires `DaemonDeps` exactly as before (`loadRegistry`→`parseRegistry`, `loadEnabled`→`parseEnabled`, `loadTopology`→`parseSwarm`, `dispatch`→`Bun.spawn(dispatchArgv(...))`). The `loadSwarm`→`loadTopology` dep rename from Task 2 applies here.

- [ ] **Step 8: Run the round-trip test + the remaining CEO scheduler tests + typecheck**

Run: `cd ~/code/claude-ceo-perch-cutover && bun install && bun test lib/scheduler/ && bun run --cwd lib/scheduler typecheck 2>/dev/null || (cd lib/scheduler && bunx tsc --noEmit)`
Expected: round-trip test PASS (2); `registry`/`swarm`/`enabled`/`runtime` tests still PASS; typecheck 0. If `tsc` flags an unresolved `perch/core`, confirm `bun install` linked the sibling and the `exports` map in `perch/package.json` is correct.

- [ ] **Step 9: Commit the atomic cutover**

```bash
cd ~/code/claude-ceo-perch-cutover
git status --short                          # verify only scheduler files + package.json
git add lib/scheduler package.json bun.lockb 2>/dev/null || git add lib/scheduler package.json
git diff --cached --name-only
git commit -m "feat(scheduler): consume perch/core as adapter; delete duplicated engine modules"
```

- [ ] **Step 10: Verify the live daemons (manual, requires user)**

On ML-1 and the MacBook (both need `perch` checked out as `~/code/perch` for the path dep):
```bash
cd ~/code/claude-ceo && git pull && bun install
launchctl kickstart -p gui/$(id -u)/com.ceo.schedulerd   # macOS; restarts the daemon
ceo doctor                                                # heartbeat fresh, daemon alive
```
Expected: `ceo doctor` reports the daemon alive with a fresh heartbeat; a scheduled playbook fires at its slot; the launchd label is still `com.ceo.schedulerd` (no bootout/bootstrap was needed — the plist is untouched). This step gates the PR merge.

---

## Self-Review

**Spec coverage:** Standalone repo ✓ (Task 1). Shell-command dispatch ✓ (Task 3, `ShellDispatcher` + argv-contract test). Full machinery incl. multi-host/heartbeat ✓ (Task 2 daemon + Task 3 topology provider/synced heartbeat). One package + subpath exports ✓ (Task 1 `exports`). Path dependency ✓ (Task 4 Step 4). croner in runtime deps ✓ (Task 1). Own tsconfig, `@/*` rewritten ✓ (Tasks 1–2). CI ✓ (Task 1). Atomic cutover, byte-identical CEO behavior + label ✓ (Task 4). README ✓ (Task 3). hostname "auto" = short os hostname asserted ✓ (Task 3 config test + Task 4 round-trip). No gaps.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to". Deploy templates (Task 3 Step 12) and README (Step 13) describe concrete content and point at the exact existing files to model from rather than reproducing 90 lines of plist — acceptable since the source files exist and are named.

**Type consistency:** `Job<T>`/`Topology`/`Heartbeat`/`DaemonDeps`/`PerchConfig` used identically across Tasks 2–4. Field renames (`schedule`→`cronSchedule`, `status`→`isActive`, `loadSwarm`→`loadTopology`) are applied consistently in the engine (Task 2), the providers (Task 3), and the CEO adapter (Task 4). `dispatchArgv(cronBin, name) = [cronBin, name, "--scheduled"]` is identical in the existing `runtime.ts`, the `ShellDispatcher` default template (`["{job}", "--scheduled"]` with command `["ceo-cron.sh"]`), and the round-trip assertion.
