"""Task registry + safe-delegation gate.

Declares which bounded tasks may run on a local model and how. Two enum fields
select behavior — `runner` (who executes) and `tier` (how risky) — so both are
validated at parse time AND gated at dispatch, and an unknown value is rejected,
never defaulted (enum-config-typo-fallback: a `runner: scrpt` typo must fail
loudly, not silently fall through to a default path). A high-stakes task can
never be delegated to a local model regardless of what the entry says.
"""
import json
import math
from pathlib import Path

RUNNERS = {"ollama"}                       # who may execute a registered task
# Ordered low→high stakes; the order is used verbatim in the "known: …" diagnostic.
TIERS = ["deterministic", "low-stakes-write", "high-stakes"]
# A local model may take deterministic + low-stakes-write work. high-stakes
# (billing, credentials, multi-tenant writes, anything irreversible) is never
# delegated — it stays with a human or a trusted (non-local) agent.
DELEGABLE_TIERS = {"deterministic", "low-stakes-write"}


class RegistryError(ValueError):
    """A registry entry is structurally invalid (missing field or unknown enum).
    Raised at parse time so a typo fails loudly instead of silently defaulting."""


class TaskSpec:
    def __init__(self, name, runner, model, tier, tools="*", rules=True, skills=False,
                 min_score=None, eval_task=None, eval_model=None):
        self.name = name
        self.runner = runner
        self.model = model
        self.tier = tier
        self.tools = tools          # "*" or a list of allowed tool names
        self.rules = rules
        self.skills = skills
        # Empirical-competence gate: refuse delegation unless the model scored
        # >= min_score on the pinned eval_task class. eval_task is REQUIRED when
        # min_score is set (an aggregate-mean default would let a model that
        # fails the task that matters pass on the strength of unrelated tasks);
        # eval_task="*" opts into the cross-task mean explicitly. eval_model
        # defaults to the run model.
        self.min_score = min_score
        self.eval_task = eval_task
        self.eval_model = eval_model


def normalize_model(model):
    """Map a registry model id to the filename/score form. run.sh derives output
    filenames via `tr ':/' '.-'`, so scores.tsv carries `gpt-oss.20b`, not
    `gpt-oss:20b`. Mirror that transform exactly (colon→dot AND slash→dash)."""
    return model.replace(":", ".").replace("/", "-")


def load_scores(source):
    """Parse a scores.tsv (emitted by the model-matrix skill's grade.py). Returns
    (scores, generated_at) where scores is {(task, model): ratio} for rows with
    a non-empty ratio (total>0). A blank ratio (total=0) is omitted — the gate
    treats it as missing → refuse. `source` is a path or the tsv text itself."""
    text = Path(source).read_text() if Path(str(source)).exists() else str(source)
    scores, generated_at = {}, None
    for line in text.splitlines():
        if line.startswith("# generated_at="):
            generated_at = line.split("=", 1)[1].strip()
            continue
        if not line.strip() or line.startswith("task\t"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        task, model, _correct, _total, ratio = parts[:5]
        if ratio.strip() == "":          # total=0 → no usable score
            continue
        try:
            val = float(ratio)
        except ValueError:
            continue
        if not math.isfinite(val):       # nan/inf is not a usable score — a
            continue                     # corrupt value must not slip past the
        scores[(task, model)] = val      # threshold (nan < x is always False)
    return scores, generated_at


def score_for(scores, eval_task, model):
    """Look up the model's ratio for eval_task (model already normalized).
    eval_task="*" averages the model's ratios across all tasks. Returns None
    when there is no usable score (the gate then refuses)."""
    if eval_task == "*":
        vals = [r for (t, m), r in scores.items() if m == model]
        return sum(vals) / len(vals) if vals else None
    return scores.get((eval_task, model))


def _validate(name, entry):
    for field in ("runner", "model", "tier"):
        if not entry.get(field):
            raise RegistryError(f"task {name!r}: missing required field {field!r}")
    if entry["runner"] not in RUNNERS:
        raise RegistryError(
            f"task {name!r}: unknown runner {entry['runner']!r} (known: {sorted(RUNNERS)})")
    if entry["tier"] not in TIERS:
        raise RegistryError(
            f"task {name!r}: unknown tier {entry['tier']!r} (known: {TIERS})")
    tools = entry.get("tools", "*")
    if tools != "*" and not isinstance(tools, list):
        raise RegistryError(f"task {name!r}: tools must be \"*\" or a list, got {type(tools).__name__}")
    if "min_score" in entry and entry["min_score"] is not None:
        ms = entry["min_score"]
        if isinstance(ms, bool) or not isinstance(ms, (int, float)):
            raise RegistryError(f"task {name!r}: min_score must be a number, got {type(ms).__name__}")
        if not entry.get("eval_task"):
            # No aggregate-mean default: a gate that averages away a task-class
            # failure fails open on its whole purpose. Require an explicit pin
            # (use eval_task "*" to opt into the cross-task mean).
            raise RegistryError(f"task {name!r}: min_score requires eval_task (use \"*\" for the cross-task mean)")


def load_registry(source):
    """`source` is a path, a JSON string, or a dict shaped {"tasks": {name: {...}}}.
    Every entry is validated; the first invalid entry raises RegistryError (a bad
    registry is a configuration error, surfaced, not a quietly-skipped task)."""
    if isinstance(source, dict):
        data = source
    else:
        text = Path(source).read_text() if Path(str(source)).exists() else str(source)
        data = json.loads(text)
    tasks = data.get("tasks", {})
    specs = {}
    for name, entry in tasks.items():
        _validate(name, entry)
        specs[name] = TaskSpec(
            name=name, runner=entry["runner"], model=entry["model"], tier=entry["tier"],
            tools=entry.get("tools", "*"), rules=entry.get("rules", True),
            skills=entry.get("skills", False), min_score=entry.get("min_score"),
            eval_task=entry.get("eval_task"), eval_model=entry.get("eval_model"))
    return specs


def gate(spec, scores=None):
    """Dispatch-time gate (defense in depth after parse validation). Returns
    (ok, reason). A non-delegable tier or unknown runner/tier is rejected — the
    caller routes the rejection through failure observability, never runs it.

    When `spec.min_score` is set, `scores` (from load_scores) must be supplied;
    the model is refused unless its ratio on the pinned eval_task is >= min_score.
    A missing/unreadable score is a refusal (reject-don't-default) — never a
    silent pass. Staleness is the caller's concern (log, don't refuse)."""
    if spec.runner not in RUNNERS:
        return False, f"unknown runner {spec.runner!r}"
    if spec.tier not in TIERS:
        return False, f"unknown tier {spec.tier!r}"
    if spec.tier not in DELEGABLE_TIERS:
        return False, f"tier {spec.tier!r} may not be delegated to a local model"
    if spec.min_score is not None:
        model = normalize_model(spec.eval_model or spec.model)
        if scores is None:
            return False, "min_score set but no eval scores available"
        score = score_for(scores, spec.eval_task, model)
        if score is None:
            return False, (f"no eval score for model {model!r} on task "
                           f"{spec.eval_task!r} — cannot confirm competence")
        if score < spec.min_score:
            return False, (f"model {model!r} scored {score:.4f} on {spec.eval_task!r}, "
                           f"below min_score {spec.min_score}")
    return True, "ok"


def filter_tools(tools, allowed):
    """Restrict a tool-schema list to the names a task is allowed to use. `allowed`
    is "*" (no restriction) or a list of permitted tool names."""
    if allowed == "*":
        return tools
    allow = set(allowed)
    return [t for t in tools if t["function"]["name"] in allow]
