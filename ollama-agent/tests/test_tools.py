"""ToolBox.dispatch error capture (epic #197 Slice C / #215).

A mutating tool whose result carries an "error" (write_file/git/run_shell
exception or timeout) is recorded in .tool_errors so the cron gate can fail a
completed-but-errored run. A benign read/list probe error and a non-zero shell
returncode are NOT operational failures and must stay out of .tool_errors.
"""
import json

from ollama_agent.tools import ToolBox


def test_write_file_error_recorded(tmp_path):
    (tmp_path / "blocker").write_text("x")  # a FILE where write_file needs a dir
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("write_file", {"path": "blocker/child.txt", "content": "d"}))
    assert "error" in result
    assert [e["tool"] for e in tb.tool_errors] == ["write_file"]


def test_successful_write_records_no_error(tmp_path):
    tb = ToolBox(cwd=str(tmp_path))
    tb.dispatch("write_file", {"path": "ok.txt", "content": "hi"})
    assert tb.tool_errors == []


def test_run_shell_nonzero_exit_is_not_an_error(tmp_path):
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("run_shell", {"command": "exit 3"}))
    assert result["returncode"] == 3
    assert tb.tool_errors == []


def test_read_file_missing_is_not_an_error(tmp_path):
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("read_file", {"path": "nope.txt"}))
    assert "error" in result
    assert tb.tool_errors == []


def test_run_shell_timeout_is_an_error(tmp_path):
    tb = ToolBox(cwd=str(tmp_path), timeout=1)
    result = json.loads(tb.dispatch("run_shell", {"command": "sleep 5"}))
    assert "error" in result
    assert [e["tool"] for e in tb.tool_errors] == ["run_shell"]
