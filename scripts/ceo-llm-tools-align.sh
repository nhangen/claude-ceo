#!/usr/bin/env bash
set -uo pipefail

: "${HOME:?HOME must be set for ceo-llm-tools-align}"

repo="${LLM_TOOLS_REPO:-}"
if [ -z "$repo" ]; then
  for candidate in "$HOME/code/llm-tools" "$HOME/Code/llm-tools" "$HOME/ML-AI/llm-tools" "/c/Projects/llm-tools"; do
    if [ -x "$candidate/scripts/llm-tools-align.sh" ]; then
      repo="$candidate"
      break
    fi
  done
fi

if [ -z "$repo" ] || [ ! -x "$repo/scripts/llm-tools-align.sh" ]; then
  echo "llm-tools align script not found or not executable; set LLM_TOOLS_REPO" >&2
  exit 1
fi

"$repo/scripts/llm-tools-align.sh"
rc=$?

if [ "$rc" -eq 0 ] && [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  printf 'noop' >"$CEO_RUNNER_OUTCOME_FILE"
fi

exit "$rc"
