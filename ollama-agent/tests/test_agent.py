import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent import ToolBox, TOOLS, run_agent  # noqa: E402
from ollama_agent.agent import _normalize_args, _tool_calls_from_content  # noqa: E402
from ollama_agent.tools import _clip, MAX_OUTPUT, MAX_READ  # noqa: E402
from ollama_agent.transport import ollama_transport, parse_chat_response  # noqa: E402


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


def test_edit_file_in_toolbox(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    tb.write_file("file.txt", "line 1\nline 2\n")
    out = json.loads(tb.edit_file("file.txt", "line 2", "line two"))
    assert "error" not in out
    read = json.loads(tb.read_file("file.txt"))
    assert read["content"] == "line 1\nline two\n"


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
    """Build a transport from scripted responses. Each response is either a plain
    assistant-message dict (paired with zero usage) or a (message, usage) tuple to
    exercise token accounting. Transport returns (message, usage), matching the
    real contract."""
    seq = iter(responses)
    last = responses[-1]
    def transport(messages, tools):
        r = next(seq, last)
        if isinstance(r, tuple):
            return r
        return r, {"input": 0, "output": 0}
    return transport


def test_records_ollama_token_usage_across_turns(tmp_path):
    # Ground-truth local-model spend: eval_count/prompt_eval_count summed over
    # every turn of the run (this is the data the savings estimate reads).
    transport = _script(
        ({"role": "assistant", "tool_calls": [
            {"function": {"name": "write_file", "arguments": {"path": "f.txt", "content": "hi"}}}]},
         {"input": 30, "output": 300}),
        ({"role": "assistant", "content": "done"}, {"input": 15, "output": 150}),
    )
    rec = run_agent("write", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, turn_cap=8)
    assert rec["ollama_input_tokens"] == 45
    assert rec["ollama_output_tokens"] == 450


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


def test_verify_cmd_none_is_prior_behavior(tmp_path):
    # No verify gate: the model stopping (no tool calls) completes immediately,
    # and `verified` is None (feature not engaged).
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, verify_cmd=None)
    assert rec["completed"] is True
    assert rec["turns"] == 1
    assert rec["verified"] is None
    assert rec["verify_cmd"] is None


def test_verify_cmd_passing_accepts_the_stop(tmp_path):
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, verify_cmd="true")
    assert rec["completed"] is True
    assert rec["verified"] is True
    assert rec["verify_cmd"] == "true"
    assert rec["turns"] == 1


def test_verify_cmd_keeps_going_until_green(tmp_path):
    # The model tries to stop every turn, but the verify command fails the first
    # time and passes the second. The loop must NOT accept the first stop — it
    # re-prompts and only completes once verification is green.
    counter = tmp_path / "cnt"
    verify = f"n=$(cat {counter} 2>/dev/null || echo 0); n=$((n+1)); echo $n > {counter}; [ $n -ge 2 ]"
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("fix it", "sys", transport, ToolBox(cwd=tmp_path), TOOLS,
                    turn_cap=8, verify_cmd=verify)
    assert rec["completed"] is True
    assert rec["verified"] is True
    assert rec["verify_cmd"] == verify
    assert rec["turns"] == 2


def test_verify_cmd_never_green_ends_unverified_at_cap(tmp_path):
    # Verify never passes: the run exhausts the cap and reports verified False,
    # completed False — a caller must see it did NOT reach green.
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("fix it", "sys", transport, ToolBox(cwd=tmp_path), TOOLS,
                    turn_cap=3, verify_cmd="false")
    assert rec["verified"] is False
    assert rec["completed"] is False
    assert rec["verify_cmd"] == "false"
    assert rec["turns"] == 3


def _refuses_to_run(messages, tools):
    """A transport that fails the test if it is called at all, so an arm can assert
    a guard fired at entry rather than merely somewhere. Without it the same guard
    moved to the function's exit keeps these arms green, after the turn loop has
    run and the tracker is dirty — which is the state #436 exists to prevent.
    test_cli.py's sibling arms already pin this via `"system" not in captured`."""
    raise AssertionError("transport called: the verify_cmd guard did not run at entry")


def test_verify_cmd_empty_string_refused_before_any_turn(tmp_path):
    # #436: Empty string is not a valid gate and must not silently run ungated.
    tracker = {}
    with pytest.raises(ValueError, match="pass None to run without a gate"):
        run_agent("fix it", "sys", _refuses_to_run, ToolBox(cwd=tmp_path), TOOLS,
                  verify_cmd="", usage_tracker=tracker)
    assert tracker == {}


def test_verify_cmd_whitespace_string_refused_before_any_turn(tmp_path):
    # #436: Whitespace-only string must not pass as truthy gate and forge green status.
    tracker = {}
    with pytest.raises(ValueError, match="pass None to run without a gate"):
        run_agent("fix it", "sys", _refuses_to_run, ToolBox(cwd=tmp_path), TOOLS,
                  verify_cmd="   \t\n  ", usage_tracker=tracker)
    assert tracker == {}


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
    # `headers` is here because a real http.client.HTTPResponse always has it.
    # Without it the fake diverged from production and the provenance capture
    # (#667) crashed against the stub while working against the daemon -- the
    # test-reproduces-production-conditions failure, in the fixture rather than
    # the code.
    def __init__(self, status, body, headers=None):
        self.status, self._body = status, body
        self.headers = headers or {}
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False
    def read(self):
        if isinstance(self._body, bytes):
            return self._body
        return self._body.encode()


def test_transport_success(monkeypatch):
    import ollama_agent.transport as t
    monkeypatch.setattr(t.urllib.request, "urlopen",
                        lambda req, timeout: _FakeResp(200, json.dumps({
                            "message": {"role": "assistant", "content": "ok"},
                            "prompt_eval_count": 7, "eval_count": 11})))
    msg, usage = t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert msg["content"] == "ok"
    assert usage == {"input": 7, "output": 11}


def _captured_payload(monkeypatch, **kwargs):
    """Return the JSON body ollama_transport would POST, plus the timeout it passed."""
    import ollama_agent.transport as t
    seen = {}

    def fake_urlopen(req, timeout):
        seen["body"] = json.loads(req.data.decode())
        seen["timeout"] = timeout
        return _FakeResp(200, json.dumps({"message": {"role": "assistant", "content": "ok"},
                                          "prompt_eval_count": 1, "eval_count": 1}))

    monkeypatch.setattr(t.urllib.request, "urlopen", fake_urlopen)
    t.ollama_transport("m", **kwargs)([{"role": "user", "content": "hi"}], [])
    return seen


def test_transport_omits_think_by_default(monkeypatch):
    # The default has to stay byte-identical to what shipped before the parameter existed:
    # an older daemon should not be handed a field it does not know, and "think": null is
    # not the same request as no "think" key at all.
    seen = _captured_payload(monkeypatch)
    assert "think" not in seen["body"]
    assert seen["timeout"] == 600


def test_transport_sends_think_false_when_asked(monkeypatch):
    # A thinking model can spend a whole turn reasoning and never answer. Measured on
    # qwen3.8:27b over a 1,464-token diff: no answer inside 600s with thinking on, 62s
    # with it off. The flag is the only thing that reaches the daemon — a "/no_think"
    # prompt prefix was measured doing nothing at all.
    seen = _captured_payload(monkeypatch, think=False)
    assert seen["body"]["think"] is False


def test_transport_timeout_is_caller_settable(monkeypatch):
    seen = _captured_payload(monkeypatch, timeout=42)
    assert seen["timeout"] == 42


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


@pytest.mark.parametrize("status", [429, 502, 503, 504])
def test_transport_retries_transient_http_once_without_changing_request(
        monkeypatch, status):
    import io
    import ollama_agent.transport as t

    requests = []
    errors = []

    def respond(req, timeout):
        requests.append((req.full_url, dict(req.headers), timeout, req.data))
        if len(requests) == 1:
            error = t.urllib.error.HTTPError(
                "u", status, "upstream failure", {},
                io.BytesIO(b"upstream failed"))
            errors.append(error)
            raise error
        return _FakeResp(200, json.dumps({
            "message": {"role": "assistant", "content": "ok"},
            "prompt_eval_count": 7,
            "eval_count": 11,
        }))

    monkeypatch.setattr(t.urllib.request, "urlopen", respond)
    monkeypatch.setattr(t.time, "sleep", lambda *a: None)

    msg, usage = t.ollama_transport("local-coder")(
        [{"role": "user", "content": "hi"}], [])

    assert msg["content"] == "ok"
    assert usage == {"input": 7, "output": 11}
    assert len(requests) == 2
    assert requests[0] == requests[1]
    assert errors[0].closed


def test_transport_honors_retry_after_header(monkeypatch):
    import io
    import ollama_agent.transport as t

    sleeps = []
    calls = {"n": 0}

    def respond(req, timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            raise t.urllib.error.HTTPError(
                "u", 429, "rate limited", {"Retry-After": "1.5"},
                io.BytesIO(b"rate limited"))
        return _FakeResp(200, json.dumps({
            "message": {"role": "assistant", "content": "ok"},
            "prompt_eval_count": 1,
            "eval_count": 1,
        }))

    monkeypatch.setattr(t.urllib.request, "urlopen", respond)
    monkeypatch.setattr(t.time, "sleep", lambda s: sleeps.append(s))

    t.ollama_transport("local-coder")([{"role": "user", "content": "hi"}], [])

    assert calls["n"] == 2
    assert sleeps == [1.5]


def test_transport_stops_after_bounded_502_retries(monkeypatch, capsys):
    import io
    import ollama_agent.transport as t

    errors = []

    def fail(req, timeout):
        error = t.urllib.error.HTTPError(
            "u", 502, "bad gateway", {}, io.BytesIO(b"no healthy backends"))
        errors.append(error)
        raise error

    monkeypatch.setattr(t.urllib.request, "urlopen", fail)
    monkeypatch.setattr(t.time, "sleep", lambda *a: None)

    with pytest.raises(
            RuntimeError,
            match=r"HTTP 502 after 3 attempts for model local-coder: no healthy backends") as exc:
        t.ollama_transport("local-coder", host="router:40114")(
            [{"role": "user", "content": "hi"}], [])

    assert len(errors) == 3
    assert all(error.closed for error in errors)
    assert "no healthy backends" in str(exc.value)
    err = capsys.readouterr().err
    assert err.count("warning: ollama HTTP 502") == 2
    assert "attempt 1/3" in err
    assert "attempt 2/3" in err
    assert "attempt 3/3" not in err


@pytest.mark.parametrize("status", [400, 500])
def test_transport_does_not_retry_other_http_errors(monkeypatch, capsys, status):
    import io
    import ollama_agent.transport as t

    errors = []

    def fail(req, timeout):
        error = t.urllib.error.HTTPError(
            "u", status, "request failed", {},
            io.BytesIO(b'{"error":"request failed"}'))
        errors.append(error)
        raise error

    monkeypatch.setattr(t.urllib.request, "urlopen", fail)
    monkeypatch.setattr(t.time, "sleep", lambda *a: pytest.fail("a non-retryable status backed off"))

    with pytest.raises(RuntimeError, match=f"HTTP {status}"):
        t.ollama_transport("local-coder")(
            [{"role": "user", "content": "hi"}], [])

    assert len(errors) == 1
    assert errors[0].closed
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("make_exc", [
    lambda: __import__("http.client").client.RemoteDisconnected("closed without response"),
    lambda: ConnectionAbortedError("aborted"),
    lambda: BrokenPipeError("broken pipe"),
    lambda: __import__("http.client").client.IncompleteRead(b"partial"),
], ids=["RemoteDisconnected", "ConnectionAbortedError", "BrokenPipeError", "IncompleteRead"])
def test_transport_retries_a_dropped_connection_then_succeeds(monkeypatch, capsys, make_exc):
    # Raised from urlopen, not from read(): with "stream": False the daemon sends
    # no headers until generation ends, so a dropped connection surfaces inside
    # getresponse(). A test that only fails read() would pass a transport that
    # narrowed its try to the read and missed the real case. One case per member
    # of RETRYABLE_READ_ERRORS: a member dropped from the tuple falls through to
    # the config arm and stops retrying, silently.
    import ollama_agent.transport as t

    calls = {"n": 0}
    first = make_exc()
    name = type(first).__name__

    def flaky(req, timeout):
        calls["n"] += 1
        if calls["n"] == 1:
            raise first
        return _FakeResp(200, json.dumps({
            "message": {"role": "assistant", "content": "ok"},
            "prompt_eval_count": 7, "eval_count": 11}))

    sleeps = []
    monkeypatch.setattr(t.urllib.request, "urlopen", flaky)
    monkeypatch.setattr(t.time, "sleep", sleeps.append)

    prov = {}
    msg, usage = t.ollama_transport("local-coder", host="localhost:11434", provenance=prov)(
        [{"role": "user", "content": "hi"}], [])

    assert msg["content"] == "ok"
    assert usage == {"input": 7, "output": 11}
    assert calls["n"] == 2
    assert prov["retried_statuses"] == [f"{name}@1"]
    assert sleeps == [0.2]
    # The same wording as the HTTP retry arm (#411): one retry, one log format.
    assert (f"warning: ollama {name} on attempt 1/3 for model local-coder, "
            "retrying in 0.2s") in capsys.readouterr().err


def test_transport_read_error_stops_after_bounded_retries(monkeypatch, capsys):
    import ollama_agent.transport as t

    class _ResetReadResp(_FakeResp):
        def read(self):
            raise ConnectionResetError("[Errno 104] Connection reset by peer")

    sleeps = []
    monkeypatch.setattr(t.urllib.request, "urlopen", lambda req, timeout: _ResetReadResp(200, ""))
    monkeypatch.setattr(t.time, "sleep", sleeps.append)

    prov = {}
    with pytest.raises(
        RuntimeError,
        match=r"ollama ConnectionResetError after 3 attempts for model local-coder "
              r"at http://router:40114/api/chat:.*reset",
    ) as exc:
        t.ollama_transport("local-coder", host="router:40114", provenance=prov)(
            [{"role": "user", "content": "hi"}], [])

    assert prov["retried_statuses"] == ["ConnectionResetError@1", "ConnectionResetError@2"]
    assert sleeps == [0.2, 0.4]
    assert isinstance(exc.value.__cause__, ConnectionResetError)
    err = capsys.readouterr().err
    assert "attempt 1/3" in err and "attempt 2/3" in err
    assert "attempt 3/3" not in err


def test_transport_incomplete_read_retries_then_raises(monkeypatch):
    import http.client
    import ollama_agent.transport as t

    class _IncompleteReadResp(_FakeResp):
        def read(self):
            raise http.client.IncompleteRead(b"partial payload")

    monkeypatch.setattr(t.urllib.request, "urlopen",
                        lambda req, timeout: _IncompleteReadResp(200, ""))
    monkeypatch.setattr(t.time, "sleep", lambda *a: None)

    prov = {}
    with pytest.raises(
        RuntimeError,
        match=r"ollama IncompleteRead after 3 attempts for model local-coder "
              r"at http://router:40114/api/chat:.*IncompleteRead\(15 bytes read\)",
    ):
        t.ollama_transport("local-coder", host="router:40114", provenance=prov)(
            [{"role": "user", "content": "hi"}], [])

    assert prov["retried_statuses"] == ["IncompleteRead@1", "IncompleteRead@2"]


# socket.timeout is its own OSError subclass on 3.9 and an alias of TimeoutError
# from 3.10, so both are pinned: the host python here is 3.9, CI's may not be.
@pytest.mark.parametrize("exc_type", ["socket_timeout", "TimeoutError"])
def test_transport_timeout_is_not_retried(monkeypatch, exc_type):
    # With "stream": False a timeout fires before any header arrives, and in the
    # documented case (a thinking model on a long turn, see cli.py) it recurs on
    # every attempt. Retrying turned one 600s failure into ~1800s and two extra
    # full generations, then reported it as a network blip.
    import socket
    import ollama_agent.transport as t

    calls = []

    def hang(req, timeout):
        calls.append(timeout)
        raise socket.timeout("timed out") if exc_type == "socket_timeout" else TimeoutError("timed out")

    monkeypatch.setattr(t.urllib.request, "urlopen", hang)
    monkeypatch.setattr(t.time, "sleep", lambda *a: pytest.fail("a timeout must not back off"))

    prov = {}
    with pytest.raises(RuntimeError, match=r"timed out after 600s") as exc:
        t.ollama_transport("local-coder", provenance=prov)([{"role": "user", "content": "hi"}], [])

    assert len(calls) == 1
    assert "retried_statuses" not in prov
    assert "--no-think" in str(exc.value) and "--timeout" in str(exc.value)
    assert isinstance(exc.value.__cause__, OSError)


def test_transport_config_error_is_not_retried(monkeypatch):
    # A bad port can never succeed; retrying it filed a typo in --host under
    # retried_statuses beside real 503 flaps.
    import http.client
    import ollama_agent.transport as t

    calls = []

    def bad(req, timeout):
        calls.append(1)
        raise http.client.InvalidURL("nonnumeric port: 'abc'")

    monkeypatch.setattr(t.urllib.request, "urlopen", bad)
    monkeypatch.setattr(t.time, "sleep", lambda *a: pytest.fail("a config error must not back off"))

    prov = {}
    with pytest.raises(RuntimeError, match=r"ollama InvalidURL at .* for model local-coder") as exc:
        t.ollama_transport("local-coder", provenance=prov)([{"role": "user", "content": "hi"}], [])

    assert calls == [1]
    assert "retried_statuses" not in prov
    assert isinstance(exc.value.__cause__, http.client.InvalidURL)


# Both halves of the catch: a reset is an OSError, a short body is an
# HTTPException (IncompleteRead) -- which of the two a dropped body raises
# depends on the Python version.
@pytest.mark.parametrize("make_exc", [
    lambda: ConnectionResetError("[Errno 54] Connection reset by peer"),
    lambda: __import__("http.client").client.IncompleteRead(b"par"),
], ids=["ConnectionResetError", "IncompleteRead"])
def test_transport_unreadable_http_error_body_is_translated(monkeypatch, make_exc):
    # e.read() runs inside the HTTPError handler, where the sibling except
    # clauses cannot reach it, so a reset mid-body escaped raw with no url or
    # model: the "read-path failures escape untranslated" gap #440 is named for.
    import io
    import ollama_agent.transport as t

    err = make_exc()

    class _DroppedBody(io.BytesIO):
        def read(self, *a):
            raise err

    def fail(req, timeout):
        raise t.urllib.error.HTTPError("u", 500, "server error", {}, _DroppedBody(b""))

    monkeypatch.setattr(t.urllib.request, "urlopen", fail)

    with pytest.raises(RuntimeError, match=r"ollama HTTP 500 for model local-coder; "
                                           r"error body unreadable") as exc:
        t.ollama_transport("local-coder")([{"role": "user", "content": "hi"}], [])

    assert exc.value.__cause__ is err


# --- transport success check ---

def test_parse_chat_response_ok():
    msg, usage = parse_chat_response(200, json.dumps({
        "message": {"role": "assistant", "content": "hi"},
        "prompt_eval_count": 12, "eval_count": 34}))
    assert msg == {"role": "assistant", "content": "hi"}
    assert usage == {"input": 12, "output": 34}


def test_parse_chat_response_usage_defaults_zero_when_absent():
    # Older ollama builds / interrupted streams may omit the counts — default to
    # 0 (numeric), never None, so downstream sums don't break.
    msg, usage = parse_chat_response(200, json.dumps({
        "message": {"role": "assistant", "content": "hi"}}))
    assert usage == {"input": 0, "output": 0}


def test_parse_chat_response_non_200_raises():
    with pytest.raises(RuntimeError, match="HTTP 500"):
        parse_chat_response(500, "boom")


def test_parse_chat_response_error_body_raises():
    with pytest.raises(RuntimeError, match="ollama error"):
        parse_chat_response(200, json.dumps({"error": "model not found"}))


def test_parse_chat_response_missing_message_raises():
    with pytest.raises(RuntimeError, match="no message"):
        parse_chat_response(200, json.dumps({"done": True}))


def test_parse_chat_response_context_overflow_500_diagnostic():
    body = json.dumps({"error": "no user query found in messages"})
    with pytest.raises(RuntimeError, match="prompt exceeded context window.*--num-ctx"):
        parse_chat_response(500, body)


def test_parse_chat_response_context_overflow_200_diagnostic():
    # Reaches the parsed-error branch, not the non-200 one: ollama returns the
    # overflow either way. Reverting that branch to the plain "ollama error" raise
    # fails this test — it did not before, because a pre-status raw-body check
    # matched first and this arm never reached json.loads.
    body = json.dumps({"error": "no user query found in messages"})
    with pytest.raises(RuntimeError, match="prompt exceeded context window.*--num-ctx"):
        parse_chat_response(200, body)


def test_parse_chat_response_healthy_200_quoting_the_sentinel_returns():
    # The sentinel is ollama's error wording, and it is also ordinary text a model
    # can emit — the phrase lives in this repo, which ollama-agent codes against, so
    # a run asked to fix transport.py will quote it. Matching it on the raw body
    # before the status check turned that healthy turn into a fatal run.
    body = json.dumps({
        "message": {"role": "assistant",
                    "content": "the guard is: no user query found in messages"},
        "prompt_eval_count": 10, "eval_count": 5})
    msg, usage = parse_chat_response(200, body)
    assert msg["content"] == "the guard is: no user query found in messages"
    assert usage == {"input": 10, "output": 5}


def test_parse_chat_response_unparseable_json_raises_runtimeerror():
    # #385: a 200 carrying non-JSON (a proxy's HTML error page) surfaced as a bare
    # ValueError naming neither ollama nor the body. cli.py:334 is `except
    # Exception` and already ledgered it, so what this buys is a diagnostic
    # message -- NOT, as the ticket claimed, reaching the ledger at all. Do not
    # read it as licence to narrow that catch back to RuntimeError.
    with pytest.raises(RuntimeError, match="ollama 200 with unparseable body: <html>"):
        parse_chat_response(200, "<html>502 Bad Gateway</html>")


@pytest.mark.parametrize("body,kind", [("[]", "list"), ("null", "NoneType"),
                                       ('"s"', "str"), ("123", "int")])
def test_parse_chat_response_non_object_body_raises_runtimeerror(body, kind):
    # The other half of #385's class: this parses, then dies on `.get` as an
    # AttributeError. One arm per JSON type because a guard keyed on any one of
    # them (a truthiness test, say) passes the others through.
    with pytest.raises(RuntimeError, match=f"non-object body \\({kind}\\)"):
        parse_chat_response(200, body)


def test_parse_chat_response_non_numeric_token_counts_raise_runtimeerror():
    # int("abc") is a ValueError, and the invariant is that nothing leaves this
    # function as anything but RuntimeError.
    body = json.dumps({"message": {"role": "assistant", "content": "hi"},
                       "prompt_eval_count": "abc"})
    with pytest.raises(RuntimeError, match="non-numeric token counts"):
        parse_chat_response(200, body)


# --- why the run ended (reason) ---
#
# The ledger's outcome was a two-field truth table with a null in it:
# (completed, verified). Across 57 real rows the shapes are (True, None) x28,
# (True, True) x17, (False, False) x7, (False, None) x5 — so reading "did this
# work" means joining two nullable fields and knowing that None means "no gate
# configured", not "unknown". `reason` says it in one field.
#
# Only the three values the loop can actually reach are emitted. A RuntimeError
# returns from cli before the ledger write, and an OOM kill takes the process
# with it, so "error"/"killed" would be values nothing ever writes.

def test_reason_ok_when_model_stops_ungated(tmp_path):
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, verify_cmd=None)
    assert rec["reason"] == "ok"


def test_reason_ok_when_the_gate_passes(tmp_path):
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("noop", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, verify_cmd="true")
    assert rec["reason"] == "ok"


def test_reason_turn_cap_when_ungated_run_exhausts_the_cap(tmp_path):
    # The 5 real (False, None) rows: the model never stopped and no gate was
    # configured, so nothing failed — it just ran out of turns.
    transport = _script({"role": "assistant", "tool_calls": [
        {"function": {"name": "list_dir", "arguments": {"path": "."}}}]})
    rec = run_agent("loop forever", "sys", transport, ToolBox(cwd=tmp_path), TOOLS, turn_cap=4)
    assert rec["completed"] is False
    assert rec["reason"] == "turn-cap"


def test_reason_verify_failed_when_the_gate_is_still_red_at_the_cap(tmp_path):
    # The 7 real (False, False) rows, all at turns == cap. Distinct from the
    # case above: work was attempted and the gate rejected it every time.
    transport = _script({"role": "assistant", "content": "done"})
    rec = run_agent("fix it", "sys", transport, ToolBox(cwd=tmp_path), TOOLS,
                    turn_cap=3, verify_cmd="false")
    assert rec["completed"] is False
    assert rec["reason"] == "verify-failed"


def test_run_agent_updates_usage_tracker_across_turns(tmp_path):
    tracker = {}
    transport = _script(
        ({"role": "assistant", "tool_calls": [{"function": {"name": "list_dir", "arguments": {"path": "."}}}]},
         {"input": 15, "output": 25}),
        ({"role": "assistant", "content": "done"},
         {"input": 30, "output": 40}),
    )
    rec = run_agent("task", "sys", transport, ToolBox(cwd=tmp_path), TOOLS,
                    turn_cap=5, usage_tracker=tracker)
    assert rec["completed"] is True
    assert tracker["ollama_input_tokens"] == 45
    assert tracker["ollama_output_tokens"] == 65
    assert tracker["turns"] == 2


def test_run_agent_returns_verify_gated_from_the_verify_cmd(tmp_path):
    # The return key and the tracker reset are separate promises that happened to
    # share one test. This one owns the return contract: whatever else changes
    # about tracker reuse, run_agent's record still says whether a gate was
    # configured.
    with_gate = _script(({"role": "assistant", "content": "done"}, {"input": 1, "output": 1}))
    rec = run_agent("task", "sys", with_gate, ToolBox(cwd=tmp_path), TOOLS,
                    turn_cap=1, verify_cmd="true")
    assert rec["verify_gated"] is True

    without = _script(({"role": "assistant", "content": "done"}, {"input": 1, "output": 1}))
    rec = run_agent("task", "sys", without, ToolBox(cwd=tmp_path), TOOLS, turn_cap=1)
    assert rec["verify_gated"] is False


def test_run_agent_resets_a_reused_usage_tracker_on_entry(tmp_path):
    # The docstring promises a reused tracker does not double-count and that a
    # stale `verified` cannot leak forward. Without the entry reset both are false
    # and nothing else in the suite notices.
    tracker = {}
    first = _script(({"role": "assistant", "content": "done"}, {"input": 10, "output": 20}))
    rec1 = run_agent("task", "sys", first, ToolBox(cwd=tmp_path), TOOLS,
                     turn_cap=1, verify_cmd="false", usage_tracker=tracker)
    assert tracker["verified"] is False
    assert tracker["verify_gated"] is True
    assert tracker["verify_cmd"] == "false"
    assert rec1["verify_gated"] is True
    assert rec1["verify_cmd"] == "false"
    assert tracker["ollama_input_tokens"] == 10

    second = _script(({"role": "assistant", "content": "done"}, {"input": 3, "output": 4}))
    rec2 = run_agent("task", "sys", second, ToolBox(cwd=tmp_path), TOOLS,
                     turn_cap=1, usage_tracker=tracker)
    assert tracker["verified"] is None
    assert tracker["verify_gated"] is False
    assert tracker["verify_cmd"] is None
    assert rec2["verify_gated"] is False
    assert rec2["verify_cmd"] is None
    assert tracker["ollama_input_tokens"] == 3
    assert tracker["turns"] == 1


# --- #384: context overflow detected from the token count, not a daemon string ---

def _usage_transport(input_counts):
    """A transport returning a fixed prompt_eval_count per turn, then stopping.

    The last turn makes no tool call, which is how run_agent ends a run.
    """
    seq = list(input_counts)

    def transport(messages, tools):
        i = min(len(seq) - 1, max(0, len(messages) // 2))
        return ({"role": "assistant", "content": "done"},
                {"input": seq[i], "output": 5})
    return transport


def test_overflow_warns_from_token_count(tmp_path):
    """The durable overflow signal is prompt_eval_count against num_ctx.

    #376 detects overflow by matching ollama's own wording ("no user query found
    in messages"). That is the daemon's message, not an API contract: a reword
    upstream silently reverts every overflow to a generic HTTP 500 with nothing
    saying the diagnostic stopped working. The count is already in hand —
    parse_chat_response returns usage["input"] — and nothing compared it to
    num_ctx.
    """
    tb = ToolBox(cwd=tmp_path)
    rec = run_agent("t", "s", _usage_transport([3700]), tb, TOOLS,
                    turn_cap=1, num_ctx=4096)
    assert rec["warnings"], "a prompt at 90% of num_ctx must warn"
    assert any("context" in w.lower() for w in rec["warnings"])
    assert any("1" in w for w in rec["warnings"]), "the warning must name the turn"


def test_no_warning_well_under_the_limit(tmp_path):
    tb = ToolBox(cwd=tmp_path)
    rec = run_agent("t", "s", _usage_transport([1000]), tb, TOOLS,
                    turn_cap=1, num_ctx=4096)
    assert rec["warnings"] == [], "a prompt with room to spare must not warn"


def test_warning_reaches_the_usage_tracker(tmp_path):
    """The caller's tracker is what the ledger and the CLI read, so the warning
    has to land there too — a record field alone is invisible to both."""
    tb = ToolBox(cwd=tmp_path)
    tracker = {}
    run_agent("t", "s", _usage_transport([4000]), tb, TOOLS,
              turn_cap=1, num_ctx=4096, usage_tracker=tracker)
    assert tracker.get("warnings"), "the overflow warning must reach the usage tracker"


def test_num_ctx_absent_disables_the_check(tmp_path):
    """num_ctx is optional: a caller that does not know it gets no false warning
    rather than a guess. Defaulting to a number would warn on every run against a
    model whose real window is larger."""
    tb = ToolBox(cwd=tmp_path)
    rec = run_agent("t", "s", _usage_transport([999999]), tb, TOOLS, turn_cap=1)
    assert rec["warnings"] == []


def test_edit_file_through_the_loop_leaves_the_rest_byte_identical(tmp_path):
    """The capability this tool exists for, exercised end to end.

    #382 and #384 were both whole-file rewrites that deleted functions the model
    was not asked to touch. The unit arms prove edit_file replaces a unique
    anchor; this proves a model driving it through run_agent changes only what it
    named. Asserted on bytes, because the two failure modes found in review --
    U+FFFD substitution and CRLF folding -- are invisible to a text comparison.
    """
    src = tmp_path / "mod.py"
    original = (
        "def alpha():\n    return 1\n\n"
        "def beta():\n    return 2\n\n"
        "def gamma():\n    return 3\n"
    )
    src.write_bytes(original.encode())

    calls = [{"function": {"name": "edit_file", "arguments": {
        "path": "mod.py", "old_string": "    return 2", "new_string": "    return 22"}}}]

    def transport(messages, tools):
        if len(messages) <= 2:
            return ({"role": "assistant", "content": "", "tool_calls": calls}, {"input": 1, "output": 1})
        return ({"role": "assistant", "content": "done"}, {"input": 1, "output": 1})

    tb = ToolBox(cwd=str(tmp_path))
    rec = run_agent("edit beta", "s", transport, tb, TOOLS, turn_cap=3)

    assert rec["tool_errors"] == []
    expected = original.replace("    return 2\n\ndef gamma", "    return 22\n\ndef gamma")
    assert src.read_bytes() == expected.encode(), \
        "only the named anchor may change; every other byte must survive"
    assert b"def alpha" in src.read_bytes() and b"def gamma" in src.read_bytes(), \
        "the functions the model did not name must still exist"


# --- #385: transport non-UTF8 decode replace and retry visibility ---

def test_ollama_transport_handles_non_utf8_200_body(monkeypatch):
    raw = b'{"message": {"role": "assistant", "content": "hello \xff\xfe"}, "prompt_eval_count": 5, "eval_count": 2}'
    monkeypatch.setattr("urllib.request.urlopen", lambda req, timeout=None: _FakeResp(200, raw))
    t = ollama_transport("qwen3.8:27b", host="127.0.0.1:11434")
    msg, usage = t([{"role": "user", "content": "hi"}], [])
    # The replacement char, not just "hello" -- a substring assert passes equally
    # under errors="ignore", which drops the bytes instead of marking them.
    assert msg["content"] == "hello \ufffd\ufffd"
    assert usage == {"input": 5, "output": 2}


def test_ollama_transport_handles_non_utf8_error_body(monkeypatch):
    import urllib.error

    class _FakeHTTPError(urllib.error.HTTPError):
        def __init__(self):
            super().__init__("http://127.0.0.1/api/chat", 400, "Bad Request", {}, io.BytesIO(b"error \xff\xfe"))

    def raise_http_error(req, timeout=None):
        raise _FakeHTTPError()

    monkeypatch.setattr("urllib.request.urlopen", raise_http_error)
    t = ollama_transport("qwen3.8:27b", host="127.0.0.1:11434")
    with pytest.raises(RuntimeError, match="ollama HTTP 400: error"):
        t([{"role": "user", "content": "hi"}], [])


def test_ollama_transport_logs_warning_on_retry(monkeypatch, capsys):
    import urllib.error

    call_count = 0

    class _Fake503(urllib.error.HTTPError):
        def __init__(self):
            super().__init__("http://127.0.0.1/api/chat", 503, "Service Unavailable", {}, io.BytesIO(b"overloaded"))

    def fail_then_succeed(req, timeout=None):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            raise _Fake503()
        return _FakeResp(200, b'{"message": {"role": "assistant", "content": "recovered"}, "prompt_eval_count": 1, "eval_count": 1}')

    monkeypatch.setattr("urllib.request.urlopen", fail_then_succeed)
    monkeypatch.setattr("time.sleep", lambda s: None)
    t = ollama_transport("qwen3.8:27b", host="127.0.0.1:11434")
    msg, usage = t([{"role": "user", "content": "hi"}], [])
    assert msg["content"] == "recovered"
    err = capsys.readouterr().err
    assert "warning: ollama HTTP 503 on attempt 1/3 for model qwen3.8:27b" in err
    assert "retrying in 0.2s: overloaded" in err


def test_ollama_transport_records_the_retry_in_provenance(monkeypatch):
    # stderr under ceo-cron goes to a log nobody reads. The ledger row is the
    # record that has to distinguish a run that flapped from one that did not.
    import urllib.error

    calls = {"n": 0}

    class _Fake503(urllib.error.HTTPError):
        def __init__(self):
            super().__init__("http://127.0.0.1/api/chat", 503, "Service Unavailable",
                             {}, io.BytesIO(b"overloaded"))

    def fail_then_succeed(req, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            raise _Fake503()
        return _FakeResp(200, b'{"message": {"role": "assistant", "content": "ok"},'
                              b' "prompt_eval_count": 1, "eval_count": 1}')

    monkeypatch.setattr("urllib.request.urlopen", fail_then_succeed)
    monkeypatch.setattr("time.sleep", lambda s: None)
    prov = {}
    t = ollama_transport("qwen3.8:27b", host="127.0.0.1:11434", provenance=prov)
    t([{"role": "user", "content": "hi"}], [])
    assert prov["retried_statuses"] == ["503@1"]



# --- #447 fix pass: Retry-After bounds, guarded 5xx read, excerpts, decode ---

_OK_BODY = json.dumps({"message": {"role": "assistant", "content": "ok"},
                       "prompt_eval_count": 1, "eval_count": 1})


class _FailingBody(io.BytesIO):
    """An HTTPError body whose read() raises what `make_exc` builds, fresh each call."""

    def __init__(self, make_exc):
        super().__init__(b"")
        self._make_exc = make_exc

    def read(self, *a):
        raise self._make_exc()


def _fail_first(monkeypatch, status, headers=None, body=b"busy", fp_factory=None, failures=1):
    """HTTPError `status` on the first `failures` calls, then a clean 200.
    Returns (sleeps, calls): sleeps records every delay the transport asked for."""
    import ollama_agent.transport as t
    calls = {"n": 0}

    def respond(req, timeout):
        calls["n"] += 1
        if calls["n"] <= failures:
            fp = fp_factory() if fp_factory else io.BytesIO(body)
            raise t.urllib.error.HTTPError("u", status, "x", headers or {}, fp)
        return _FakeResp(200, _OK_BODY)

    sleeps = []
    monkeypatch.setattr(t.urllib.request, "urlopen", respond)
    monkeypatch.setattr(t.time, "sleep", sleeps.append)
    return sleeps, calls


def test_retry_after_is_capped(monkeypatch):
    import ollama_agent.transport as t
    sleeps, _ = _fail_first(monkeypatch, 429, {"Retry-After": "3600"})
    t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert t.RETRY_AFTER_CAP_SECONDS == 30.0
    assert sleeps == [30.0]


def test_retry_after_below_backoff_keeps_the_backoff_floor(monkeypatch):
    # Retry-After raises the delay, never lowers it: `Retry-After: 0` must not
    # turn the backoff into a hot loop.
    import ollama_agent.transport as t
    sleeps, _ = _fail_first(monkeypatch, 503, {"Retry-After": "0"})
    t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert sleeps == [0.2]


@pytest.mark.parametrize("value", ["Wed, 21 Oct 2015 07:28:00 GMT", "soon"])
def test_non_numeric_retry_after_falls_back_to_backoff(monkeypatch, value):
    import ollama_agent.transport as t
    sleeps, _ = _fail_first(monkeypatch, 429, {"Retry-After": value})
    t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert sleeps == [0.2]


def test_5xx_body_read_failure_still_retries(monkeypatch):
    import http.client
    import ollama_agent.transport as t
    sleeps, calls = _fail_first(
        monkeypatch, 502,
        fp_factory=lambda: _FailingBody(lambda: http.client.IncompleteRead(b"par")))
    msg, _ = t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert msg["content"] == "ok"
    assert calls["n"] == 2
    assert sleeps == [0.2]


@pytest.mark.parametrize("make_exc,name", [
    (lambda: __import__("http.client").client.IncompleteRead(b"par"), "IncompleteRead"),
    (lambda: ValueError("I/O operation on closed file"), "ValueError"),
], ids=["IncompleteRead", "ValueError"])
def test_5xx_body_read_failure_leaves_a_trace_on_exhaustion(monkeypatch, capsys, make_exc, name):
    # An unreadable body must not read like a 5xx with an empty one.
    import ollama_agent.transport as t
    sleeps, calls = _fail_first(monkeypatch, 503,
                                fp_factory=lambda: _FailingBody(make_exc), failures=3)
    with pytest.raises(RuntimeError) as exc:
        t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    assert calls["n"] == 3
    assert sleeps == [0.2, 0.4]
    assert str(exc.value) == (f"ollama HTTP 503 after 3 attempts for model m: "
                              f"(error body unreadable: {name})")
    assert f"retrying in 0.2s: (error body unreadable: {name})" in capsys.readouterr().err


@pytest.mark.parametrize("exc_type", ["socket_timeout", "TimeoutError"])
def test_5xx_body_read_timeout_raises_at_once(monkeypatch, exc_type):
    # Retrying a body-read timeout brings back the ~3x wait #445 removed.
    import socket
    import ollama_agent.transport as t

    def make():
        return socket.timeout("timed out") if exc_type == "socket_timeout" else TimeoutError("timed out")

    sleeps, calls = _fail_first(monkeypatch, 503,
                                fp_factory=lambda: _FailingBody(make), failures=3)
    prov = {}
    with pytest.raises(RuntimeError, match=r"ollama timed out after 600s at .* for model m; "
                                           r"a thinking model may need --no-think") as exc:
        t.ollama_transport("m", provenance=prov)([{"role": "user", "content": "hi"}], [])
    assert calls["n"] == 1
    assert sleeps == []
    assert "retried_statuses" not in prov
    assert isinstance(exc.value.__cause__, OSError)


def test_non_retryable_body_read_value_error_is_translated(monkeypatch):
    import ollama_agent.transport as t

    def fail(req, timeout):
        raise t.urllib.error.HTTPError("u", 500, "x", {},
                                       _FailingBody(lambda: ValueError("closed")))
    monkeypatch.setattr(t.urllib.request, "urlopen", fail)
    with pytest.raises(RuntimeError, match=r"ollama HTTP 500 for model m; error body unreadable"):
        t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])


def test_retry_warning_and_exhaustion_carry_the_escaped_body(monkeypatch, capsys):
    import ollama_agent.transport as t
    sleeps, _ = _fail_first(monkeypatch, 503, body=b"busy\nREFUSED x\r\\y", failures=3)
    with pytest.raises(RuntimeError) as exc:
        t.ollama_transport("m")([{"role": "user", "content": "hi"}], [])
    escaped = "busy\\nREFUSED x\\r\\\\y"
    assert str(exc.value).endswith(": " + escaped)
    assert "\n" not in str(exc.value)
    err = capsys.readouterr().err
    assert f"retrying in 0.2s: {escaped}" in err
    assert f"retrying in 0.4s: {escaped}" in err
    assert not any(line.startswith("REFUSED") for line in err.splitlines())


_SENT = "no user query found in messages"


@pytest.mark.parametrize("status,body", [
    (500, _SENT + "\nREFUSED forged"),
    (500, "boom\nREFUSED forged"),
    (200, "not json\nREFUSED forged"),
    (200, "[1,\nREFUSED]"),
    (200, '{"done":\ntrue}'),
    (200, '{"message": {}, "eval_count":\n"REFUSED"}'),
    (200, json.dumps({"error": _SENT + "\nREFUSED forged"})),
    (200, json.dumps({"error": "busy\nREFUSED forged"})),
], ids=["non200-overflow", "non200", "unparseable", "non-object", "no-message",
        "non-numeric", "err-overflow", "err"])
def test_parse_chat_response_errors_are_single_line(status, body):
    with pytest.raises(RuntimeError) as exc:
        parse_chat_response(status, body)
    assert "\n" not in str(exc.value)
    assert "\\n" in str(exc.value)


def test_decode_check_counts_raw_invalid_bytes_as_a_summed_int(monkeypatch, capsys):
    raw = (b'{"message": {"role": "assistant", "content": "hello \xff\xfe world"},'
           b' "prompt_eval_count": 1, "eval_count": 1}')
    monkeypatch.setattr("urllib.request.urlopen", lambda req, timeout=None: _FakeResp(200, raw))
    prov = {}
    msg, _ = ollama_transport("m", provenance=prov)([{"role": "user", "content": "hi"}], [])
    assert msg["content"] == "hello �� world"
    assert prov["decode_replacements"] == 2
    assert ("warning: ollama message had 2 U+FFFD replacement character(s); "
            "model output may be corrupted") in capsys.readouterr().err


def test_decode_replacements_sum_across_turns(monkeypatch):
    # `_note` dedups, so three turns of one replacement each recorded ["1"].
    raw = (b'{"message": {"role": "assistant", "content": "a \xff"},'
           b' "prompt_eval_count": 1, "eval_count": 1}')
    monkeypatch.setattr("urllib.request.urlopen", lambda req, timeout=None: _FakeResp(200, raw))
    prov = {}
    t = ollama_transport("m", provenance=prov)
    for _ in range(3):
        t([{"role": "user", "content": "hi"}], [])
    assert prov["decode_replacements"] == 3


@pytest.mark.parametrize("message", [
    b'{"role": "assistant", "content": "caf\\ufffd"}',
    b'{"role": "assistant", "content": "", "tool_calls": [{"function": '
    b'{"name": "write_file", "arguments": {"content": "caf\\ufffd"}}}]}',
    b'{"role": "assistant", "content": "", "thinking": "caf\\ufffd"}',
], ids=["content", "tool-call-argument", "thinking"])
def test_decode_check_sees_the_go_escaped_substitution(monkeypatch, capsys, message):
    # Go's json.Marshal substitutes invalid bytes server-side and emits the
    # escape, so the body is valid ASCII and a byte-level check never fires.
    raw = b'{"message": ' + message + b', "prompt_eval_count": 1, "eval_count": 1}'
    monkeypatch.setattr("urllib.request.urlopen", lambda req, timeout=None: _FakeResp(200, raw))
    prov = {}
    ollama_transport("m", provenance=prov)([{"role": "user", "content": "hi"}], [])
    assert prov["decode_replacements"] == 1
    assert "1 U+FFFD replacement character(s)" in capsys.readouterr().err


def test_clean_body_records_no_decode_replacements(monkeypatch, capsys):
    raw = _OK_BODY.encode()
    monkeypatch.setattr("urllib.request.urlopen", lambda req, timeout=None: _FakeResp(200, raw))
    prov = {}
    ollama_transport("m", provenance=prov)([{"role": "user", "content": "hi"}], [])
    assert "decode_replacements" not in prov
    assert "U+FFFD" not in capsys.readouterr().err
