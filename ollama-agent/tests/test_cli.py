import json
import sys
from pathlib import Path

import pytest

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
                       verify_cmd=None, usage_tracker=None):
        captured["system"] = system
        captured["tools"] = tools
        captured["run_id"] = run_id
        captured["verify_cmd"] = verify_cmd
        if usage_tracker is not None:
            usage_tracker["ollama_input_tokens"] = 40
            usage_tracker["ollama_output_tokens"] = 400
            usage_tracker["turns"] = 1
        return {"completed": True, "verified": None, "turns": 1, "run_id": run_id,
                "ollama_input_tokens": 40, "ollama_output_tokens": 400,
                "transcript": [{"role": "assistant", "content": "done"}],
                "calls": [], "unknown_calls": []}
    monkeypatch.setattr(cli, "run_agent", fake_run_agent)
    # Neutralize the ledger write so cli tests never touch the real state dir;
    # capture the args instead for the tests that assert on them.
    # The signature is pinned positionally on purpose rather than swallowed with
    # **kwargs: it is what caught the #667 provenance argument being added, and a
    # stub that accepts anything cannot report a caller drifting from the real one.
    def fake_append_run(rec, model, task_name, cwd, provenance=None):
        captured["ledger"] = (model, task_name, cwd)
        captured["provenance"] = provenance
        return "/dev/null/ledger"

    monkeypatch.setattr(cli, "append_run", fake_append_run)


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


def _transport_kwargs(tmp_path, monkeypatch, argv):
    """Run main() offline and return the kwargs it handed ollama_transport."""
    captured = {}
    _stub(monkeypatch, captured)
    seen = {}
    monkeypatch.setattr(cli, "ollama_transport",
                        lambda *a, **k: seen.update(k) or (lambda m, t: {"role": "assistant", "content": "ok"}))
    rc = cli.main(["--task", "do work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--ungated"] + argv)
    assert rc == 0
    return seen


def test_cli_defaults_leave_thinking_to_the_model(tmp_path, monkeypatch):
    # Existing callers must be unaffected: think=None means the payload carries no
    # "think" key at all, which is what shipped before the flag existed.
    seen = _transport_kwargs(tmp_path, monkeypatch, [])
    assert seen["think"] is None
    assert seen["timeout"] == 600


def test_cli_no_think_reaches_the_transport(tmp_path, monkeypatch):
    # The wrapper that needs this (ollama-review.sh) runs one long analytic turn, where
    # a thinking model spends the whole turn reasoning and never answers.
    seen = _transport_kwargs(tmp_path, monkeypatch, ["--no-think"])
    assert seen["think"] is False


def test_cli_timeout_reaches_the_transport(tmp_path, monkeypatch):
    seen = _transport_kwargs(tmp_path, monkeypatch, ["--timeout", "1200"])
    assert seen["timeout"] == 1200


def test_cli_no_tools_offers_an_empty_toolset(tmp_path, monkeypatch):
    # A review is one completion. Given tools, the model was measured spending its whole
    # turn budget grepping the file already pasted into its prompt and never answering.
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "review this", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--ungated", "--no-tools"])
    assert rc == 0
    assert captured["tools"] == []


def test_cli_tools_are_offered_by_default(tmp_path, monkeypatch):
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--task", "do work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--ungated"])
    assert rc == 0
    assert captured["tools"], "the default must keep offering the toolset"


def test_cli_writes_the_reason_to_a_real_ledger(tmp_path, monkeypatch, capsys):
    # End-to-end through the wiring the other cli tests stub out: real run_agent,
    # real append_run, a real ledger file. Only the network transport is faked.
    # `_stub` replaces both run_agent and append_run, so a `reason` asserted only
    # there would pass with the field never reaching a ledger row.
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))
    monkeypatch.setattr(cli, "ollama_transport",
                        lambda *a, **k: (lambda m, t: ({"role": "assistant", "content": "ok"},
                                                       {"input": 10, "output": 20})))
    rc = cli.main(["--ungated", "--task", "fix it", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--verify-cmd", "false", "--turn-cap", "2"])
    assert rc == 0
    row = json.loads(ledger.read_text().strip())
    assert row["completed"] is False
    assert row["verified"] is False
    assert row["reason"] == "verify-failed"


def test_cli_logs_prompt_size_and_num_ctx(tmp_path, monkeypatch, capsys):
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "do work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--num-ctx", "32768"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "prompt:" in err
    assert "num_ctx=32768" in err


def test_cli_warns_when_prompt_may_overflow_context(tmp_path, monkeypatch, capsys):
    captured = {}
    _stub(monkeypatch, captured)
    rc = cli.main(["--ungated", "--task", "x" * 500, "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--num-ctx", "100"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "warning: prompt size" in err
    assert "may exceed num_ctx=100" in err


def test_cli_surfaces_overflow_diagnostic_raised_by_parse(tmp_path, monkeypatch, capsys):
    # Named for what it reaches: parse_chat_response directly, then cli's RuntimeError
    # handler. urlopen and the HTTPError path in ollama_transport are stubbed out, so
    # this does not show that a real 500 arrives here — test_agent covers parse itself.
    def failing_transport(m, t):
        from ollama_agent.transport import parse_chat_response
        return parse_chat_response(500, '{"error":"no user query found in messages"}')

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: failing_transport)
    rc = cli.main(["--ungated", "--task", "large task", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills"])
    assert rc == 1
    err = capsys.readouterr().err
    # The class prefix comes from #383's crash handler, which now names the
    # exception type; the diagnostic itself is #376's.
    assert "agent failed: RuntimeError: ollama HTTP 500: prompt exceeded context window" in err
    assert "--num-ctx" in err


def test_cli_crashed_run_writes_error_ledger_row_with_accumulated_tokens(tmp_path, monkeypatch, capsys):
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))

    call_count = 0
    def failing_transport(messages, tools):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return ({"role": "assistant", "tool_calls": [{"function": {"name": "list_dir", "arguments": {"path": "."}}}]},
                    {"input": 50, "output": 15})
        raise RuntimeError("model transport failed mid-run")

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: failing_transport)
    rc = cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--turn-cap", "5"])
    assert rc == 1
    err = capsys.readouterr().err
    assert "agent failed: RuntimeError: model transport failed mid-run" in err
    row = json.loads(ledger.read_text().strip())
    assert row["completed"] is False
    assert row["verified"] is None
    assert row["reason"] == "error"
    assert row["ollama_input_tokens"] == 50
    assert row["ollama_output_tokens"] == 15
    # 2 turns carrying 1 turn's tokens is the intended reading: on a crash row
    # `turns` is the turn the run died on, not the count it completed. See the
    # usage_tracker paragraph in run_agent's docstring.
    assert row["turns"] == 2


def test_cli_interrupted_run_writes_killed_ledger_row(tmp_path, monkeypatch, capsys):
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))

    call_count = 0
    def interrupt_transport(messages, tools):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return ({"role": "assistant", "tool_calls": [{"function": {"name": "list_dir", "arguments": {"path": "."}}}]},
                    {"input": 30, "output": 10})
        raise KeyboardInterrupt()

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: interrupt_transport)
    rc = cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--turn-cap", "5"])
    assert rc == 130
    err = capsys.readouterr().err
    assert "agent interrupted" in err
    row = json.loads(ledger.read_text().strip())
    assert row["completed"] is False
    assert row["verified"] is None
    assert row["reason"] == "killed"
    assert row["ollama_input_tokens"] == 30
    assert row["ollama_output_tokens"] == 10
    assert row["turns"] == 2


def test_cli_crashed_run_immediate_records_zero_tokens(tmp_path, monkeypatch, capsys):
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))

    def immediate_fail(messages, tools):
        raise RuntimeError("daemon unreachable")

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: immediate_fail)
    rc = cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills"])
    assert rc == 1
    row = json.loads(ledger.read_text().strip())
    assert row["completed"] is False
    assert row["reason"] == "error"
    assert row["ollama_input_tokens"] == 0
    assert row["ollama_output_tokens"] == 0


def test_cli_crashed_run_records_a_row_for_a_non_runtimeerror(tmp_path, monkeypatch, capsys):
    # The except is deliberately broad — the ledger's job is to record burned
    # tokens whatever killed the run. Narrowing it to RuntimeError would put
    # every other exception back in the hole #328 closes.
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))

    call_count = 0

    def failing_transport(messages, tools):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return ({"role": "assistant",
                     "tool_calls": [{"function": {"name": "list_dir",
                                                  "arguments": {"path": "."}}}]},
                    {"input": 11, "output": 22})
        raise OSError("connection reset by peer")

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: failing_transport)
    rc = cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--turn-cap", "5"])
    assert rc == 1
    assert "agent failed: OSError: connection reset by peer" in capsys.readouterr().err
    row = json.loads(ledger.read_text().strip())
    assert row["reason"] == "error"
    assert row["ollama_input_tokens"] == 11
    assert row["ollama_output_tokens"] == 22


def test_cli_crashed_run_after_a_red_gate_records_verified_false(tmp_path, monkeypatch, capsys):
    # None means "no gate was configured" (run_agent's contract), so a gated run
    # that drove the gate red and then crashed must not report None — that reads
    # as ungated to every ledger consumer.
    ledger = tmp_path / "runs.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(ledger))

    call_count = 0
    def gate_then_crash(messages, tools):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            # No tool calls, so the gate runs — and `false` exits non-zero.
            return ({"role": "assistant", "content": "done"}, {"input": 7, "output": 3})
        raise RuntimeError("transport died after the gate went red")

    monkeypatch.setattr(cli, "ollama_transport", lambda *a, **k: gate_then_crash)
    rc = cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                   "--no-rules", "--no-skills", "--verify-cmd", "false", "--turn-cap", "5"])
    assert rc == 1
    row = json.loads(ledger.read_text().strip())
    assert row["reason"] == "error"
    assert row["verified"] is False
    assert row["ollama_input_tokens"] == 7


def test_cli_sigterm_writes_a_killed_ledger_row(tmp_path):
    # A real subprocess and a real signal. monkeypatch-raising KeyboardInterrupt
    # exercises the handler arm but not the signal disposition, which is the half
    # that was missing: a supervisor stop sends SIGTERM, not SIGINT.
    import os
    import signal as signal_mod
    import subprocess
    import time

    ledger = tmp_path / "runs.jsonl"
    driver = tmp_path / "driver.py"
    driver.write_text(
        "import sys, time\n"
        f"sys.path.insert(0, {str(Path(cli.__file__).resolve().parent)!r})\n"
        "import cli\n"
        "calls = []\n"
        "def slow(messages, tools):\n"
        "    calls.append(1)\n"
        "    if len(calls) == 1:\n"
        "        return ({'role': 'assistant', 'tool_calls': [{'function': "
        "{'name': 'list_dir', 'arguments': {'path': '.'}}}]}, {'input': 77, 'output': 33})\n"
        "    sys.stderr.write('READY\\n'); sys.stderr.flush()\n"
        "    time.sleep(120)\n"
        "cli.ollama_transport = lambda *a, **k: slow\n"
        f"sys.exit(cli.main(['--ungated', '--task', 'work', '--cwd', {str(tmp_path)!r},\n"
        "                   '--no-rules', '--no-skills', '--turn-cap', '5']))\n"
    )
    env = dict(os.environ, OLLAMA_AGENT_LEDGER=str(ledger))
    proc = subprocess.Popen([sys.executable, str(driver)], env=env,
                            stderr=subprocess.PIPE, text=True)
    try:
        ready = False
        deadline = time.time() + 30
        while time.time() < deadline:
            line = proc.stderr.readline()
            if not line:
                break
            if "READY" in line:
                ready = True
                break
        if not ready:
            # Otherwise a driver that dies during import degrades into a 30s
            # timeout and we signal a corpse, which is a mystery, not a failure.
            proc.kill()
            pytest.fail(f"driver never reached the second turn: {proc.stderr.read()!r}")
        proc.send_signal(signal_mod.SIGTERM)
        rc = proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)

    assert rc == 130
    row = json.loads(ledger.read_text().strip())
    assert row["reason"] == "killed"
    assert row["completed"] is False
    assert row["ollama_input_tokens"] == 77
    assert row["ollama_output_tokens"] == 33


def test_cli_main_leaves_the_kill_handlers_as_it_found_them(tmp_path, monkeypatch):
    # main() is callable in-process and this suite calls it forty times. A handler
    # left installed past a normal return rewrites the caller's signal disposition
    # for the rest of the process.
    import signal as signal_mod

    before = {name: signal_mod.getsignal(getattr(signal_mod, name))
              for name in ("SIGTERM", "SIGHUP")}
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(tmp_path / "runs.jsonl"))
    monkeypatch.setattr(cli, "ollama_transport",
                        lambda *a, **k: (lambda m, t: ({"role": "assistant", "content": "ok"},
                                                       {"input": 1, "output": 1})))
    assert cli.main(["--ungated", "--task", "work", "--cwd", str(tmp_path),
                     "--no-rules", "--no-skills"]) == 0
    after = {name: signal_mod.getsignal(getattr(signal_mod, name))
             for name in ("SIGTERM", "SIGHUP")}
    assert after == before


def test_cli_threads_provenance_from_transport_to_ledger(tmp_path, monkeypatch, capsys):
    """The unit arms in test_provenance.py prove the transport captures who
    served and that the ledger can store it. Neither proves main() connects the
    two, which is the whole fix: for thirteen runs the resolution was available
    on every response and never reached a row (#667).

    So this asserts the SAME dict object travels transport -> append_run, rather
    than that each end works in isolation.
    """
    captured = {}
    _stub(monkeypatch, captured)

    def transport_that_reports(*a, **k):
        prov = k["provenance"]
        captured["handed_to_transport"] = prov
        prov["model_served"] = ["hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"]
        prov["endpoint"] = ["ml1-5080"]
        return lambda m, t: {"role": "assistant", "content": "ok"}

    monkeypatch.setattr(cli, "ollama_transport", transport_that_reports)
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--model", "local-coder",
                   "--no-rules", "--no-skills"])
    assert rc == 0
    assert captured["provenance"] is captured["handed_to_transport"], \
        "main() handed the ledger a different dict than the transport filled in"
    assert captured["provenance"]["model_served"] == ["hf.co/Qwen/Qwen3-14B-GGUF:Q5_K_M"]

    # And the operator is told, because a row nobody reads is how this was missed.
    err = capsys.readouterr().err
    assert "served-by:" in err
    assert "Qwen3-14B" in err and "ml1-5080" in err and "requested local-coder" in err


def test_cli_stays_quiet_when_the_served_model_is_the_one_requested(tmp_path, monkeypatch, capsys):
    """The `served-by:` line exists to flag a SUBSTITUTION. Printing it on every
    run would make the signal invisible again, one line down."""
    captured = {}
    _stub(monkeypatch, captured)

    def transport_that_reports(*a, **k):
        k["provenance"]["model_served"] = ["qwen3.8:27b"]
        return lambda m, t: {"role": "assistant", "content": "ok"}

    monkeypatch.setattr(cli, "ollama_transport", transport_that_reports)
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--model", "qwen3.8:27b",
                   "--no-rules", "--no-skills"])
    assert rc == 0
    assert "served-by:" not in capsys.readouterr().err


def test_cli_warns_on_alias_routing_even_when_the_model_string_matches(tmp_path, monkeypatch, capsys):
    """The substitution that hid for thirteen runs was visible two ways: the model
    came back different, AND the router said it resolved an alias. Relying only on
    the first means a proxy that echoes the requested alias goes unreported --
    which is the exact shape of the original failure, one layer down."""
    captured = {}
    _stub(monkeypatch, captured)

    def transport_that_reports(*a, **k):
        prov = k["provenance"]
        prov["model_served"] = ["local-coder"]   # proxy echoed the alias back
        prov["endpoint"] = ["ml1-5080"]
        prov["routing"] = ["alias"]
        return lambda m, t: {"role": "assistant", "content": "ok"}

    monkeypatch.setattr(cli, "ollama_transport", transport_that_reports)
    rc = cli.main(["--ungated", "--task", "x", "--cwd", str(tmp_path), "--model", "local-coder",
                   "--no-rules", "--no-skills"])
    assert rc == 0
    err = capsys.readouterr().err
    assert "served-by:" in err, "alias routing was not reported because the strings matched"
    assert "ml1-5080" in err
