#!/usr/bin/env python3
"""ollama-agent CLI — run a local model as a tool-using agent on a bounded task.

    python cli.py --task "summarize the README" --model gpt-oss:20b --cwd /repo

Slice 2 (#187): real shell/fs/git tools + task-relevant rule injection.
"""
import argparse
import hashlib
import json
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path

from ollama_agent import (ToolBox, TOOLS, USE_SKILL_TOOL, MCPClient, RegistryError,
                          StdioMCPTransport, compose_system, filter_tools, gate,
                          load_registry, load_scores, load_skill_index, mcp_tools_to_ollama,
                          ollama_transport, render_catalog, run_agent)
from ollama_agent.ledger import append_run

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


class _Terminated(KeyboardInterrupt):
    """A supervisor's SIGTERM/SIGHUP, routed into the KeyboardInterrupt arm."""


def _install_kill_handlers():
    """Make a supervisor stop reach the ledger the way Ctrl-C already does.

    Ctrl-C is not how this process usually dies. ceo-schedulerd spawns the cron
    bridge as an ordinary child in its own cgroup, so `systemctl --user stop`, a
    redeploy, or a reboot SIGTERMs the run in flight — and launchd does the same
    on macOS. Without this, `reason: "killed"` is reachable only from an
    interactive terminal and the dominant kill path still loses the row (#328).

    _Terminated subclasses KeyboardInterrupt rather than SystemExit on purpose:
    SystemExit derives from BaseException, so it would slip past `except
    Exception` and land back in the hole this closes. SIGKILL stays unhandleable
    by definition — a `kill -9` still loses the row, and nothing here can change
    that.
    """
    def raise_terminated(signum, _frame):
        raise _Terminated(f"signal {signum}")

    for name in ("SIGTERM", "SIGHUP"):
        sig = getattr(signal, name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, raise_terminated)
        except ValueError:
            # Not the main thread (an embedding caller, a test harness). The run
            # still works; it just keeps the default disposition.
            pass


def _restore_default_kill_handlers():
    """Hand SIGTERM/SIGHUP back to the OS once the crash record is being built.

    Called from the finally, so it covers two cases. mcp.close() documents itself
    as never raising and catches Exception — _Terminated is a KeyboardInterrupt,
    so a second signal during its 10s of proc.wait would escape the finally and
    drop the very row this path exists to write. And main() is callable
    in-process (forty tests do it), so a handler left installed past a normal
    return silently rewrites the caller's signal disposition for the rest of the
    process. A second supervisor signal should kill us, not re-enter.
    """
    for name in ("SIGTERM", "SIGHUP"):
        sig = getattr(signal, name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, signal.SIG_DFL)
        except ValueError:
            pass


def _crash_record(reason, run_id, usage_tracker, toolbox):
    """A ledger row for a run that died before run_agent could return one.

    The counts come from the tracker the caller handed to run_agent, so the row
    reports the tokens the run actually burned instead of zero — a 0-token row
    understates cost as badly as an absent one (#328).
    """
    return {
        "completed": False,
        # From the tracker, not a hardcoded None, so a gated run whose check went
        # red before it crashed records False rather than reading as ungated.
        # With `gated`, (gated=True, verified=None) distinguishes a run that died
        # before the gate first ran from an ungated run (gated=False, verified=None).
        # True is unreachable here: a green gate breaks and returns normally.
        "verified": usage_tracker.get("verified"),
        "gated": usage_tracker.get("gated", False),
        "reason": reason,
        "turns": usage_tracker.get("turns", 0),
        "run_id": run_id,
        "ollama_input_tokens": usage_tracker.get("ollama_input_tokens", 0),
        "ollama_output_tokens": usage_tracker.get("ollama_output_tokens", 0),
        "transcript": [],
        "calls": toolbox.calls,
        "unknown_calls": toolbox.unknown_calls,
        "tool_errors": toolbox.tool_errors,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description="Run a local ollama model as a tool-using agent.")
    p.add_argument("--task", required=True, help="The task for the agent to perform.")
    p.add_argument("--model", default="gpt-oss:20b")
    p.add_argument("--cwd", default=".", help="Working directory the tools operate in.")
    p.add_argument("--system", default=DEFAULT_SYSTEM)
    p.add_argument("--host", default="127.0.0.1:11434")
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--num-ctx", type=int, default=16384)
    # A thinking model can spend an entire turn reasoning and never reach an answer. On
    # one long analytic turn that is fatal (measured: qwen3.8:27b over a 1,464-token diff
    # never answered inside the 600s request timeout, and finished in 62s with thinking
    # off); across many short turns it costs nothing. So the caller says, and the default
    # is whatever the model does on its own — unchanged from before this flag existed.
    p.add_argument("--no-think", dest="think", action="store_const", const=False,
                   default=None, help="Suppress a thinking model's reasoning phase.")
    p.add_argument("--timeout", type=int, default=600,
                   help="Seconds to wait on one ollama request (default 600).")
    # Some tasks are one completion, not an agentic loop — a code review reads a diff that
    # is already inline and answers. Offered tools, a model explores instead: measured on
    # qwen3.8:27b reviewing a diff, three turns went to grep and sed against the very file
    # pasted into the prompt, the turn cap ran out, and the run returned a tool result
    # instead of findings. Telling it not to in the prompt did not stop it; withholding the
    # tools does.
    p.add_argument("--no-tools", action="store_true",
                   help="Offer the model no tools — for a single-completion task.")
    p.add_argument("--turn-cap", type=int, default=8)
    p.add_argument("--verify-cmd", default=None,
                   help="Shell command that gates completion: the agent keeps "
                        "iterating until it exits 0 (drive-to-green). Runs in --cwd.")
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
    p.add_argument("--run-id", default=None,
                   help="Caller-minted run identifier, echoed in the record so a "
                        "downstream ingestion pass can dedup this run's findings.")
    p.add_argument("--json", action="store_true", help="Print the full record as JSON.")
    p.add_argument("--ungated", action="store_true",
                   help="Explicitly opt into an ad-hoc, ungated run (no registered "
                        "task, no delegation gate). Without it, a run must select a "
                        "registered task via --task-name.")
    a = p.parse_args(argv)

    # The delegation gate (tier + min_score) only fires for a registered task
    # (--task-name). A bare --task otherwise runs whatever --model says, ungated —
    # making the gate theater for ad-hoc use. Require an explicit --ungated opt-in
    # so the bypass is no longer the silent default. The cron bridge always passes
    # --task-name (ceo-cron.sh) and is unaffected.
    if not a.task_name and not a.ungated:
        print("REFUSED: an ad-hoc run requires --ungated (it applies no delegation "
              "gate). Use --task-name <name> --registry <path> to run a gated, "
              "registered task instead.", file=sys.stderr)
        return 2

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
    # rules_loaded_hash: a stable fingerprint of the EXACT injected rule block
    # (sel.render() is the names + bodies + order that go into the system prompt),
    # so a downstream correlation pass (epic #197 slice D) can ask which injected
    # rule set changed local-model behavior. Three distinct buckets, never folded:
    # "none" — rules disabled (--no-rules); "no-match" — rules active but zero
    # scored against the task (a selector-coverage signal, NOT the same condition
    # as rules-off); a 16-hex hash — the specific rule set that was injected.
    rules_loaded_hash = "none"
    if not a.no_rules:
        system, sel = compose_system(a.system, a.task, a.rules_dir, a.max_rules, a.rules_budget)
        if sel.selected:
            rules_loaded_hash = hashlib.sha256(sel.render().encode()).hexdigest()[:16]
        else:
            rules_loaded_hash = "no-match"
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
    tools = [] if a.no_tools else TOOLS + ([USE_SKILL_TOOL] if skills else [])

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
    # Who actually serves the turns. The transport fills this in as it goes, so
    # it is readable after the run even when the run failed (#667).
    provenance = {}
    transport = ollama_transport(a.model, host=a.host, temperature=a.temperature,
                                 num_ctx=a.num_ctx, timeout=a.timeout, think=a.think,
                                 provenance=provenance)
    prompt_chars = len(system) + len(a.task)
    print(f"prompt: {prompt_chars} chars (system={len(system)}, task={len(a.task)}) | num_ctx={a.num_ctx}",
          file=sys.stderr)
    if prompt_chars > a.num_ctx * 3:
        print(f"warning: prompt size ({prompt_chars} chars) may exceed num_ctx={a.num_ctx} (~{a.num_ctx * 3} chars); consider --num-ctx",
              file=sys.stderr)
    usage_tracker = {"ollama_input_tokens": 0, "ollama_output_tokens": 0, "turns": 0,
                     "verified": None, "gated": bool(a.verify_cmd)}
    _install_kill_handlers()
    rec = None
    exit_code = 0
    try:
        rec = run_agent(a.task, system, transport, toolbox, tools, turn_cap=a.turn_cap,
                        run_id=a.run_id, verify_cmd=a.verify_cmd, usage_tracker=usage_tracker)
    except KeyboardInterrupt:
        print("agent interrupted", file=sys.stderr)
        rec = _crash_record("killed", a.run_id, usage_tracker, toolbox)
        exit_code = 130
    # Deliberately broad. The ledger's job is to record that a run burned tokens,
    # and a TypeError in the loop burned them exactly as a RuntimeError would.
    # Naming only the types seen so far puts the next unseen one back in the hole
    # this catch exists to close, so the class goes in the message instead.
    except Exception as e:
        print(f"agent failed: {type(e).__name__}: {e}", file=sys.stderr)
        rec = _crash_record("error", a.run_id, usage_tracker, toolbox)
        exit_code = 1
    finally:
        # Before close(), and on the success path too — see the helper's docstring.
        _restore_default_kill_handlers()
        if mcp_transport:
            mcp_transport.close()

    rec["rules_loaded_hash"] = rules_loaded_hash
    rec["model"] = a.model

    # Record the local model's token usage to the ledger so a consumer can
    # attribute/estimate delegation savings. Best-effort: a ledger write failure
    # warns but never fails the run.
    led = append_run(rec, a.model, a.task_name, a.cwd, provenance=provenance)
    if led is None:
        print("warning: could not write ollama-agent ledger (run unaffected)", file=sys.stderr)

    served = provenance.get("model_served") or []
    # Two independent substitution signals, because either alone can miss it.
    # The model string differing is the obvious one. `routing` is the router
    # saying it resolved an alias, which still fires if the proxy echoes the
    # alias name back and `model_served` therefore looks like an exact match.
    substituted = bool(served) and served != [a.model]
    aliased = any("alias" in r for r in (provenance.get("routing") or []))
    if substituted or aliased:
        where = ", ".join(provenance.get("endpoint") or []) or "unknown endpoint"
        what = ", ".join(served) or "an unreported model"
        print(f"served-by: {what} via {where} (requested {a.model})", file=sys.stderr)

    if exit_code != 0:
        return exit_code

    if a.json:
        print(json.dumps(rec, indent=2))
    else:
        final = rec["transcript"][-1]
        print(f"completed={rec['completed']} verified={rec['verified']} turns={rec['turns']} "
              f"calls={len(rec['calls'])} unknown={rec['unknown_calls']}")
        print(f"ollama tokens: in={rec['ollama_input_tokens']} out={rec['ollama_output_tokens']}")
        print("--- final message ---")
        print(final.get("content", "(no content)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
