#!/usr/bin/env bash
set -uo pipefail

: "${HOME:?HOME must be set for ceo-agent-scope}"
: "${CEO_DIR:?CEO_DIR must be set for ceo-agent-scope}"

reports_dir="$CEO_DIR/reports/agent-scope"
# Must match {MONTH} in docs/playbooks/agent-scope.md's artifact: the tool
# rewrites one file per month in place, so the runner is the only place that
# knows the real filename before doctor's cross-check runs the next morning.
report="$reports_dir/$(date +%Y-%m).md"

bin=""
if [ -n "${LLM_TOOLS_REPO:-}" ]; then
  # An explicit override is never searched past. The candidate sweep below tries
  # ~/.claude/skills first, which on a normal install is a symlink into the
  # default clone -- so a typo'd LLM_TOOLS_REPO used to resolve to that clone and
  # report success from a tree the operator did not select.
  bin="$LLM_TOOLS_REPO/home/.claude/skills/agent-scope/scripts/agent-scope"
  if [ ! -x "$bin" ]; then
    echo "LLM_TOOLS_REPO is set but $bin is not executable" >&2
    exit 1
  fi
else
  for candidate in \
    "$HOME/.claude/skills/agent-scope/scripts/agent-scope" \
    "$HOME/code/llm-tools/home/.claude/skills/agent-scope/scripts/agent-scope" \
    "$HOME/Code/llm-tools/home/.claude/skills/agent-scope/scripts/agent-scope"; do
    if [ -x "$candidate" ]; then
      bin="$candidate"
      break
    fi
    if [ -e "$candidate" ]; then
      echo "  $candidate [not executable]" >&2
    else
      echo "  $candidate [absent]" >&2
    fi
  done
fi

if [ -z "$bin" ]; then
  echo "agent-scope launcher not found or not executable at any path above; install ~/.claude/skills/agent-scope or set LLM_TOOLS_REPO" >&2
  exit 1
fi

mkdir -p "$reports_dir" || {
  echo "cannot create $reports_dir (vault unmounted or read-only?)" >&2
  exit 1
}

started=$(date +%s)
"$bin" \
  --ledger-root "$CEO_DIR/agents" \
  --reports-dir "$reports_dir" \
  --agents-dir "${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"

rc=$?

# Upstream agent-scope (nhangen/llm-tools#770) exits 3 and writes nothing on
# partial input or when no agent reaches the ranking threshold. ceo-cron keeps
# only the last stderr lines, cut to 120 chars, so this line has to carry the
# diagnosis on its own and name both causes. --lenient is deliberately never
# passed, so the launcher's advice to use it does not apply here.
if [ "$rc" -eq 3 ]; then
  echo "agent-scope rc=3: partial input or no agent ranked; snapshot NOT written (runner never passes --lenient)" >&2
fi

# A launcher that exits 0 without writing is the failure doctor cannot see until
# the next morning, and only then if this playbook completed today.
if [ "$rc" -eq 0 ]; then
  if [ ! -s "$report" ]; then
    echo "agent-scope exited 0 but $report is missing or empty" >&2
    rc=1
  elif [ "$(date -r "$report" +%s 2>/dev/null || echo 0)" -lt "$started" ]; then
    echo "agent-scope exited 0 but $report was not rewritten this run" >&2
    rc=1
  fi
fi

if [ "$rc" -eq 0 ] && [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
  printf 'fired' >"$CEO_RUNNER_OUTCOME_FILE"
fi

exit "$rc"
