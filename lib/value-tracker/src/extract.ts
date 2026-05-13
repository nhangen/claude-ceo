const PATH_RE = /(?:[\w./-]+\/)?[\w.-]+\.(?:ts|tsx|js|jsx|mjs|cjs|php|py|rb|go|rs|java|kt|sh|md|json|toml|yml|yaml|html|css|scss)\b/g;
const NAMESPACED_SYMBOL_RE = /\b[A-Z][A-Za-z0-9_]*(?:\\[A-Z][A-Za-z0-9_]*)+\b/g;
const DOUBLE_COLON_SYMBOL_RE = /\b[A-Z][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*\b/g;

export function extractPathsAndSymbols(text: string): Set<string> {
  const out = new Set<string>();
  if (!text) return out;
  for (const m of text.matchAll(PATH_RE)) out.add(m[0]);
  for (const m of text.matchAll(NAMESPACED_SYMBOL_RE)) out.add(m[0]);
  for (const m of text.matchAll(DOUBLE_COLON_SYMBOL_RE)) out.add(m[0]);
  return out;
}
