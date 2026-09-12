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


def test_edit_file_replaces_unique_string(tmp_path):
    f = tmp_path / "code.py"
    f.write_text("def foo():\n    return 1\n")
    tb = ToolBox(cwd=str(tmp_path))
    res = json.loads(tb.dispatch("edit_file", {
        "path": "code.py",
        "old_string": "return 1",
        "new_string": "return 2",
    }))
    assert "error" not in res
    assert res["path"] == str(f)
    assert f.read_text() == "def foo():\n    return 2\n"
    assert tb.tool_errors == []


def test_edit_file_absent_anchor_is_error_and_recorded(tmp_path):
    f = tmp_path / "code.py"
    f.write_text("def foo():\n    return 1\n")
    tb = ToolBox(cwd=str(tmp_path))
    res = json.loads(tb.dispatch("edit_file", {
        "path": "code.py",
        "old_string": "return 999",
        "new_string": "return 2",
    }))
    assert "error" in res
    assert "old_string not found" in res["error"]
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


def test_edit_file_ambiguous_anchor_is_error_and_recorded(tmp_path):
    f = tmp_path / "code.py"
    f.write_text("x = 1\nx = 1\n")
    tb = ToolBox(cwd=str(tmp_path))
    res = json.loads(tb.dispatch("edit_file", {
        "path": "code.py",
        "old_string": "x = 1",
        "new_string": "x = 2",
    }))
    assert "error" in res
    assert "found 2 times" in res["error"]
    assert "must be unique" in res["error"]
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


def test_edit_file_missing_file_is_error_and_recorded(tmp_path):
    tb = ToolBox(cwd=str(tmp_path))
    res = json.loads(tb.dispatch("edit_file", {
        "path": "nonexistent.py",
        "old_string": "foo",
        "new_string": "bar",
    }))
    assert "error" in res
    assert "not a file" in res["error"]
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


def test_edit_file_empty_old_string_is_error_and_recorded(tmp_path):
    f = tmp_path / "code.py"
    f.write_text("def foo(): pass\n")
    tb = ToolBox(cwd=str(tmp_path))
    res = json.loads(tb.dispatch("edit_file", {
        "path": "code.py",
        "old_string": "",
        "new_string": "bar",
    }))
    assert "error" in res
    assert "old_string must not be empty" in res["error"]
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


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


def _repo(tmp_path):
    """A real git repo, since the point is what git itself does with a refusal."""
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "t"], check=True)
    return tmp_path


def test_refused_git_commit_is_recorded(tmp_path):
    """A git that git itself refused reaches the cron dispatcher as a clean run.

    ToolBox.git sets "error" only on TimeoutExpired, so a non-zero returncode
    carries no error key, _note_tool_error finds nothing, and .tool_errors stays
    empty. scripts/ceo-cron.sh gates on len(tool_errors) > 0, so the run is
    recorded successful with the commit never made — the failure #215 and the
    write_file arm above exist to prevent, with no equivalent for git.
    """
    _repo(tmp_path)
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("git", {"args": ["commit", "-m", "nothing staged"]}))
    assert result["returncode"] != 0, "precondition: git must refuse an empty commit"
    assert "error" in result, "a refused git commit must carry an error key"
    assert [e["tool"] for e in tb.tool_errors] == ["git"]


def test_read_verb_exiting_nonzero_is_not_an_error(tmp_path):
    """Read verbs exit non-zero as a normal answer, not a failure.

    `diff --quiet` returns 1 to mean "there are differences". Treating that as an
    operational error would fail runs that did exactly what they meant to, so the
    guard has to key on the subcommand rather than the returncode alone.
    """
    repo = _repo(tmp_path)
    (repo / "f.txt").write_text("a")
    subprocess.run(["git", "-C", str(repo), "add", "f.txt"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "one"], check=True)
    (repo / "f.txt").write_text("b")

    tb = ToolBox(cwd=str(repo))
    result = json.loads(tb.dispatch("git", {"args": ["diff", "--quiet"]}))
    assert result["returncode"] != 0, "precondition: diff --quiet signals differences"
    assert tb.tool_errors == [], "a read verb's non-zero exit must not be an operational error"


def test_successful_git_records_no_error(tmp_path):
    repo = _repo(tmp_path)
    (repo / "f.txt").write_text("a")
    tb = ToolBox(cwd=str(repo))
    tb.dispatch("git", {"args": ["add", "f.txt"]})
    assert tb.tool_errors == []


def test_bare_git_is_recorded(tmp_path):
    """Decided here rather than left open: an empty argv is always a caller bug.

    `git` with no subcommand prints usage and exits 1. It mutates nothing, so an
    allowlist keyed on the subcommand leaves it benign — but a git call that named
    no subcommand did not do the work the caller intended, and reporting it clean
    hides that from the same gate. It is recorded.
    """
    _repo(tmp_path)
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("git", {"args": []}))
    assert result["returncode"] != 0, "precondition: bare git exits non-zero"
    assert "error" in result
    assert [e["tool"] for e in tb.tool_errors] == ["git"]
