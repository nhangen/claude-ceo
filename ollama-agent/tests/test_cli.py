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
