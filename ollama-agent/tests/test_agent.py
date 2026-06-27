import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent import ToolBox, TOOLS, run_agent  # noqa: E402
from ollama_agent.agent import _normalize_args  # noqa: E402
from ollama_agent.transport import parse_chat_response  # noqa: E402


# --- real tools ---

def test_run_shell_captures_returncode_and_stdout(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    out = json.loads(tb.run_shell("echo hello"))
    assert out["returncode"] == 0
    assert "hello" in out["stdout"]


def test_run_shell_nonzero_returncode_surfaced(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    out = json.loads(tb.run_shell("exit 3"))
    assert out["returncode"] == 3


def test_run_shell_timeout(tmp_path):
    tb = ToolBox(cwd=tmp_path, timeout=1)
    out = json.loads(tb.run_shell("sleep 5"))
    assert out["returncode"] is None and "timeout" in out["error"]


def test_write_then_read_file_roundtrip(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    tb.write_file("sub/a.txt", "content here")
    out = json.loads(tb.read_file("sub/a.txt"))
    assert out["content"] == "content here"


def test_read_missing_file_is_error_not_crash(tmp_path):
    out = json.loads(ToolBox(cwd=tmp_path).read_file("nope.txt"))
    assert "error" in out


def test_list_dir(tmp_path):
    (tmp_path / "x.txt").write_text("")
    (tmp_path / "d").mkdir()
    out = json.loads(ToolBox(cwd=tmp_path).list_dir("."))
    assert "x.txt" in out["entries"] and "d/" in out["entries"]


def test_git_runs_in_cwd(tmp_path):
    subprocess.run(["git", "init"], cwd=tmp_path, capture_output=True)
    out = json.loads(ToolBox(cwd=tmp_path).git(["status", "--short"]))
    assert out["returncode"] == 0


# --- dispatch ---

def test_dispatch_records_every_call(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    tb.dispatch("list_dir", {"path": "."})
    assert tb.calls == [("list_dir", {"path": "."})]


def test_dispatch_unknown_tool_recorded_and_errors(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    res = json.loads(tb.dispatch("hallucinated", {}))
    assert "error" in res and tb.unknown_calls == ["hallucinated"]


# --- arg normalization ---

@pytest.mark.parametrize("raw,expected", [
    ({"a": 1}, {"a": 1}),
    ('{"a": 1}', {"a": 1}),
    ("not json", {}),
    (None, {}),
    ("[1,2]", {}),
])
def test_normalize_args(raw, expected):
    assert _normalize_args(raw) == expected


# --- loop ---

def _script(*responses):
    seq = iter(responses)
    last = responses[-1]
    def transport(messages, tools):
        return next(seq, last)
    return transport


def test_loop_dispatches_tools_then_finishes(tmp_path):
    transport = _script(
        {"role": "assistant", "tool_calls": [
            {"function": {"name": "write_file", "arguments": {"path": "f.txt", "content": "hi"}}}]},
        {"role": "assistant", "content": "done"},
    )
    rec = run_agent("write a file", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, turn_cap=8)
    assert rec["completed"] is True
    assert rec["turns"] == 2
    assert (tmp_path / "f.txt").read_text() == "hi"
    assert rec["unknown_calls"] == []


def test_run_id_echoed_in_record(tmp_path):
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, run_id="run-abc")
    assert rec["run_id"] == "run-abc"


def test_run_id_defaults_none(tmp_path):
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS)
    assert rec["run_id"] is None


def test_loop_respects_turn_cap(tmp_path):
    # Transport always asks for another tool call; a broken cap fails on the
    # turns assertion (not by running out of scripted responses).
    transport = _script({"role": "assistant", "tool_calls": [
        {"function": {"name": "list_dir", "arguments": {"path": "."}}}]})
    rec = run_agent("loop forever", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, turn_cap=4)
    assert rec["completed"] is False
    assert rec["turns"] == 4


def test_loop_records_unknown_tool(tmp_path):
    transport = _script(
        {"role": "assistant", "tool_calls": [
            {"function": {"name": "make_coffee", "arguments": {}}}]},
        {"role": "assistant", "content": "cannot"},
    )
    rec = run_agent("brew", "sys", transport, ToolBox(cwd=tmp_path), TOOLS)
    assert rec["unknown_calls"] == ["make_coffee"]


def test_loop_survives_malformed_tool_call_envelope(tmp_path):
    # A tool_call missing function/name must not crash the loop — it records as
    # an unknown call and feeds an error back to the model.
    transport = _script(
        {"role": "assistant", "tool_calls": [{"id": "1"}]},
        {"role": "assistant", "content": "recovered"},
    )
    rec = run_agent("oops", "sys", transport, ToolBox(cwd=tmp_path), TOOLS)
    assert rec["completed"] is True
    assert rec["unknown_calls"] == [None]
    assert "malformed" in rec["transcript"][3]["content"]


def test_loop_survives_tool_handler_exception(tmp_path):
    # write_file into a read-only dir raises PermissionError inside dispatch; the
    # loop must keep running with a recorded error, not abort the run.
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)
    transport = _script(
        {"role": "assistant", "tool_calls": [
            {"function": {"name": "write_file", "arguments": {"path": "ro/x.txt", "content": "hi"}}}]},
        {"role": "assistant", "content": "noted the failure"},
    )
    try:
        rec = run_agent("write", "sys", transport, ToolBox(cwd=tmp_path), TOOLS)
    finally:
        ro.chmod(0o700)
    assert rec["completed"] is True
    err = json.loads(rec["transcript"][3]["content"])
    assert "error" in err and "write_file failed" in err["error"]


def test_write_file_reports_byte_length_not_char_count(tmp_path):
    out = json.loads(ToolBox(cwd=tmp_path).write_file("m.txt", "héllo"))
    assert out["bytes"] == 6  # 5 chars, 6 UTF-8 bytes


# --- transport error branches (the headline non-throwing-client claim) ---

class _FakeResp:
    def __init__(self, status, body):
        self.status, self._body = status, body
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False
    def read(self):
        return self._body.encode()


def test_transport_success(monkeypatch):
    import ollama_agent.transport as t
    monkeypatch.setattr(t.urllib.request, "urlopen",
                        lambda req, timeout: _FakeResp(200, json.dumps({"message": {"role": "assistant", "content": "ok"}})))
    msg = t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert msg["content"] == "ok"


def test_transport_httperror_routes_through_success_parser(monkeypatch):
    import io
    import ollama_agent.transport as t

    def boom(req, timeout):
        raise t.urllib.error.HTTPError("u", 500, "err", {}, io.BytesIO(b'{"error":"server"}'))
    monkeypatch.setattr(t.urllib.request, "urlopen", boom)
    with pytest.raises(RuntimeError, match="HTTP 500"):
        t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])


def test_transport_urlerror_raises_unreachable(monkeypatch):
    import ollama_agent.transport as t

    def boom(req, timeout):
        raise t.urllib.error.URLError("connection refused")
    monkeypatch.setattr(t.urllib.request, "urlopen", boom)
    with pytest.raises(RuntimeError, match="unreachable"):
        t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])


# --- transport success check ---

def test_parse_chat_response_ok():
    assert parse_chat_response(200, json.dumps({"message": {"role": "assistant", "content": "hi"}})) \
        == {"role": "assistant", "content": "hi"}


def test_parse_chat_response_non_200_raises():
    with pytest.raises(RuntimeError, match="HTTP 500"):
        parse_chat_response(500, "boom")


def test_parse_chat_response_error_body_raises():
    with pytest.raises(RuntimeError, match="ollama error"):
        parse_chat_response(200, json.dumps({"error": "model not found"}))


def test_parse_chat_response_missing_message_raises():
    with pytest.raises(RuntimeError, match="no message"):
        parse_chat_response(200, json.dumps({"done": True}))
