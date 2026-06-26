"""Task registry + safe-delegation gate.

Declares which bounded tasks may run on a local model and how. Two enum fields
select behavior — `runner` (who executes) and `tier` (how risky) — so both are
validated at parse time AND gated at dispatch, and an unknown value is rejected,
never defaulted (enum-config-typo-fallback: a `runner: scrpt` typo must fail
loudly, not silently fall through to a default path). A high-stakes task can
never be delegated to a local model regardless of what the entry says.
"""
import json
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
    def __init__(self, name, runner, model, tier, tools="*", rules=True, skills=False):
        self.name = name
        self.runner = runner
        self.model = model
        self.tier = tier
        self.tools = tools          # "*" or a list of allowed tool names
        self.rules = rules
        self.skills = skills


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
            skills=entry.get("skills", False))
    return specs


def gate(spec):
    """Dispatch-time gate (defense in depth after parse validation). Returns
    (ok, reason). A non-delegable tier or unknown runner/tier is rejected — the
    caller routes the rejection through failure observability, never runs it."""
    if spec.runner not in RUNNERS:
        return False, f"unknown runner {spec.runner!r}"
    if spec.tier not in TIERS:
        return False, f"unknown tier {spec.tier!r}"
    if spec.tier not in DELEGABLE_TIERS:
        return False, f"tier {spec.tier!r} may not be delegated to a local model"
    return True, "ok"


def filter_tools(tools, allowed):
    """Restrict a tool-schema list to the names a task is allowed to use. `allowed`
    is "*" (no restriction) or a list of permitted tool names."""
    if allowed == "*":
        return tools
    allow = set(allowed)
    return [t for t in tools if t["function"]["name"] in allow]
