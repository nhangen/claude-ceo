// src/types.ts

export type Bucket = "trivially-wasted" | "plausibly-used" | "unclear";

export type ToolClass = "exploratory" | "decisionSupport" | "sideEffecting" | "maintenance" | "meta";

export interface ServerSpec {
  serverPrefix: string;                              // e.g. "mcp__gitnexus__"
  partition: Record<ToolClass, string[]>;            // tool short names per class
  windowOverrides?: Partial<Record<ToolClass, number>>;
  cliBinary?: string;                                // e.g. "gitnexus" — short name detected in Bash commands
}

export interface ToolCall {
  sessionId: string;
  timestampMs: number;
  turnIndex: number;          // 0-based position in session
  toolName: string;           // full name e.g. mcp__gitnexus__context
  shortName: string;          // e.g. context
  toolClass: ToolClass;
  input: unknown;             // raw tool_use input
  resultText: string;         // concatenated tool_result text content (or "")
  resultIsError: boolean;
  resultTokens: number;       // crude: result text length / 4 (no upstream tokens here)
  msToNextTool: number | null;
}

export interface ClassifiedCall extends ToolCall {
  bucket: Bucket;
  bucketReason: string;       // short tag e.g. "is_error", "edit-followthrough", "no-evidence"
  evidenceTurnIndex: number | null;
}

export interface SignalRow {
  toolName: string;
  shortName: string;
  toolClass: ToolClass;
  calls: number;
  errorRate: number;
  emptyRate: number;
  meanResultTokens: number;
  meanMsToNextTool: number | null;
  buckets: Record<Bucket, number>;
}

export interface RunSnapshot {
  schemaVersion: 1;
  generatedAt: string;        // ISO
  windowSinceMs: number;
  serversAnalysed: string[];  // ["gitnexus"]
  sessionCount: number;
  callCount: number;
  rows: SignalRow[];
  unclassifiedCalls: number;  // tool calls whose server prefix isn't registered
}
