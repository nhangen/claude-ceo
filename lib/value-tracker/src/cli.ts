#!/usr/bin/env bun
import { existsSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { runIngestors } from "@/ingest";
import { classifySession } from "@/classify";
import { rollup } from "@/rollup";
import { formatTerminal, formatObsidian } from "@/format";
import { writeSnapshot, defaultSnapshotDir } from "@/snapshot";
import { resolveServer } from "@/servers";
import type { ClassifiedCall, RunSnapshot, ToolCall } from "@/types";

interface Args {
  since: number;
  project: string | null;
  session: string | null;
  sessionFile: string | null;
  obsidianVault: string | null;
  noSnapshot: boolean;
  dryRun: boolean;
  help: boolean;
}

function parseArgs(argv: string[]): Args {
  const a: Args = {
    since: Date.now() - 7 * 24 * 60 * 60 * 1000,
    project: null,
    session: null,
    sessionFile: null,
    obsidianVault: existsSync(join(homedir(), "Documents", "Obsidian"))
      ? join(homedir(), "Documents", "Obsidian")
      : null,
    noSnapshot: false,
    dryRun: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]!;
    const v = argv[i + 1];
    switch (k) {
      case "-h":
      case "--help":
        a.help = true;
        break;
      case "--since":
        a.since = Date.parse(v!);
        i++;
        break;
      case "--project":
        a.project = v!;
        i++;
        break;
      case "--session":
        a.session = v!;
        i++;
        break;
      case "--session-file":
        a.sessionFile = v!;
        i++;
        break;
      case "--obsidian-vault":
        a.obsidianVault = v!;
        i++;
        break;
      case "--no-snapshot":
        a.noSnapshot = true;
        break;
      case "--dry-run":
        a.dryRun = true;
        break;
    }
  }
  return a;
}

function usage(): string {
  return [
    "value-tracker — analyse MCP tool-call value from Claude Code sessions",
    "",
    "Usage: bun lib/value-tracker/src/cli.ts [options]",
    "  --since <YYYY-MM-DD>      window start (default: 7 days ago)",
    "  --project <fragment>      filter by cwd substring",
    "  --session <id>            analyse one session by id",
    "  --session-file <path>     analyse one JSONL file directly (testing)",
    "  --obsidian-vault <path>   override Obsidian vault path",
    "  --no-snapshot             skip JSON snapshot write",
    "  --dry-run                 terminal output only, no files written",
    "  -h, --help                show this help",
    "",
  ].join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(usage());
    return;
  }

  const allCalls: ClassifiedCall[] = [];
  const sessionIds = new Set<string>();
  let unclassified = 0;

  const ingestResults = runIngestors({
    sessionFile: args.sessionFile,
    projectFilter: args.project,
    sinceMs: args.since,
  });

  // Group by sessionId so the classifier scans downstream within each session.
  const bySession = new Map<string, ToolCall[]>();
  for (const result of ingestResults) {
    for (const c of result.calls) {
      if (c.timestampMs < args.since) continue;
      if (args.session && c.sessionId !== args.session) continue;
      const arr = bySession.get(c.sessionId) ?? [];
      arr.push(c);
      bySession.set(c.sessionId, arr);
    }
  }

  for (const [sid, calls] of bySession) {
    if (calls.length === 0) continue;
    for (const c of calls) {
      if (c.toolName.startsWith("mcp__") && !resolveServer(c.toolName)) unclassified++;
    }
    const classified = classifySession(calls).filter((cc) => resolveServer(cc.toolName));
    if (classified.length > 0) sessionIds.add(sid);
    allCalls.push(...classified);
  }

  const rows = rollup(allCalls);
  const snap: RunSnapshot = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    windowSinceMs: args.since,
    serversAnalysed: ["gitnexus"],
    sessionCount: sessionIds.size,
    callCount: allCalls.length,
    rows,
    unclassifiedCalls: unclassified,
  };

  process.stdout.write(formatTerminal(snap) + "\n");

  if (args.dryRun) return;

  if (!args.noSnapshot) {
    const path = writeSnapshot(snap, defaultSnapshotDir());
    process.stdout.write(`\nSnapshot: ${path}\n`);
  }

  if (args.obsidianVault) {
    const noteDir = join(args.obsidianVault, "Projects", "Development", "nhangen", "claude-ceo", "value-tracker");
    mkdirSync(noteDir, { recursive: true });
    const notePath = join(noteDir, `${snap.generatedAt.slice(0, 10)}.md`);
    writeFileSync(notePath, formatObsidian(snap));
    process.stdout.write(`Obsidian note: ${notePath}\n`);
  }
}

main();
