#!/usr/bin/env bash
set -uo pipefail

: "${HOME:?HOME must be set for ceo-agent-scope}"
: "${CEO_DIR:?CEO_DIR must be set for ceo-agent-scope}"

bin=""
for candidate in \
  "$HOME/.claude/skills/agent-scope/scripts/agent-scope" \
  "${LLM_TOOLS_REPO:-$HOME/code/llm-tools}/home/.claude/skills/agent-scope/scripts/agent-scope" \
  "$HOME/code/llm-tools/home/.claude/skills/agent-scope/scripts/agent-scope" \
  "$HOME/Code/llm-tools/home/.claude/skills/agent-scope/scripts/agent-scope"; do
  if [ -x "$candidate" ]; then
    bin="$candidate"
    break
  fi
done

if [ -z "$bin" ]; then
  echo "agent-scope launcher not found or not executable; install ~/.claude/skills/agent-scope" >&2
  exit 1
fi

mkdir -p "$CEO_DIR/reports/agent-scope"

"$bin" \
  --ledger-root "$CEO_DIR/agents" \
  --reports-dir "$CEO_DIR/reports/agent-scope" \
  --agents-dir "${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"

rc=$?

if [ "$rc" -eq 0 ] && [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  printf 'fired' >"$CEO_RUNNER_OUTCOME_FILE"
fi

exit "$rc"
