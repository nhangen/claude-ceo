from eval import ToolBox, CHANGED_FILES

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
