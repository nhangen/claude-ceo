#!/usr/bin/env python3
"""ollama-agent CLI — run a local model as a tool-using agent on a bounded task.

    python cli.py --task "summarize the README" --model gpt-oss:20b --cwd /repo

Slice 2 (#187): real shell/fs/git tools + task-relevant rule injection.
"""
import argparse
import json
import sys

from ollama_agent import (ToolBox, TOOLS, USE_SKILL_TOOL, MCPClient, StdioMCPTransport,
                          compose_system, load_skill_index, mcp_tools_to_ollama,
                          ollama_transport, render_catalog, run_agent)

DEFAULT_SYSTEM = (
    "You are a local engineering agent operating inside a single working directory. "
    "Use the provided tools to inspect and modify files and run commands. "
    "When the task is done, reply with a short summary and no further tool calls."
)


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
    p.add_argument("--json", action="store_true", help="Print the full record as JSON.")
    a = p.parse_args(argv)

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
