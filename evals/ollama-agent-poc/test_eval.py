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
