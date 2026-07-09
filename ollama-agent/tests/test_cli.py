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

    def fake_run_agent(task, system, transport, toolbox, tools, turn_cap=8, run_id=None,
                       verify_cmd=None):
        captured["system"] = system
        captured["tools"] = tools
        captured["run_id"] = run_id
        captured["verify_cmd"] = verify_cmd
        return {"completed": True, "verified": None, "turns": 1, "run_id": run_id,
                "ollama_input_tokens": 40, "ollama_output_tokens": 400,
                "transcript": [{"role": "assistant", "content": "done"}],
                "calls": [], "unknown_calls": []}
    monkeypatch.setattr(cli, "run_agent", fake_run_agent)
    # Neutralize the ledger write so cli tests never touch the real state dir;
    # capture the args instead for the tests that assert on them.
    monkeypatch.setattr(cli, "append_run",
                        lambda rec, model, task_name, cwd: captured.setdefault("ledger", (model, task_name, cwd)) or "/dev/null/ledger")


def _tool_names(tools):
    return {t["function"]["name"] for t in tools}


def test_cli_injects_matching_rule(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "stage the tmp log files for a commit", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-skills"])
    assert rc == 0
    assert "no-commit-tmp-logs" in captured["system"]
    err = capsys.readouterr().err
    assert "matched 1" in err and "no-commit-tmp-logs" in err


def test_cli_human_output_prints_summary_and_final_message(tmp_path, monkeypatch, capsys):
    # The non-`--json` branch (cli.py:186-191): prints the completed/turns/calls
    # summary line plus the final assistant message. test_cli_threads_run_id
    # covers the `--json` branch; this covers its human-readable counterpart.
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "do work", "--cwd", str(tmp_path), "--no-rules", "--no-skills"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "completed=True verified=None turns=1 calls=0 unknown=[]" in out
    assert "--- final message ---" in out and "done" in out


def test_cli_threads_run_id_into_record(tmp_path, monkeypatch, capsys):
    import json
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "do work", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--run-id", "run-xyz", "--json"])
    assert rc == 0
    assert captured["run_id"] == "run-xyz"
    assert json.loads(capsys.readouterr().out)["run_id"] == "run-xyz"


def test_cli_run_id_defaults_none(tmp_path, monkeypatch, capsys):
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "do work", "--cwd", str(tmp_path), "--no-rules", "--no-skills"])
    assert rc == 0
    assert captured["run_id"] is None


def test_cli_rules_loaded_hash_none_when_rules_off(tmp_path, monkeypatch, capsys):
    _stub(monkeypatch, {})
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills", "--json"])
    assert rc == 0
    assert json.loads(capsys.readouterr().out)["rules_loaded_hash"] == "none"


def test_cli_rules_loaded_hash_stable_and_content_sensitive(tmp_path, monkeypatch, capsys):
    # The hash fingerprints the exact injected rule block (epic #197 slice D), so
    # it must be a stable 16-hex digest for a fixed rule set and CHANGE when a
    # selected rule's body changes — otherwise it can't attribute a behavior shift.
    rules = _fixture_rules(tmp_path)
    args = ["--task", "stage the tmp log files for a commit", "--cwd", str(tmp_path),
            "--rules-dir", str(rules), "--no-skills", "--json", "--ungated"]

    _stub(monkeypatch, {})
    cli.main(args); h1 = json.loads(capsys.readouterr().out)["rules_loaded_hash"]
    assert len(h1) == 16 and all(c in "0123456789abcdef" for c in h1)

    cli.main(args); h2 = json.loads(capsys.readouterr().out)["rules_loaded_hash"]
    assert h1 == h2, "same rule set must yield the same hash"

    # Change the selected rule's body → hash must differ.
    (rules / "no-commit-tmp-logs.md").write_text(
        "---\ndescription: never commit tmp log files\nglobs:\n---\n\n# no-commit-tmp-logs\n\nDIFFERENT body\n")
    cli.main(args); h3 = json.loads(capsys.readouterr().out)["rules_loaded_hash"]
    assert h3 != h1, "editing a selected rule's body must change the hash"


def test_cli_no_rules_skips_injection(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "stage the tmp log files", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-rules", "--no-skills"])
    assert rc == 0
    assert "no-commit-tmp-logs" not in captured["system"]
    assert "rules:" not in capsys.readouterr().err


def test_cli_no_match_reports_zero(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)
    _stub(monkeypatch, {})
    rc = cli.main(["--ungated", "--task", "paint the fence blue", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-skills"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "matched 0" in err and "(none matched)" in err


def test_cli_rules_loaded_hash_no_match_distinct_from_none(tmp_path, monkeypatch, capsys):
    # Rules active but zero matched is "no-match", NOT "none" (--no-rules). The
    # slice-D correlation pass must tell a selector-coverage gap apart from a
    # rules-off run. Revert the `else: "no-match"` branch and this reads "none".
    rules = _fixture_rules(tmp_path)
    _stub(monkeypatch, {})
    rc = cli.main(["--ungated", "--task", "paint the fence blue", "--cwd", str(tmp_path),
                   "--rules-dir", str(rules), "--no-skills", "--json"])
    assert rc == 0
    assert json.loads(capsys.readouterr().out)["rules_loaded_hash"] == "no-match"


def test_cli_transport_failure_returns_1(tmp_path, monkeypatch, capsys):
    rules = _fixture_rules(tmp_path)

    def boom(task, system, transport, toolbox, tools, turn_cap=8, run_id=None,
             verify_cmd=None):
        raise RuntimeError("ollama unreachable")
    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: None)
    monkeypatch.setattr(cli, "run_agent", boom)
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--rules-dir", str(rules), "--no-rules", "--no-skills"])
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
    rc = cli.main(["--ungated", "--task", "do a thing", "--cwd", str(tmp_path),
                   "--no-rules", "--skills-dir", str(skills)])
    assert rc == 0
    assert "obsidian-save" in captured["system"] and "use_skill" in captured["system"]
    assert "use_skill" in _tool_names(captured["tools"])
    assert "skills: 1 available" in capsys.readouterr().err


def test_cli_no_skills_suppresses_catalog_and_tool(tmp_path, monkeypatch, capsys):
    skills = _fixture_skills(tmp_path)
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "do a thing", "--cwd", str(tmp_path),
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
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--mcp", "fake-server arg"])
    assert rc == 0
    assert "mcp__echo" in _tool_names(captured["tools"])
    assert "mcp: 1 tools" in capsys.readouterr().err
    assert closed["v"] is True   # finally teardown ran


def test_cli_mcp_bridge_failure_returns_1_and_closes(tmp_path, monkeypatch, capsys):
    closed = {"v": False}
    _stub(monkeypatch, {})
    _stub_mcp(monkeypatch, closed, init_raises=True)
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
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


def _scores_file(tmp_path, body):
    f = tmp_path / "scores.tsv"
    f.write_text(body)
    return str(f)


def test_cli_min_score_missing_scores_file_rejects(tmp_path, monkeypatch, capsys):
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "gpt-oss:20b",
                                 "tier": "deterministic", "min_score": 0.8,
                                 "eval_task": "think-02"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t",
                   "--scores", str(tmp_path / "nope.tsv")])
    assert rc == 3
    assert "eval scores file not found" in capsys.readouterr().err


def test_cli_min_score_default_scores_path_resolves(tmp_path, monkeypatch):
    # Locks the default --scores repoint: with no explicit --scores, the gate must
    # resolve ~/.claude/skills/model-matrix/scripts/out/scores.tsv. Reverting the
    # default path string in cli.py fails this test (the old evals/ path won't
    # exist under the patched home).
    out = tmp_path / ".claude/skills/model-matrix/scripts/out"
    out.mkdir(parents=True)
    (out / "scores.tsv").write_text(
        "task\tmodel\tcorrect\ttotal\tratio\nthink-02\tgpt-oss.20b\t9\t10\t0.9000\n")
    monkeypatch.setattr(cli.Path, "home", staticmethod(lambda: tmp_path))
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "gpt-oss:20b",
                                 "tier": "deterministic", "min_score": 0.8,
                                 "eval_task": "think-02"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t"])
    assert rc == 0


def test_cli_min_score_default_scores_absent_rejects(tmp_path, monkeypatch, capsys):
    # The likely production failure: the model-matrix skill isn't installed, so the
    # default scores path doesn't exist → refuse (exit 3), never a silent pass.
    monkeypatch.setattr(cli.Path, "home", staticmethod(lambda: tmp_path))
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "gpt-oss:20b",
                                 "tier": "deterministic", "min_score": 0.8,
                                 "eval_task": "think-02"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t"])
    assert rc == 3
    assert "eval scores file not found" in capsys.readouterr().err


def test_cli_min_score_below_threshold_rejects(tmp_path, monkeypatch, capsys):
    sc = _scores_file(tmp_path, "task\tmodel\tcorrect\ttotal\tratio\nthink-02\tgpt-oss.20b\t2\t10\t0.2000\n")
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "gpt-oss:20b",
                                 "tier": "deterministic", "min_score": 0.8,
                                 "eval_task": "think-02"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t", "--scores", sc])
    assert rc == 3
    assert "below min_score" in capsys.readouterr().err


def test_cli_min_score_passing_with_stale_scores_warns_but_runs(tmp_path, monkeypatch, capsys):
    sc = _scores_file(tmp_path, "# generated_at=2000-01-01T00:00:00Z\n"
                                "task\tmodel\tcorrect\ttotal\tratio\nthink-02\tgpt-oss.20b\t9\t10\t0.9000\n")
    reg = _registry(tmp_path, t={"runner": "ollama", "model": "gpt-oss:20b",
                                 "tier": "deterministic", "min_score": 0.8,
                                 "eval_task": "think-02"})
    _stub(monkeypatch, {})
    rc = cli.main(["--task", "x", "--cwd", str(tmp_path), "--no-rules", "--no-skills",
                   "--registry", reg, "--task-name", "t", "--scores", sc])
    assert rc == 0
    assert "stale" in capsys.readouterr().err   # warned, but did not refuse


def test_warn_if_stale_scores_branches(capsys):
    cli._warn_if_stale_scores("2000-01-01T00:00:00Z", 30)
    assert "eval scores are" in capsys.readouterr().err          # old → warns
    cli._warn_if_stale_scores("not-a-timestamp", 30)
    assert "unparseable generated_at" in capsys.readouterr().err  # bad format → warns
    from datetime import datetime, timezone
    fresh = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cli._warn_if_stale_scores(fresh, 30)
    assert capsys.readouterr().err == ""                          # fresh → silent


def test_cli_bare_task_without_ungated_refuses(tmp_path, monkeypatch, capsys):
    # The delegation-gate bypass is no longer the silent default: a bare --task
    # (no --task-name, no --ungated) refuses BEFORE any model call.
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do work", "--cwd", str(tmp_path), "--no-rules", "--no-skills"])
    assert rc == 2
    assert "REFUSED" in capsys.readouterr().err
    assert "system" not in captured   # run_agent never reached


def test_cli_ungated_opt_in_runs(tmp_path, monkeypatch, capsys):
    # With the explicit opt-in, the ad-hoc run proceeds as before.
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do work", "--cwd", str(tmp_path), "--no-rules", "--no-skills", "--ungated"])
    assert rc == 0
    assert "system" in captured       # run_agent reached
