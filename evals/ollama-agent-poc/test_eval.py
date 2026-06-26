from eval import ToolBox, CHANGED_FILES, run_loop

def test_git_status_returns_changed_files_and_sets_flag():
    tb = ToolBox()
    import json
    assert json.loads(tb.git_status()) == CHANGED_FILES
    assert tb.git_status_called is True

def test_git_add_accumulates_union_across_calls():
    tb = ToolBox()
    tb.git_add(["src/app.py"])
    tb.git_add(["src/app.py", "README.md"])
    assert tb.staged == ["src/app.py", "README.md"]

def _fake_transport(script):
    calls = {"i": 0}
    def t(messages, tools):
        resp = script[calls["i"]]
        calls["i"] += 1
        return resp
    return t

def test_loop_dispatches_tools_then_finishes():
    script = [
        {"role":"assistant","content":"","tool_calls":[{"function":{"name":"git_status","arguments":{}}}]},
        {"role":"assistant","content":"","tool_calls":[{"function":{"name":"git_add","arguments":{"files":["src/app.py","README.md"]}}}]},
        {"role":"assistant","content":"Done."},
    ]
    r = run_loop("RULE", "stage files", _fake_transport(script))
    assert r["git_status_called"] is True
    assert r["staged"] == ["src/app.py", "README.md"]
    assert r["completed"] is True
    assert r["turns"] == 3

def test_loop_respects_turn_cap():
    loop_call = {"role":"assistant","content":"","tool_calls":[{"function":{"name":"git_status","arguments":{}}}]}
    r = run_loop("RULE", "x", _fake_transport([loop_call]*10), turn_cap=4)
    assert r["turns"] == 4
    assert r["completed"] is False

def test_grade_valid_and_excluded():
    from eval import grade
    g = grade(["src/app.py","README.md"])
    assert g == {"valid": True, "tmp_excluded": True}

def test_grade_valid_but_included():
    from eval import grade
    g = grade(["src/app.py","README.md","tmp/debug.log"])
    assert g == {"valid": True, "tmp_excluded": False}

def test_grade_partial_staging_is_invalid():
    from eval import grade
    # excludes tmp/ but dropped README.md -> not a real PASS
    g = grade(["src/app.py"])
    assert g["valid"] is False

import pytest
from eval import _parse_chat_response

def test_parse_chat_response_raises_on_error_body():
    with pytest.raises(RuntimeError):
        _parse_chat_response(200, '{"error":"model not found"}')

def test_parse_chat_response_raises_on_http_error():
    with pytest.raises(RuntimeError):
        _parse_chat_response(500, '{}')

def test_parse_chat_response_returns_message():
    msg = _parse_chat_response(200, '{"message":{"role":"assistant","content":"hi"}}')
    assert msg["content"] == "hi"
