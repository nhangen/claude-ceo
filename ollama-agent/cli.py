#!/usr/bin/env python3
"""ollama-agent CLI — run a local model as a tool-using agent on a bounded task.

    python cli.py --task "summarize the README" --model gpt-oss:20b --cwd /repo

Slice 2 (#187): real shell/fs/git tools + task-relevant rule injection.
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from ollama_agent import (ToolBox, TOOLS, USE_SKILL_TOOL, MCPClient, RegistryError,
                          StdioMCPTransport, compose_system, filter_tools, gate,
                          load_registry, load_scores, load_skill_index, mcp_tools_to_ollama,
                          ollama_transport, render_catalog, run_agent)

DEFAULT_SYSTEM = (
    "You are a local engineering agent operating inside a single working directory. "
    "Use the provided tools to inspect and modify files and run commands. "
    "When the task is done, reply with a short summary and no further tool calls."
)


def _warn_if_stale_scores(generated_at, stale_days):
    """Eval-score staleness logs a warning but never refuses (a re-pulled model
    against an old eval is a soft signal, not a hard governance failure)."""
    try:
        gen = datetime.strptime(generated_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        print(f"warning: eval scores have an unparseable generated_at {generated_at!r}",
              file=sys.stderr)
        return
    age_days = (datetime.now(timezone.utc) - gen).days
    if age_days > stale_days:
        print(f"warning: eval scores are {age_days}d old (generated_at {generated_at}, "
              f"stale after {stale_days}d) — gating on possibly outdated competence data",
              file=sys.stderr)


def main(argv=None):
    p = argparse.ArgumentParser(description="Run a local ollama model as a tool-using agent.")
    p.add_argument("--task", required=True, help="The task for the agent to perform.")
    p.add_argument("--model", default="gpt-oss:20b")
    p.add_argument("--cwd", default=".", help="Working directory the tools operate in.")
    p.add_argument("--system", default=DEFAULT_SYSTEM)
    p.add_argument("--host", default="127.0.0.1:11434")
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--num-ctx", type=int, default=16384)
    p.add_argument("--turn-cap", type=int, default=8)
    p.add_argument("--shell-timeout", type=int, default=30)
    p.add_argument("--rules-dir", default="~/.claude/rules",
                   help="Directory of rule .md files to select from.")
    p.add_argument("--max-rules", type=int, default=6)
    p.add_argument("--rules-budget", type=int, default=24000,
                   help="Max chars of rule text to inject.")
    p.add_argument("--no-rules", action="store_true", help="Skip rule injection entirely.")
    p.add_argument("--skills-dir", default="~/.claude/skills",
                   help="Directory of skill dirs (each with a SKILL.md).")
    p.add_argument("--no-skills", action="store_true", help="Skip skill discovery entirely.")
    p.add_argument("--mcp", default=None,
                   help="Command to spawn an MCP server whose tools are bridged in (e.g. "
                        "'npx -y @modelcontextprotocol/server-filesystem /path').")
    p.add_argument("--registry", default=None, help="Path/JSON of a task registry.")
    p.add_argument("--task-name", default=None,
                   help="Run a registered task by name (applies its model/tier/tools/rules).")
    p.add_argument("--scores", default=None,
                   help="Path to a model-matrix scores.tsv for the min_score gate "
                        "(default: ~/.claude/skills/model-matrix/scripts/out/scores.tsv).")
    p.add_argument("--scores-stale-days", type=int, default=30,
                   help="Warn (do not refuse) if the eval scores are older than this.")
    p.add_argument("--json", action="store_true", help="Print the full record as JSON.")
    a = p.parse_args(argv)

    # Governance: a registered task is gated before any model call. A non-delegable
    # tier (high-stakes) or unknown runner/tier is refused here — never run.
    spec = None
    if a.task_name:
        if not a.registry:
            print("--task-name requires --registry", file=sys.stderr)
            return 2
        try:
            specs = load_registry(a.registry)
        except (RegistryError, ValueError, OSError) as e:
            print(f"registry error: {e}", file=sys.stderr)
            return 2
        spec = specs.get(a.task_name)
        if spec is None:
            print(f"no registered task {a.task_name!r} (known: {sorted(specs)})", file=sys.stderr)
            return 2
        scores = None
        if spec.min_score is not None:
            scores_path = a.scores or str(
                Path.home() / ".claude/skills/model-matrix/scripts/out/scores.tsv")
            # An absent file is a configuration error, surfaced distinctly — not
            # folded into the gate's generic "model not evaluated" refusal.
            # (load_scores treats a non-existent path as inline text, so the
            # check must happen here, before the call.)
            if not Path(scores_path).is_file():
                print(f"REJECTED task {a.task_name!r}: eval scores file not found at "
                      f"{scores_path} (min_score gate requires it)", file=sys.stderr)
                return 3
            try:
                scores, generated_at = load_scores(scores_path)
            except (OSError, UnicodeDecodeError) as e:
                print(f"REJECTED task {a.task_name!r}: cannot read eval scores "
                      f"({scores_path}: {e})", file=sys.stderr)
                return 3
            if generated_at:
                _warn_if_stale_scores(generated_at, a.scores_stale_days)
        ok, reason = gate(spec, scores)
        if not ok:
            print(f"REJECTED task {a.task_name!r}: {reason}", file=sys.stderr)
            return 3
        a.model = spec.model
        a.no_rules = a.no_rules or not spec.rules
        a.no_skills = a.no_skills or not spec.skills
        print(f"task {a.task_name!r}: runner={spec.runner} tier={spec.tier} model={spec.model}",
              file=sys.stderr)

    system = a.system
    if not a.no_rules:
        system, sel = compose_system(a.system, a.task, a.rules_dir, a.max_rules, a.rules_budget)
        injected = ", ".join(r.name for r in sel.selected) or "(none matched)"
        # Counts make a zero-match a visible selection decision, not an apparent
        # load failure: "matched 0 of 64" reads differently than "rules dir empty".
        print(f"rules: considered {sel.considered}, matched {sel.matched}, "
              f"injected {len(sel.selected)} ({injected}), dropped {len(sel.dropped)}",
              file=sys.stderr)
        for r, reason in sel.dropped:
            print(f"  dropped {r.name}: {reason}", file=sys.stderr)

    skills = [] if a.no_skills else load_skill_index(a.skills_dir)
    if skills:
        system = f"{render_catalog(skills)}\n\n{system}"
        print(f"skills: {len(skills)} available (use_skill enabled)", file=sys.stderr)
    tools = TOOLS + ([USE_SKILL_TOOL] if skills else [])

    mcp_transport, mcp_client, mcp_names = None, None, {}
    if a.mcp:
        try:
            mcp_transport = StdioMCPTransport(a.mcp, cwd=a.cwd)
            mcp_client = MCPClient(mcp_transport)
            mcp_client.initialize()
            schemas, mcp_names = mcp_tools_to_ollama(mcp_client.list_tools())
            tools = tools + schemas
            print(f"mcp: {len(schemas)} tools from {a.mcp!r}", file=sys.stderr)
        except Exception as e:
            if mcp_transport:
                mcp_transport.close()
            print(f"mcp bridge failed for {a.mcp!r}: {e}", file=sys.stderr)
            return 1

    if spec is not None and spec.tools != "*":
        available = {t["function"]["name"] for t in tools}
        unknown = [n for n in spec.tools if n not in available]
        if unknown:
            # A typo'd allowlist name would otherwise silently shrink the tool set
            # with no signal — surface it (enum-config-typo-fallback). Note: MCP
            # tools match their bridged 'mcp__<name>' form here, not the raw name.
            print(f"warning: registry tools not available (ignored): {', '.join(unknown)}",
                  file=sys.stderr)
        tools = filter_tools(tools, spec.tools)
        print(f"tools restricted to: {', '.join(t['function']['name'] for t in tools) or '(none)'}",
              file=sys.stderr)

    toolbox = ToolBox(cwd=a.cwd, timeout=a.shell_timeout, skills=skills,
                      mcp_client=mcp_client, mcp_names=mcp_names)
    transport = ollama_transport(a.model, host=a.host, temperature=a.temperature, num_ctx=a.num_ctx)
    try:
        rec = run_agent(a.task, system, transport, toolbox, tools, turn_cap=a.turn_cap)
    except RuntimeError as e:
        print(f"agent failed: {e}", file=sys.stderr)
        return 1
    finally:
        if mcp_transport:
            mcp_transport.close()

    if a.json:
        print(json.dumps(rec, indent=2))
    else:
        final = rec["transcript"][-1]
        print(f"completed={rec['completed']} turns={rec['turns']} "
              f"calls={len(rec['calls'])} unknown={rec['unknown_calls']}")
        print("--- final message ---")
        print(final.get("content", "(no content)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
