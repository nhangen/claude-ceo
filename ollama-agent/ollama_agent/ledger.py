"""Append-only ledger of ollama-agent runs.

Each completed run appends one JSON line recording the LOCAL model's token usage
(ground truth from ollama's eval_count/prompt_eval_count) plus enough context to
attribute it: the Claude session that spawned it (CLAUDE_CODE_SESSION_ID), the
model, and the run outcome. A downstream consumer (token-scope) reads this by
path to estimate delegation savings — it never reverse-parses transcripts.

The bridge deliberately records only raw counts + model id here; it does NOT
price the run or compute savings (it has no Claude pricing table and shouldn't
guess). Valuation lives in the consumer.
"""
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def session_id():
    """The Claude session that spawned this run, for attribution downstream.

    Claude Code exports ``CLAUDE_CODE_SESSION_ID`` to the environment of the
    tool calls it makes (including the Bash call that runs this bridge). The
    legacy ``CLAUDE_SESSION_ID`` is honored as a fallback for other harnesses /
    manual runs. Returns None when neither is set (an unattributed run)."""
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CLAUDE_SESSION_ID")


def ledger_path():
    """Resolve the ledger file. OLLAMA_AGENT_LEDGER overrides (tests, custom
    setups); otherwise XDG state dir, falling back to ~/.local/state."""
    override = os.environ.get("OLLAMA_AGENT_LEDGER")
    if override:
        return Path(override)
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "ollama-agent" / "runs.jsonl"


def append_run(rec, model, task_name, cwd, now=None, path=None):
    """Append one run to the ledger. Best-effort: a write failure returns None
    (and never raises) so ledger I/O can't fail an otherwise-successful run.
    Returns the path written on success."""
    p = Path(path) if path is not None else ledger_path()
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = {
        "ts": stamp,
        "run_id": rec.get("run_id"),
        "session_id": session_id(),
        "model": model,
        "task_name": task_name,
        "cwd": cwd,
        "ollama_input_tokens": rec.get("ollama_input_tokens", 0),
        "ollama_output_tokens": rec.get("ollama_output_tokens", 0),
        "turns": rec.get("turns"),
        "completed": rec.get("completed"),
        "verified": rec.get("verified"),
    }
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
        return str(p)
    except Exception:
        # Best-effort telemetry must never fail an otherwise-successful run, so
        # this swallows any error (I/O, or a non-serializable field slipping in),
        # honoring the "never raises" contract above.
        return None
