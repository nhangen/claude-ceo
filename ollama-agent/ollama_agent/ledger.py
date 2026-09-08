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


# Who served the run, from `provenance` (see transport._note). Each is a list of
# distinct values in first-seen order, because a router re-decides per request.
_PROVENANCE_FIELDS = ("model_served", "endpoint", "proxy", "routing", "request_ids")

# Two things #667 asked for that are deliberately NOT here, recorded so a reader
# who greps the ticket for them is not left wondering:
#
# - `model_requested`. The ticket asked for it as a new key. `model` already
#   holds exactly that and keeps the meaning forever (see append_run), so a
#   second key would duplicate every row. Consumers are unaffected: token-scope
#   reads `run.model`.
# - The backend **ollama** version. Only the proxy's version is captured, from
#   `Via`. Ollama's /api/chat response body carries no version field, so this
#   would need a separate /api/version call per run -- which defeats the "no
#   extra request" property that makes this capture free. Left out on purpose;
#   an upgrade still has to be recorded by hand, as #414 already does.


def append_run(rec, model, task_name, cwd, now=None, path=None, provenance=None):
    """Append one run to the ledger. Best-effort: a write failure returns None
    (and never raises) so ledger I/O can't fail an otherwise-successful run.
    Returns the path written on success.

    `model` is the string the caller ASKED FOR and keeps that meaning forever:
    months of rows mean it, including the #648 and #653 evidence, so a reader
    that reinterpreted it would misattribute every historical run. Who actually
    answered goes in the `model_served` / `endpoint` / `proxy` / `request_ids`
    keys, from `provenance` (#667).

    Those keys are written as explicit nulls when nothing was captured, never
    omitted. An absent key means a row from before this existed; a null means a
    run that was recorded and had nothing to report. Collapsing the two would
    make every old row look like a fresh unattributed one.
    """
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
        "reason": rec.get("reason"),
    }
    prov = provenance or {}
    for key in _PROVENANCE_FIELDS:
        entry[key] = prov.get(key) or None
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
