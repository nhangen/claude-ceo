"""ToolBox.dispatch error capture (epic #197 Slice C / #215).

A mutating tool whose result carries an "error" (write_file/git/run_shell
exception or timeout) is recorded in .tool_errors so the cron gate can fail a
completed-but-errored run. A benign read/list probe error and a non-zero shell
returncode are NOT operational failures and must stay out of .tool_errors.
"""
import json
import subprocess

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


def test_git_string_args_handles_quoted_spaces(tmp_path):
    subprocess.run(["git", "init", "-b", "main"], cwd=tmp_path, check=True, capture_output=True)
    # hooksPath points at a real empty dir, not "": without it the fixture inherits
    # the machine's global core.hooksPath, whose identity gate rejects the placeholder
    # identity below. gpgsign off so a machine that signs by default doesn't fail the
    # commit arm for a reason unrelated to tokenization.
    hooks = tmp_path / "hooks-none"
    hooks.mkdir()
    for key, value in (("user.name", "t"), ("user.email", "t@example.com"),
                       ("core.hooksPath", str(hooks)), ("commit.gpgsign", "false")):
        subprocess.run(["git", "config", key, value], cwd=tmp_path, check=True,
                       capture_output=True)

    file_with_spaces = tmp_path / "my file with spaces.txt"
    file_with_spaces.write_text("hello world")

    tb = ToolBox(cwd=str(tmp_path))

    # String args with quoted spaces (would fail under str.split(), passes under shlex.split())
    res_str = json.loads(tb.dispatch("git", {"args": 'add "my file with spaces.txt"'}))
    assert res_str["returncode"] == 0
    assert tb.tool_errors == []

    res_commit = json.loads(tb.dispatch("git", {"args": 'commit -m "commit message with spaces"'}))
    assert res_commit["returncode"] == 0
    assert tb.tool_errors == []
    # returncode 0 alone survives posix=False, which keeps the quotes in the subject.
    subject = subprocess.run(["git", "log", "-1", "--pretty=%s"], cwd=tmp_path,
                             check=True, capture_output=True, text=True).stdout.strip()
    assert subject == "commit message with spaces"

    # List args: an element containing a space stays one argv token. Assert against
    # an UNTRACKED file — a committed one reports clean for every pathspec, including
    # a flattened argv, so asserting emptiness here proves nothing.
    (tmp_path / "another file with spaces.txt").write_text("x")
    res_status = json.loads(tb.dispatch(
        "git", {"args": ["status", "--porcelain", "another file with spaces.txt"]}))
    assert res_status["returncode"] == 0
    assert res_status["stdout"].strip() == '?? "another file with spaces.txt"'


def test_git_malformed_quoting_is_an_error(tmp_path):
    # shlex.split raises ValueError on an unbalanced quote. git is in
    # ERROR_RELEVANT_TOOLS, so a stray quote fails the run instead of reaching
    # git as the garbled argv str.split() used to hand it.
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("git", {"args": 'commit -m "unterminated'}))
    assert "error" in result
    assert "ValueError" in result["error"]
    assert [e["tool"] for e in tb.tool_errors] == ["git"]
