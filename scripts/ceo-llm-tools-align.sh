#!/usr/bin/env bash
set -uo pipefail

: "${HOME:?HOME must be set for ceo-llm-tools-align}"

# LLM_TOOLS_REPO is inherited from fleet-readiness, whose config points it at a
# throwaway checker checkout. An explicit CEO_LLM_TOOLS_ALIGN_REPO is never filtered.
repo="${CEO_LLM_TOOLS_ALIGN_REPO:-}"
if [ -z "$repo" ] && [ -n "${LLM_TOOLS_REPO:-}" ]; then
  case "$(basename "$LLM_TOOLS_REPO")" in
    fleet-readiness-checker*|llm-tools-deploy)
      echo "ignoring LLM_TOOLS_REPO=$LLM_TOOLS_REPO: fleet-readiness checkout, not the align repo" >&2
      ;;
    *) repo="$LLM_TOOLS_REPO" ;;
  esac
fi
explicit_repo="$repo"

if [ -z "$repo" ]; then
  for candidate in "$HOME/code/llm-tools" "$HOME/Code/llm-tools" "$HOME/ML-AI/llm-tools" "/c/Projects/llm-tools"; do
    if [ -x "$candidate/scripts/llm-tools-align.sh" ]; then
      repo="$candidate"
      break
    fi
  done
fi

if [ -z "$repo" ] || [ ! -x "$repo/scripts/llm-tools-align.sh" ]; then
  echo "llm-tools align script not found or not executable${explicit_repo:+ at $explicit_repo}; set CEO_LLM_TOOLS_ALIGN_REPO or LLM_TOOLS_REPO" >&2
  exit 1
fi

"$repo/scripts/llm-tools-align.sh"
rc=$?

if [ "$rc" -eq 0 ] && [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  printf 'noop' >"$CEO_RUNNER_OUTCOME_FILE"
fi

exit "$rc"
