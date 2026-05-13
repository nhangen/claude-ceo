import { findSessionFiles, readSession } from "@/ingest/claude-code-jsonl";
import { readCursorBubbles } from "@/ingest/cursor-sqlite";
import type { ToolCall } from "@/types";

export interface IngestOptions {
  sessionFile?: string | null;
  projectFilter?: string | null;
  sinceMs?: number;
  /** Disable specific ingestors by name. */
  disable?: Set<string>;
}

export interface IngestResult {
  source: string;
  calls: ToolCall[];
}

export type Ingestor = (opts: IngestOptions) => IngestResult[];

const claudeCodeJsonlIngestor: Ingestor = (opts) => {
  const files = opts.sessionFile
    ? [opts.sessionFile]
    : findSessionFiles().filter((f) => {
        if (opts.projectFilter && !f.toLowerCase().includes(opts.projectFilter.toLowerCase())) return false;
        return true;
      });

  const calls: ToolCall[] = [];
  for (const file of files) {
    calls.push(...readSession(file));
  }
  return [{ source: "claude-code-jsonl", calls }];
};

const cursorSqliteIngestor: Ingestor = (opts) => {
  // sessionFile flag is only meaningful for the JSONL ingestor; if set, the
  // user is targeting one specific JSONL file and Cursor data shouldn't be
  // mixed in.
  if (opts.sessionFile) return [{ source: "cursor-sqlite", calls: [] }];
  const calls = readCursorBubbles({ sinceMs: opts.sinceMs });
  return [{ source: "cursor-sqlite", calls }];
};

export const ingestors: Map<string, Ingestor> = new Map([
  ["claude-code-jsonl", claudeCodeJsonlIngestor],
  ["cursor-sqlite", cursorSqliteIngestor],
]);

export function runIngestors(opts: IngestOptions): IngestResult[] {
  const out: IngestResult[] = [];
  for (const [name, ingestor] of ingestors) {
    if (opts.disable?.has(name)) continue;
    out.push(...ingestor(opts));
  }
  return out;
}
