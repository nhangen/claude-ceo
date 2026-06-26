import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cli  # noqa: E402


def _rule(d, name, desc):
    (d / f"{name}.md").write_text(f"---\ndescription: {desc}\nglobs:\n---\n\n# {name}\n\nbody\n")


def _fixture_rules(tmp_path):
    d = tmp_path / "rules"
    d.mkdir()
    _rule(d, "no-commit-tmp-logs", "never commit tmp log files")
    return d


def _stub(monkeypatch, captured):
    # Replace the network pieces so main() runs offline; capture the system prompt
    # run_agent receives so the test can assert what rule text was injected.
    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: (lambda m, t: {"role": "assistant", "content": "ok"}))

    def fake_run_agent(task, system, transport, toolbox, tools, turn_cap=8):
        captured["system"] = system
        captured["tools"] = tools
        return {"completed": True, "turns": 1, "transcript": [{"role": "assistant", "content": "done"}],
                "calls": [], "unknown_calls": []}
    monkeypatch.setattr(cli, "run_agent", fake_run_agent)


def _tool_names(tools):
    return {t["function"]["name"] for t in tools}


def test_cli_injects_matching_rule(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "stage the tmp log files for a commit", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-skills"])
    assert rc == 0
    assert "no-commit-tmp-logs" in captured["system"]
    err = capsys.readouterr().err
    assert "matched 1" in err and "no-commit-tmp-logs" in err


def test_cli_no_rules_skips_injection(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "stage the tmp log files", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-rules", "--no-skills"])
    assert rc == 0
    assert "no-commit-tmp-logs" not in captured["system"]
    assert "rules:" not in capsys.readouterr().err


def test_cli_no_match_reports_zero(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "paint the fence blue", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-skills"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "matched 0" in err and "(none matched)" in err


def test_cli_transport_failure_returns_1(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)

    def boom(task, system, transport, toolbox, tools, turn_cap=8):
        raise RuntimeError("ollama unreachable")
    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: None)
    monkeypatch.setattr(cli, "run_agent", boom)
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--rules-dir", str(rules), "--no-rules", "--no-skills"])
    assert rc == 1
    assert "agent failed" in capsys.readouterr().err


def _fixture_skills(tmp_path):
    r = tmp_path / "skills" / "obsidian-save"
    r.mkdir(parents=True)
    (r / "SKILL.md").write_text("---\nname: obsidian-save\ndescription: save to vault\n---\n\n# save\nbody\n")
    return tmp_path / "skills"


def test_cli_injects_skill_catalog_and_use_skill_tool(tmp_path, monkeypatch, capsys):
    skills = _fixture_skills(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do a thing", "--cwd", str(tmp_path),
                   "--no-rules", "--skills-dir", str(skills)])
    assert rc == 0
    assert "obsidian-save" in captured["system"] and "use_skill" in captured["system"]
    assert "use_skill" in _tool_names(captured["tools"])
    assert "skills: 1 available" in capsys.readouterr().err


def test_cli_no_skills_suppresses_catalog_and_tool(tmp_path, monkeypatch, capsys):
    skills = _fixture_skills(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do a thing", "--cwd", str(tmp_path),
                   "--no-rules", "--skills-dir", str(skills), "--no-skills"])
    assert rc == 0
    assert "obsidian-save" not in captured["system"]
    assert "use_skill" not in _tool_names(captured["tools"])
    assert "skills:" not in capsys.readouterr().err


def _stub_mcp(monkeypatch, closed, *, init_raises=False):
    class FT:
        def __init__(self, *a, **k):
            pass

        def close(self):
            closed["v"] = True
    monkeypatch.setattr(cli, "StdioMCPTransport", FT)

    class FC:
        def __init__(self, t):
            pass

        def initialize(self):
            if init_raises:
                raise RuntimeError("no server there")

        def list_tools(self):
            return [{"name": "echo", "description": "e", "inputSchema": {"type": "object", "properties": {}}}]
    monkeypatch.setattr(cli, "MCPClient", FC)


def test_cli_mcp_bridges_tools_and_closes_transport(tmp_path, monkeypatch, capsys):
    captured, closed = {}, {"v": False}
    _stub(monkeypatch, captured)
    _stub_mcp(monkeypatch, closed)
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--mcp", "fake-server arg"])
    assert rc == 0
    assert "mcp__echo" in _tool_names(captured["tools"])
    assert "mcp: 1 tools" in capsys.readouterr().err
    assert closed["v"] is True   # finally teardown ran


def test_cli_mcp_bridge_failure_returns_1_and_closes(tmp_path, monkeypatch, capsys):
    closed = {"v": False}
    _stub(monkeypatch, {})
    _stub_mcp(monkeypatch, closed, init_raises=True)
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--mcp", "broken-server"])
    assert rc == 1
    assert "mcp bridge failed for 'broken-server'" in capsys.readouterr().err
    assert closed["v"] is True


def _registry(tmp_path, **tasks):
    f = tmp_path / "reg.json"
    f.write_text(json.dumps({"tasks": tasks}))
    return str(f)


def test_cli_registered_deterministic_task_applies_model_and_runs(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, triage={"runner": "ollama", "model": "registry-model:7b",
                                       "tier": "deterministic", "tools": ["run_shell", "git"]})
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do triage", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "triage"])
    assert rc == 0
    assert _tool_names(captured["tools"]) == {"run_shell", "git"}   # restricted to allowlist
    err = capsys.readouterr().err
    assert "model=registry-model:7b" in err and "tools restricted to:" in err


def test_cli_high_stakes_task_is_rejected_before_any_run(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, payout={"runner": "ollama", "model": "m", "tier": "high-stakes"})
    captured = {}

    def must_not_run(*a, **k):
        raise AssertionError("run_agent must not be called for a rejected task")
    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: None)
    monkeypatch.setattr(cli, "run_agent", must_not_run)
    rc = cli.main(["--task", "pay the invoice", "--cwd", str(tmp_path),
                   "--registry", reg, "--task-name", "payout"])
    assert rc == 3
    assert "REJECTED task 'payout'" in capsys.readouterr().err


def test_cli_unknown_registered_task_returns_2(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, triage={"runner": "ollama", "model": "m", "tier": "deterministic"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--registry", reg, "--task-name", "nope"])
    assert rc == 2
    assert "no registered task 'nope'" in capsys.readouterr().err


def test_cli_bad_registry_runner_returns_2(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, x={"runner": "scrpt", "model": "m", "tier": "deterministic"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--registry", reg, "--task-name", "x"])
    assert rc == 2
    err = capsys.readouterr().err
    assert "registry error" in err and "unknown runner" in err


def test_cli_task_name_without_registry_returns_2(tmp_path, monkeypatch, capsys):
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--task-name", "t"])
    assert rc == 2
    assert "requires --registry" in capsys.readouterr().err


def test_cli_registry_tool_typo_is_warned_not_silent(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "m", "tier": "deterministic",
                                 "tools": ["read-file", "git"]})  # 'read-file' is a typo
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t"])
    assert rc == 0
    assert _tool_names(captured["tools"]) == {"git"}   # only the valid name survives
    assert "not available (ignored): read-file" in capsys.readouterr().err


def test_cli_registry_rules_skills_propagation(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "m", "tier": "deterministic",
                                 "rules": False, "skills": False})
    captured = {}
    _stub(monkeypatch, captured)
    # rules-dir/skills-dir point at fixtures, but the spec forces them off
    rules = _fixture_rules(tmp_path)
    skills = _fixture_skills(tmp_path)
    rc = cli.main(["--task", "stage the tmp log files", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--skills-dir", str(skills),
                   "--registry", reg, "--task-name", "t"])
    assert rc == 0
    assert "no-commit-tmp-logs" not in captured["system"]   # rules:false honored
    assert "use_skill" not in _tool_names(captured["tools"])  # skills:false honored
    err = capsys.readouterr().err
    assert "rules:" not in err and "skills:" not in err
