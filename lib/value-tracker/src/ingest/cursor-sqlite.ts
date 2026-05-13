import { existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { Database } from "bun:sqlite";
import { resolveServer } from "@/servers";
import type { ToolCall, ToolClass } from "@/types";

// Cursor stores conversation bubbles in a SQLite KV at:
//   ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
// table: cursorDiskKV, columns: key TEXT, value TEXT (JSON blob)
//
// Bubble keys: 'bubbleId:<composerId>:<bubbleSubId>'.
// Composer keys: 'composerData:<composerId>' — has 'createdAt' (unix ms).
//
// Tool calls live at value.toolFormerData with shape:
//   { name: "mcp-<server>-user-<server>-<tool>", params: ..., result: ...,
//     status: ..., toolCallId, modelCallId, ... }
//
// Cursor's MCP naming differs from Claude Code's. We translate
// 'mcp-gitnexus-user-gitnexus-impact' to 'mcp__gitnexus__impact' so the
// resolveServer registry (which matches 'mcp__<server>__' prefixes) works.

export function defaultCursorDbPath(): string {
  return join(
    homedir(),
    "Library",
    "Application Support",
    "Cursor",
    "User",
    "globalStorage",
    "state.vscdb",
  );
}

const CURSOR_MCP_RE = /^mcp-([A-Za-z0-9_-]+)-user-\1-(.+)$/;

function canonicalizeName(cursorName: string): string {
  const m = CURSOR_MCP_RE.exec(cursorName);
  if (m) return `mcp__${m[1]}__${m[2]}`;
  // Fall-through on unexpected shape: log if it looks like an MCP call, so
  // a silently-demoted-to-meta call is at least visible. Per
  // billing-defensive-observability, silent fallbacks need a log line.
  if (cursorName.startsWith("mcp-")) {
    process.stderr.write(`cursor-sqlite: unrecognised MCP tool name shape, demoting to meta: ${cursorName}\n`);
  }
  return cursorName;
}

function classifyToolName(name: string): { shortName: string; toolClass: ToolClass } {
  const spec = resolveServer(name);
  if (!spec) return { shortName: name, toolClass: "meta" };
  const short = name.slice(spec.serverPrefix.length);
  for (const [klass, members] of Object.entries(spec.partition) as [ToolClass, string[]][]) {
    if (members.includes(short)) return { shortName: short, toolClass: klass };
  }
  return { shortName: short, toolClass: "meta" };
}

function extractComposerIdFromKey(key: string): string | null {
  // Real shape: 'bubbleId:<composerId>:<bubbleSubId>' — three segments.
  // A two-segment key like 'bubbleId:<x>' isn't a real bubble row.
  const parts = key.split(":");
  if (parts.length < 3) return null;
  const composerId = parts[1];
  if (!composerId) return null;
  return composerId;
}

interface RawTfd {
  name?: string;
  params?: unknown;
  result?: unknown;
  rawArgs?: unknown;
  status?: string | number;
  toolCallId?: string;
}

function resultIsError(status: unknown, result: unknown): boolean {
  if (typeof status === "string" && /(error|fail|cancel)/i.test(status)) return true;
  if (typeof status === "number" && status !== 0 && status !== 1 && status !== 2) return true;
  if (result && typeof result === "object" && "error" in (result as object)) return true;
  return false;
}

// Cursor stores params/result as JSON-encoded strings (sometimes doubly:
// `result` is a string, which when parsed yields `{"result": "<another json
// string>"}`, whose inner string is the actual MCP tool_result content).
// Unwrap as far as we can so the classifier's path/symbol extractor sees
// real text rather than escape soup.
function unwrapStringJson(v: unknown, depth = 3): unknown {
  let cur = v;
  for (let i = 0; i < depth; i++) {
    if (typeof cur !== "string") break;
    const trimmed = cur.trim();
    if (!(trimmed.startsWith("{") || trimmed.startsWith("["))) break;
    try { cur = JSON.parse(trimmed); } catch { break; }
  }
  return cur;
}

function resultToText(result: unknown): string {
  const unwrapped = unwrapStringJson(result);
  if (unwrapped === null || unwrapped === undefined) return "";
  if (typeof unwrapped === "string") return unwrapped;
  // Cursor wraps real MCP tool_result content under `{ result: { content: [{type:"text", text}] } }`.
  // Pull the inner text array out if we recognise that shape.
  if (typeof unwrapped === "object") {
    const obj = unwrapped as Record<string, unknown>;
    const inner = unwrapStringJson(obj["result"]);
    if (inner && typeof inner === "object") {
      const innerObj = inner as Record<string, unknown>;
      const content = innerObj["content"];
      if (Array.isArray(content)) {
        return content
          .filter((b): b is Record<string, unknown> => typeof b === "object" && b !== null)
          .map((b) => (b["type"] === "text" && typeof b["text"] === "string" ? b["text"] : ""))
          .join("\n");
      }
    }
  }
  return JSON.stringify(unwrapped);
}

export interface CursorIngestOptions {
  dbPath?: string;
  sinceMs?: number;
}

export function readCursorBubbles(opts: CursorIngestOptions = {}): ToolCall[] {
  const dbPath = opts.dbPath ?? defaultCursorDbPath();
  if (!existsSync(dbPath)) return [];
  const sinceMs = opts.sinceMs ?? 0;

  const db = new Database(dbPath, { readonly: true });
  try {
    const composerRows = db
      .query("SELECT substr(key, length('composerData:') + 1) AS id, json_extract(value, '$.createdAt') AS createdAt FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_extract(value, '$.createdAt') IS NOT NULL")
      .all() as { id: string; createdAt: number | null }[];
    const createdAtById = new Map<string, number>();
    for (const r of composerRows) {
      if (typeof r.id === "string" && typeof r.createdAt === "number") {
        createdAtById.set(r.id, r.createdAt);
      }
    }

    const bubbleRows = db
      .query(`
        SELECT
          key AS k,
          json_extract(value, '$.toolFormerData') AS tfd,
          json_extract(value, '$.type') AS bubbleType
        FROM cursorDiskKV
        WHERE key LIKE 'bubbleId:%'
          AND json_extract(value, '$.toolFormerData') IS NOT NULL
          AND json_extract(value, '$.toolFormerData.name') IS NOT NULL
      `)
      .all() as { k: string; tfd: string | null; bubbleType: number | null }[];

    const calls: ToolCall[] = [];
    const turnIndexByComposer = new Map<string, number>();

    for (const row of bubbleRows) {
      if (!row.tfd) continue;
      let tfd: RawTfd;
      try { tfd = JSON.parse(row.tfd) as RawTfd; } catch { continue; }
      if (typeof tfd.name !== "string") continue;
      const composerId = extractComposerIdFromKey(row.k);
      if (!composerId) continue;

      const ts = createdAtById.get(composerId) ?? 0;
      if (ts < sinceMs) continue;

      const turnIndex = turnIndexByComposer.get(composerId) ?? 0;
      turnIndexByComposer.set(composerId, turnIndex + 1);

      const canonical = canonicalizeName(tfd.name);
      const { shortName, toolClass } = classifyToolName(canonical);
      const text = resultToText(tfd.result);

      calls.push({
        sessionId: composerId,
        timestampMs: ts,
        turnIndex,
        toolName: canonical,
        shortName,
        toolClass,
        input: unwrapStringJson(tfd.params ?? tfd.rawArgs ?? null),
        resultText: text,
        resultIsError: resultIsError(tfd.status, tfd.result),
        resultTokens: Math.ceil(text.length / 4),
        msToNextTool: null,
      });
    }

    const sorted = calls.slice().sort((a, b) => {
      if (a.sessionId === b.sessionId) return a.turnIndex - b.turnIndex;
      return a.timestampMs - b.timestampMs;
    });
    // msToNextTool is unreliable for Cursor: within one composer all bubbles
    // share createdAt (Cursor schema doesn't store per-bubble timestamps in
    // this surface), so the diff is always 0. Leave as null for all pairs so
    // downstream rollups don't treat a meaningless 0 as a real signal.
    return sorted;
  } finally {
    db.close();
  }
}
