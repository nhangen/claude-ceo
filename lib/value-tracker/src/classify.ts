import { extractPathsAndSymbols } from "@/extract";
import { resolveServer } from "@/servers";
import { EMPTY_THRESHOLD_TOKENS } from "@/signals";
import type { Bucket, ClassifiedCall, ToolCall, ToolClass } from "@/types";

const DEFAULT_WINDOW: Record<ToolClass, number> = {
  exploratory: 10,
  decisionSupport: 10,
  sideEffecting: 0,
  maintenance: 0,
  meta: 0,
};

const TRIV_DOWNSTREAM_WINDOW = 3;

function windowFor(call: ToolCall): number {
  const spec = resolveServer(call.toolName);
  const overrides = spec?.windowOverrides ?? {};
  return overrides[call.toolClass] ?? DEFAULT_WINDOW[call.toolClass];
}

function inputContains(input: unknown, needles: Set<string>): boolean {
  const s = JSON.stringify(input ?? "");
  for (const n of needles) if (n && s.includes(n)) return true;
  return false;
}

export function classifyCall(calls: ToolCall[], i: number): ClassifiedCall {
  const c = calls[i]!;

  if (c.toolClass === "sideEffecting") {
    if (c.resultIsError) {
      return { ...c, bucket: "trivially-wasted", bucketReason: "is_error", evidenceTurnIndex: null };
    }
    return { ...c, bucket: "plausibly-used", bucketReason: "side-effect-success", evidenceTurnIndex: null };
  }

  if (c.toolClass === "maintenance") {
    if (c.resultIsError) {
      return { ...c, bucket: "trivially-wasted", bucketReason: "is_error", evidenceTurnIndex: null };
    }
    return { ...c, bucket: "plausibly-used", bucketReason: "maintenance-success", evidenceTurnIndex: null };
  }

  if (c.resultIsError) {
    return { ...c, bucket: "trivially-wasted", bucketReason: "is_error", evidenceTurnIndex: null };
  }

  const symbols = extractPathsAndSymbols(c.resultText);
  const window = windowFor(c);

  if (symbols.size > 0) {
    for (let j = i + 1; j < calls.length; j++) {
      const next = calls[j]!;
      if (next.turnIndex - c.turnIndex > window) break;
      if (inputContains(next.input, symbols)) {
        return { ...c, bucket: "plausibly-used", bucketReason: "downstream-input-match", evidenceTurnIndex: next.turnIndex };
      }
    }
  }

  if (c.resultTokens < EMPTY_THRESHOLD_TOKENS && symbols.size === 0) {
    const inputSyms = extractPathsAndSymbols(JSON.stringify(c.input ?? ""));
    if (inputSyms.size === 0) {
      return { ...c, bucket: "trivially-wasted", bucketReason: "empty-result-no-input-symbols", evidenceTurnIndex: null };
    }
    let echoed = false;
    for (let j = i + 1; j < calls.length; j++) {
      const next = calls[j]!;
      if (next.turnIndex - c.turnIndex > TRIV_DOWNSTREAM_WINDOW) break;
      if (inputContains(next.input, inputSyms)) { echoed = true; break; }
    }
    if (!echoed) {
      return { ...c, bucket: "trivially-wasted", bucketReason: "empty-result-no-echo", evidenceTurnIndex: null };
    }
  }

  return { ...c, bucket: "unclear", bucketReason: "no-evidence", evidenceTurnIndex: null };
}

export function classifySession(calls: ToolCall[]): ClassifiedCall[] {
  return calls.map((_, i) => classifyCall(calls, i));
}

export const _internal = { DEFAULT_WINDOW, EMPTY_THRESHOLD_TOKENS, TRIV_DOWNSTREAM_WINDOW } as const;
