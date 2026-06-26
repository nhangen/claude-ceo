import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent.registry import (  # noqa: E402
    RegistryError, TaskSpec, filter_tools, gate, load_registry,
)


def _reg(**tasks):
    return {"tasks": tasks}


def test_load_valid_registry():
    specs = load_registry(_reg(
        triage={"runner": "ollama", "model": "gpt-oss:20b", "tier": "deterministic"}))
    s = specs["triage"]
    assert s.model == "gpt-oss:20b" and s.tier == "deterministic" and s.tools == "*"


def test_load_rejects_unknown_runner():
    # The enum-config-typo-fallback incident: `runner: scrpt` must fail loudly.
    with pytest.raises(RegistryError, match="unknown runner"):
        load_registry(_reg(x={"runner": "scrpt", "model": "m", "tier": "deterministic"}))


def test_load_rejects_unknown_tier():
    with pytest.raises(RegistryError, match="unknown tier"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "detrministic"}))


def test_load_rejects_missing_field():
    with pytest.raises(RegistryError, match="missing required field 'model'"):
        load_registry(_reg(x={"runner": "ollama", "tier": "deterministic"}))


def test_load_rejects_bad_tools_type():
    with pytest.raises(RegistryError, match="tools must be"):
        load_registry(_reg(x={"runner": "ollama", "model": "m", "tier": "deterministic", "tools": "run_shell"}))


def test_load_from_json_string():
    specs = load_registry('{"tasks": {"t": {"runner": "ollama", "model": "m", "tier": "deterministic"}}}')
    assert "t" in specs


def test_load_from_file(tmp_path):
    f = tmp_path / "reg.json"
    f.write_text('{"tasks": {"t": {"runner": "ollama", "model": "m", "tier": "low-stakes-write"}}}')
    assert load_registry(str(f))["t"].tier == "low-stakes-write"


def test_gate_allows_deterministic():
    ok, reason = gate(TaskSpec("t", "ollama", "m", "deterministic"))
    assert ok and reason == "ok"


def test_gate_allows_low_stakes_write():
    ok, _ = gate(TaskSpec("t", "ollama", "m", "low-stakes-write"))
    assert ok


def test_gate_rejects_high_stakes():
    ok, reason = gate(TaskSpec("t", "ollama", "m", "high-stakes"))
    assert not ok and "may not be delegated" in reason


def test_gate_rejects_unknown_runner_defense_in_depth():
    # gate re-checks even if a TaskSpec is hand-built bypassing load validation.
    ok, reason = gate(TaskSpec("t", "bogus", "m", "deterministic"))
    assert not ok and "unknown runner" in reason


def test_filter_tools_star_is_passthrough():
    tools = [{"function": {"name": "run_shell"}}, {"function": {"name": "git"}}]
    assert filter_tools(tools, "*") == tools


def test_filter_tools_restricts_to_allowlist():
    tools = [{"function": {"name": "run_shell"}}, {"function": {"name": "git"}},
             {"function": {"name": "write_file"}}]
    kept = {t["function"]["name"] for t in filter_tools(tools, ["git", "read_file"])}
    assert kept == {"git"}


def test_filter_tools_empty_allowlist_yields_nothing():
    tools = [{"function": {"name": "run_shell"}}]
    assert filter_tools(tools, []) == []


def test_load_bad_json_raises_valueerror():
    with pytest.raises(ValueError):
        load_registry("{not valid json")
