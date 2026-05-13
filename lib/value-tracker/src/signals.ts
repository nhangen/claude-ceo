import type { ClassifiedCall } from "@/types";

export const EMPTY_THRESHOLD_TOKENS = 50;

export function computeSignals(calls: ClassifiedCall[]): {
  errorRate: number;
  emptyRate: number;
  meanResultTokens: number;
  meanMsToNextTool: number | null;
} {
  if (calls.length === 0) {
    return { errorRate: 0, emptyRate: 0, meanResultTokens: 0, meanMsToNextTool: null };
  }
  const errors = calls.filter((c) => c.resultIsError).length;
  const empties = calls.filter((c) => c.resultTokens < EMPTY_THRESHOLD_TOKENS).length;
  const meanTokens = calls.reduce((s, c) => s + c.resultTokens, 0) / calls.length;
  const withNext = calls.filter((c) => c.msToNextTool !== null);
  const meanMs =
    withNext.length > 0
      ? withNext.reduce((s, c) => s + (c.msToNextTool ?? 0), 0) / withNext.length
      : null;
  return {
    errorRate: errors / calls.length,
    emptyRate: empties / calls.length,
    meanResultTokens: meanTokens,
    meanMsToNextTool: meanMs,
  };
}
