import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent import ToolBox, TOOLS, run_agent  # noqa: E402
from ollama_agent.agent import _normalize_args, _tool_calls_from_content  # noqa: E402
from ollama_agent.tools import _clip, MAX_OUTPUT, MAX_READ  # noqa: E402
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


def test_run_shell_timeout(tmp_path, monkeypatch):
    # Deterministic + instant: stub subprocess.run to raise the timeout rather
    # than sleeping a real wall-clock second, so the test reliably exercises the
    # except branch mapping a timeout to returncode None + a "timeout>Ns" error.
    def raise_timeout(*a, **k):
        raise subprocess.TimeoutExpired(cmd="sleep", timeout=1)
    monkeypatch.setattr(subprocess, "run", raise_timeout)
    tb = ToolBox(cwd=tmp_path, timeout=1)
    out = json.loads(tb.run_shell("sleep 5"))
    assert out["returncode"] is None and out["error"] == "timeout>1s"


def test_clip_under_limit_is_unchanged():
    assert _clip("abc", 10) == "abc"
    assert _clip("x" * 10, 10) == "x" * 10   # exactly at limit, no suffix
    assert _clip("", 10) == ""
    assert _clip(None, 10) == ""


def test_clip_over_limit_truncates_with_count_suffix():
    out = _clip("x" * 50, 10)
    assert out == "x" * 10 + "\n…[truncated 40 chars]"


def test_read_file_truncates_at_max_read(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    tb.write_file("big.txt", "a" * (MAX_READ + 100))
    out = json.loads(tb.read_file("big.txt"))
    assert out["content"] == "a" * MAX_READ + "\n…[truncated 100 chars]"


def test_run_shell_truncates_stdout_at_max_output(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    n = MAX_OUTPUT + 50
    out = json.loads(tb.run_shell(f"python3 -c \"print('a'*{n}, end='')\""))
    assert out["stdout"] == "a" * MAX_OUTPUT + "\n…[truncated 50 chars]"


def test_git_accepts_string_args_via_split(tmp_path):
    # The non-list branch (`str(args).split()`): a model that passes args as a
    # space-joined string instead of a list still drives git correctly.
    tb = ToolBox(cwd=tmp_path, timeout=10)
    tb.git(["init"])
    out = json.loads(tb.git("rev-parse --is-inside-work-tree"))
    assert out["returncode"] == 0 and out["stdout"].strip() == "true"


def test_resolve_absolute_path_escapes_cwd_no_jail(tmp_path):
    # Characterizes the INTENTIONAL absence of a path jail (the #190 governance
    # boundary): _resolve passes an absolute path through unchanged, so a write
    # can land outside cwd. If a jail is ever added, this test must be changed
    # deliberately — it is the explicit record that escape is currently allowed.
    cwd = tmp_path / "work"; cwd.mkdir()
    outside = tmp_path / "outside"; outside.mkdir()
    target = outside / "escaped.txt"
    tb = ToolBox(cwd=cwd)
    wr = json.loads(tb.write_file(str(target), "I escaped cwd"))
    assert wr["path"] == str(target)
    assert target.read_text() == "I escaped cwd"          # wrote outside cwd
    rd = json.loads(tb.read_file(str(target)))
    assert rd["content"] == "I escaped cwd"               # and read it back


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


# --- content-embedded tool-call recovery (qwen-class models) ---

def test_content_fallback_parses_plain_json_object():
    # The exact shape observed from qwen2.5-coder:14b: a {"name","arguments"}
    # object serialized into content, native tool_calls empty.
    calls = _tool_calls_from_content('{"name": "run_shell", "arguments": {"command": "echo hi"}}')
    assert calls == [{"function": {"name": "run_shell", "arguments": {"command": "echo hi"}}}]


def test_content_fallback_parses_fenced_json():
    content = '```json\n{"name": "run_shell", "arguments": {"command": "echo hi"}}\n```'
    calls = _tool_calls_from_content(content)
    assert calls == [{"function": {"name": "run_shell", "arguments": {"command": "echo hi"}}}]


def test_content_fallback_ignores_prose_and_non_call_json():
    assert _tool_calls_from_content("I'll use the write_file tool to do this.") == []   # glm-style prose
    assert _tool_calls_from_content('{"result": 42}') == []                              # JSON, but not a call
    assert _tool_calls_from_content('{"name": "x"}') == []                               # name but no arguments
    assert _tool_calls_from_content(None) == []
    assert _tool_calls_from_content("") == []


def test_loop_recovers_tool_call_embedded_in_content(tmp_path):
    # qwen emits a correct call as JSON in content with an empty native
    # tool_calls field; the loop must recover and dispatch it (the agent.py:41
    # drop site). Drives the real run_agent + real ToolBox so the file write
    # proves the recovered call actually executed.
    transport = _script(
        {"role": "assistant",
         "content": json.dumps({"name": "write_file", "arguments": {"path": "f.txt", "content": "hi"}})},
        {"role": "assistant", "content": "done"},
    )
    rec = run_agent("write a file", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, turn_cap=8)
    assert rec["completed"] is True
    assert rec["turns"] == 2
    assert (tmp_path / "f.txt").read_text() == "hi"
    assert rec["unknown_calls"] == []


def test_loop_prose_content_still_completes_without_recovery(tmp_path):
    # A text-only model (glm) whose content is prose must still complete as a
    # normal no-tool-call turn — the fallback recovers nothing and does not crash.
    transport = _script({"role": "assistant", "content": "Here is my answer in prose."})
    rec = run_agent("answer", "sys", transport, ToolBox(cwd=tmp_path), TOOLS)
    assert rec["completed"] is True
    assert rec["turns"] == 1
    assert rec["calls"] == []


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
