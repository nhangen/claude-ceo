import { existsSync, readdirSync, readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { resolveServer } from "@/servers";
import { detectCliInvocations } from "@/cli-detect";
import type { ToolCall, ToolClass } from "@/types";

export function findSessionFiles(projectsDir: string = join(homedir(), ".claude", "projects")): string[] {
  const out: string[] = [];
  if (!existsSync(projectsDir)) return out;
  function walk(dir: string) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        if (entry.name !== "subagents") walk(join(dir, entry.name));
      } else if (entry.name.endsWith(".jsonl")) {
        out.push(join(dir, entry.name));
      }
    }
  }
  walk(projectsDir);
  return out;
}

interface ToolUseRef {
  id: string;
  name: string;
  input: unknown;
  turnIndex: number;
  timestampMs: number;
}

function extractTextFromResultContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b): b is Record<string, unknown> => typeof b === "object" && b !== null)
    .map((b) => (b["type"] === "text" && typeof b["text"] === "string" ? b["text"] : ""))
    .join("\n");
}

function classifyToolName(name: string): { shortName: string; toolClass: ToolClass } {
  const spec = resolveServer(name);
  if (!spec) {
    return { shortName: name, toolClass: "meta" };
  }
  const short = name.slice(spec.serverPrefix.length);
  for (const [klass, members] of Object.entries(spec.partition) as [ToolClass, string[]][]) {
    if (members.includes(short)) return { shortName: short, toolClass: klass };
  }
  return { shortName: short, toolClass: "meta" };
}

export function readSession(file: string): ToolCall[] {
  const raw = readFileSync(file, "utf8");
  const pendingByUseId = new Map<string, ToolUseRef>();
  const calls: ToolCall[] = [];
  let turnIndex = -1;
  let sessionId = "";

  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let obj: Record<string, unknown>;
    try { obj = JSON.parse(line); } catch { continue; }
    const ts = new Date(String(obj["timestamp"] ?? "")).getTime();
    sessionId = String(obj["sessionId"] ?? sessionId);

    if (obj["type"] === "assistant") {
      turnIndex++;
      const msg = obj["message"] as Record<string, unknown> | undefined;
      const blocks = (msg?.["content"] ?? []) as Record<string, unknown>[];
      for (const b of Array.isArray(blocks) ? blocks : []) {
        if (b["type"] === "tool_use" && typeof b["id"] === "string" && typeof b["name"] === "string") {
          pendingByUseId.set(b["id"], {
            id: b["id"],
            name: b["name"],
            input: b["input"],
            turnIndex,
            timestampMs: ts,
          });
        }
      }
    } else if (obj["type"] === "user") {
      const msg = obj["message"] as Record<string, unknown> | undefined;
      const blocks = (msg?.["content"] ?? []) as Record<string, unknown>[];
      for (const b of Array.isArray(blocks) ? blocks : []) {
        if (b["type"] !== "tool_result") continue;
        const id = String(b["tool_use_id"] ?? "");
        const ref = pendingByUseId.get(id);
        if (!ref) continue;
        pendingByUseId.delete(id);
        const text = extractTextFromResultContent(b["content"]);
        const { shortName, toolClass } = classifyToolName(ref.name);
        calls.push({
          sessionId,
          timestampMs: ref.timestampMs,
          turnIndex: ref.turnIndex,
          toolName: ref.name,
          shortName,
          toolClass,
          input: ref.input,
          resultText: text,
          resultIsError: b["is_error"] === true,
          resultTokens: Math.ceil(text.length / 4),
          msToNextTool: null,
        });

        if (ref.name === "Bash") {
          const cmd = (ref.input as { command?: string } | null)?.command ?? "";
          for (const match of detectCliInvocations(cmd)) {
            calls.push({
              sessionId,
              timestampMs: ref.timestampMs,
              turnIndex: ref.turnIndex,
              toolName: match.syntheticToolName,
              shortName: match.shortName,
              toolClass: match.toolClass,
              input: { command: cmd, viaBash: true },
              resultText: text,
              resultIsError: b["is_error"] === true,
              resultTokens: Math.ceil(text.length / 4),
              msToNextTool: null,
            });
          }
        }
      }
    }
  }

  const sorted = calls.slice().sort((a, b) => a.timestampMs - b.timestampMs);
  for (let i = 0; i < sorted.length - 1; i++) {
    sorted[i]!.msToNextTool = sorted[i + 1]!.timestampMs - sorted[i]!.timestampMs;
  }
  return sorted;
}
