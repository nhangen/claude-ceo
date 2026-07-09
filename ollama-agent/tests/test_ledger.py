import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ollama_agent.ledger import append_run, ledger_path  # noqa: E402


def _rec(**over):
    base = {"run_id": "r1", "ollama_input_tokens": 45, "ollama_output_tokens": 450,
            "turns": 2, "completed": True, "verified": None}
    base.update(over)
    return base


def test_append_run_writes_expected_fields(tmp_path, monkeypatch):
    p = tmp_path / "runs.jsonl"
    monkeypatch.setenv("CLAUDE_SESSION_ID", "sess-xyz")
    out = append_run(_rec(), "mistral-small3.2:24b", "code-fix", "/repo", path=str(p))
    assert out == str(p)
    line = json.loads(p.read_text().strip())
    assert line["model"] == "mistral-small3.2:24b"
    assert line["task_name"] == "code-fix"
    assert line["cwd"] == "/repo"
    assert line["ollama_input_tokens"] == 45
    assert line["ollama_output_tokens"] == 450
    assert line["session_id"] == "sess-xyz"
    assert line["run_id"] == "r1"
    assert line["ts"].endswith("Z")


def test_append_run_is_append_only(tmp_path):
    p = tmp_path / "runs.jsonl"
    append_run(_rec(), "m", "t", "/c", path=str(p))
    append_run(_rec(), "m", "t", "/c", path=str(p))
    assert len(p.read_text().strip().splitlines()) == 2


def test_session_id_none_when_env_absent(tmp_path, monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    p = tmp_path / "runs.jsonl"
    append_run(_rec(), "m", "t", "/c", path=str(p))
    assert json.loads(p.read_text().strip())["session_id"] is None


def test_missing_token_counts_default_zero(tmp_path):
    p = tmp_path / "runs.jsonl"
    append_run({"run_id": "r"}, "m", "t", "/c", path=str(p))  # no token keys
    line = json.loads(p.read_text().strip())
    assert line["ollama_input_tokens"] == 0
    assert line["ollama_output_tokens"] == 0


def test_append_run_failure_returns_none(tmp_path):
    # Parent path is a FILE, so mkdir(parents=True) raises OSError → best-effort
    # returns None, never raises (ledger I/O can't fail a run).
    blocker = tmp_path / "afile"
    blocker.write_text("x")
    out = append_run(_rec(), "m", "t", "/c", path=str(blocker / "nested" / "runs.jsonl"))
    assert out is None


def test_ledger_path_env_override(monkeypatch, tmp_path):
    target = tmp_path / "custom.jsonl"
    monkeypatch.setenv("OLLAMA_AGENT_LEDGER", str(target))
    assert ledger_path() == target


def test_ledger_path_uses_xdg_state(monkeypatch, tmp_path):
    monkeypatch.delenv("OLLAMA_AGENT_LEDGER", raising=False)
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    assert ledger_path() == tmp_path / "ollama-agent" / "runs.jsonl"
