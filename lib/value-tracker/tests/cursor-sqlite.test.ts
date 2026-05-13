import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { readCursorBubbles } from "@/ingest/cursor-sqlite";

function makeFixtureDb(): { dbPath: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "mvt-cursor-"));
  const dbPath = join(dir, "state.vscdb");
  const db = new Database(dbPath);
  db.exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)");

  const composerId = "11111111-1111-1111-1111-111111111111";
  const createdAt = Date.parse("2026-05-09T12:00:00Z");
  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `composerData:${composerId}`,
    JSON.stringify({ createdAt, _v: 3 }),
  );

  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `bubbleId:${composerId}:bbb1`,
    JSON.stringify({
      _v: 3, type: 2, bubbleId: "bbb1",
      toolFormerData: {
        name: "mcp-gitnexus-user-gitnexus-impact",
        params: { target: "Foo", direction: "upstream" },
        result: { risk: "MEDIUM", impactedCount: 7 },
        status: "success",
      },
    }),
  );
  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `bubbleId:${composerId}:bbb2`,
    JSON.stringify({
      _v: 3, type: 2, bubbleId: "bbb2",
      toolFormerData: {
        name: "mcp-gitnexus-user-gitnexus-query",
        params: { query: "auth flow" },
        result: "long text result",
        status: "success",
      },
    }),
  );
  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `bubbleId:${composerId}:bbb3`,
    JSON.stringify({
      _v: 3, type: 2, bubbleId: "bbb3",
      toolFormerData: {
        name: "mcp-gitnexus-user-gitnexus-impact",
        params: { target: "Bar" },
        result: { error: "Target not found" },
        status: "error",
      },
    }),
  );
  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `bubbleId:${composerId}:bbb4`,
    JSON.stringify({
      _v: 3, type: 2, bubbleId: "bbb4",
      toolFormerData: {
        name: "read_file_v2",
        params: { path: "src/foo.ts" },
        result: "(file contents)",
        status: "success",
      },
    }),
  );
  db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
    `bubbleId:${composerId}:bbb5`,
    JSON.stringify({ _v: 3, type: 1, bubbleId: "bbb5", text: "hi" }),
  );

  db.close();
  return { dbPath, cleanup: () => rmSync(dir, { recursive: true }) };
}

describe("readCursorBubbles", () => {
  test("returns empty list when DB does not exist", () => {
    expect(readCursorBubbles({ dbPath: "/nope/state.vscdb" })).toEqual([]);
  });

  test("translates Cursor MCP names to canonical mcp__server__tool form", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      const impactCall = calls.find((c) => c.toolName === "mcp__gitnexus__impact");
      expect(impactCall).toBeDefined();
      expect(impactCall!.shortName).toBe("impact");
      expect(impactCall!.toolClass).toBe("decisionSupport");
    } finally {
      cleanup();
    }
  });

  test("classifies query as exploratory", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      const queryCall = calls.find((c) => c.toolName === "mcp__gitnexus__query");
      expect(queryCall).toBeDefined();
      expect(queryCall!.toolClass).toBe("exploratory");
    } finally {
      cleanup();
    }
  });

  test("flags resultIsError when status is error", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      const errorCall = calls.find((c) => c.input && JSON.stringify(c.input).includes("Bar"));
      expect(errorCall).toBeDefined();
      expect(errorCall!.resultIsError).toBe(true);
    } finally {
      cleanup();
    }
  });

  test("uses composer createdAt as bubble timestamp", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      expect(calls.length).toBeGreaterThan(0);
      for (const c of calls) {
        expect(c.timestampMs).toBe(Date.parse("2026-05-09T12:00:00Z"));
      }
    } finally {
      cleanup();
    }
  });

  test("respects sinceMs filter", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const future = Date.parse("2026-06-01T00:00:00Z");
      const calls = readCursorBubbles({ dbPath, sinceMs: future });
      expect(calls).toEqual([]);
    } finally {
      cleanup();
    }
  });

  test("skips bubbles without toolFormerData", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      expect(calls.some((c) => JSON.stringify(c.input ?? "").includes("hi"))).toBe(false);
    } finally {
      cleanup();
    }
  });

  test("non-MCP tools are ingested but classified meta", () => {
    const { dbPath, cleanup } = makeFixtureDb();
    try {
      const calls = readCursorBubbles({ dbPath });
      const readFileCall = calls.find((c) => c.toolName === "read_file_v2");
      expect(readFileCall).toBeDefined();
      expect(readFileCall!.toolClass).toBe("meta");
    } finally {
      cleanup();
    }
  });

  test("unwraps doubly-encoded JSON params and result (real Cursor shape)", () => {
    // Real Cursor stores params/result as JSON-encoded strings, sometimes
    // doubly: `result` is a string whose parse yields { result: "<json string>" }
    // whose inner parse yields { content: [{type: "text", text: "..."}] }.
    const dir = mkdtempSync(join(tmpdir(), "mvt-cursor-real-"));
    const dbPath = join(dir, "state.vscdb");
    const db = new Database(dbPath);
    db.exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)");

    const composerId = "22222222-2222-2222-2222-222222222222";
    db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
      `composerData:${composerId}`,
      JSON.stringify({ createdAt: Date.now(), _v: 3 }),
    );

    const innerResult = JSON.stringify({
      content: [{ type: "text", text: "Foo lives in src/foo.ts:12 — see Class:src/foo.ts:Foo" }],
    });
    const outerResult = JSON.stringify({ result: innerResult });

    db.query("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)").run(
      `bubbleId:${composerId}:bbb`,
      JSON.stringify({
        _v: 3, type: 2,
        toolFormerData: {
          name: "mcp-gitnexus-user-gitnexus-context",
          params: JSON.stringify({ tools: [{ name: "context", parameters: '{"name":"Foo"}', serverName: "gitnexus" }] }),
          result: outerResult,
          status: "completed",
        },
      }),
    );
    db.close();

    try {
      const calls = readCursorBubbles({ dbPath });
      expect(calls.length).toBe(1);
      const c = calls[0]!;
      // Result text should be the human-readable inner content, not escape soup.
      expect(c.resultText).toContain("Foo lives in src/foo.ts:12");
      expect(c.resultText).not.toContain("\\\\\""); // no leftover escape sequences
      // Input should be the parsed object, not a string.
      expect(typeof c.input).toBe("object");
    } finally {
      rmSync(dir, { recursive: true });
    }
  });
});
