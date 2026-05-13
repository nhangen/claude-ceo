import { computeSignals } from "@/signals";
import type { Bucket, ClassifiedCall, SignalRow } from "@/types";

export function rollup(calls: ClassifiedCall[]): SignalRow[] {
  const byTool = new Map<string, ClassifiedCall[]>();
  for (const c of calls) {
    const arr = byTool.get(c.toolName) ?? [];
    arr.push(c);
    byTool.set(c.toolName, arr);
  }

  const rows: SignalRow[] = [];
  for (const [toolName, group] of byTool) {
    const first = group[0]!;
    const buckets: Record<Bucket, number> = {
      "trivially-wasted": 0,
      "plausibly-used": 0,
      unclear: 0,
    };
    for (const c of group) buckets[c.bucket]++;
    const sig = computeSignals(group);
    rows.push({
      toolName,
      shortName: first.shortName,
      toolClass: first.toolClass,
      calls: group.length,
      ...sig,
      buckets,
    });
  }

  const order: Record<string, number> = {
    exploratory: 0,
    decisionSupport: 1,
    sideEffecting: 2,
    maintenance: 3,
    meta: 4,
  };
  rows.sort((a, b) => order[a.toolClass]! - order[b.toolClass]! || b.calls - a.calls);
  return rows;
}
