"""ToolBox.dispatch error capture (epic #197 Slice C / #215).

A mutating tool whose result carries an "error" (write_file/git/run_shell
exception or timeout) is recorded in .tool_errors so the cron gate can fail a
completed-but-errored run. A benign read/list probe error and a non-zero shell
returncode are NOT operational failures and must stay out of .tool_errors.
"""
import json
import subprocess

from ollama_agent.tools import ToolBox, TOOLS, ERROR_RELEVANT_TOOLS
from ollama_agent.skills import Skill, USE_SKILL_TOOL


def test_schema_and_dispatch_handler_parity(tmp_path):
    """#275: Every tool in TOOLS (+ USE_SKILL_TOOL) must have a dispatch handler in ToolBox,
    and every static dispatch handler in ToolBox must have a matching schema.
    """
    schema_names = {t["function"]["name"] for t in TOOLS} | {USE_SKILL_TOOL["function"]["name"]}
    expected_handlers = {"run_shell", "git", "read_file", "write_file", "edit_file", "list_dir", "use_skill"}

    assert schema_names == expected_handlers, "Schemas and expected handler names must match exactly"

    skill_file = tmp_path / "SKILL.md"
    skill_file.write_text("body text")
    skill = Skill("my_skill", str(skill_file), "description")
    # cwd, not the default ".". write_file and edit_file below are dispatched for
    # real, so without this the parity check writes dummy.txt into the repo
    # working tree instead of the fixture (test-writes-stay-in-the-fixture).
    tb = ToolBox(cwd=str(tmp_path), skills=[skill])
    args_map = {
        "run_shell": {"command": "true"},
        "git": {"args": "version"},
        "read_file": {"path": "dummy.txt"},
        "write_file": {"path": "dummy.txt", "content": "hi"},
        "edit_file": {"path": "dummy.txt", "old_string": "h", "new_string": "H"},
        "list_dir": {"path": "."},
        "use_skill": {"name": "my_skill"},
    }
    for name in schema_names:
        # None of the real tools should report "unknown tool" when dispatched
        res = json.loads(tb.dispatch(name, args_map[name]))
        assert res.get("error") != f"unknown tool: {name}"
    assert tb.unknown_calls == []

    # An unknown name is recorded in unknown_calls
    res_unknown = json.loads(tb.dispatch("unknown_tool_xyz", {}))
    assert tb.unknown_calls == ["unknown_tool_xyz"]
    assert res_unknown.get("error") == "unknown tool: unknown_tool_xyz"


def test_mutating_tools_covered_by_error_capture_predicate():
    """#275: Mutating members of the dispatch table must be covered by ERROR_RELEVANT_TOOLS,
    so mutating failures are always recorded in tool_errors for the cron gate (#215).
    """
    mutating_builtins = {"write_file", "edit_file", "git", "run_shell"}
    assert mutating_builtins == ERROR_RELEVANT_TOOLS

    read_only_tools = {"read_file", "list_dir", "use_skill"}
    assert read_only_tools.isdisjoint(ERROR_RELEVANT_TOOLS)


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
    # A refusal must also not have written. Asserting only the error passes an
    # implementation that writes and *then* refuses — verified: moving the
    # uniqueness check below f.write_bytes left the whole suite green.
    assert f.read_text() == "def foo():\n    return 1\n"



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
    # A refusal must also not have written. Asserting only the error passes an
    # implementation that writes and *then* refuses — verified: moving the
    # uniqueness check below f.write_bytes left the whole suite green.
    assert f.read_text() == "x = 1\nx = 1\n"



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
    # A refusal must also not have written. Asserting only the error passes an
    # implementation that writes and *then* refuses — verified: moving the
    # uniqueness check below f.write_bytes left the whole suite green.
    assert f.read_text() == "def foo(): pass\n"



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


# --- #408 review: the success path must not corrupt what it did not touch ---

def test_non_utf8_file_is_refused_not_mangled(tmp_path):
    """`read_text(errors="replace")` then `write_text` round-trips U+FFFD back to disk.

    read_file uses the same flag safely because it never writes. edit_file is the
    first tool to round-trip it, so a byte the model never targeted is destroyed
    while the result reads `{"path":…, "bytes":…}` with an empty .tool_errors —
    the #382 shape reappearing inside the fix for it.
    """
    f = tmp_path / "latin.txt"
    f.write_bytes(b"header\nname = caf\xe9\nANCHOR\nfooter\n")
    before = f.read_bytes()

    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("edit_file", {
        "path": "latin.txt", "old_string": "ANCHOR", "new_string": "REPLACED"}))

    assert "error" in result, "an undecodable file must be refused, not silently rewritten"
    assert f.read_bytes() == before, "a refused edit must leave the file byte-identical"
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


def test_crlf_line_endings_survive_an_edit(tmp_path):
    """`read_text` folds CRLF to \\n and `write_text` writes os.linesep back.

    A one-line edit therefore rewrites every line ending in the file — a
    whole-file diff from a tool whose entire contract is "replace one unique
    occurrence", which is the deletion-heavy shape #407 exists to prevent.
    """
    f = tmp_path / "crlf.txt"
    f.write_bytes(b"a = 1\r\nb = 2\r\nc = 3\r\n")

    tb = ToolBox(cwd=str(tmp_path))
    json.loads(tb.dispatch("edit_file", {
        "path": "crlf.txt", "old_string": "b = 2", "new_string": "b = 9"}))

    assert f.read_bytes() == b"a = 1\r\nb = 9\r\nc = 3\r\n", \
        "only the anchor may change; line endings elsewhere must be untouched"


def test_omitted_new_string_is_refused(tmp_path):
    """An omitted third field turns an edit into a deletion, reported as success.

    Routine for the small local models this bridge targets — which is why
    _normalize_args exists at all. An explicit "" stays a legal deletion; an
    absent key is a caller bug.
    """
    f = tmp_path / "del.py"
    f.write_text("def f():\n    return 1\n")

    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("edit_file", {
        "path": "del.py", "old_string": "    return 1\n"}))

    assert "error" in result, "an absent new_string must be refused, not treated as a deletion"
    assert f.read_text() == "def f():\n    return 1\n", "and the file must be untouched"
    assert [e["tool"] for e in tb.tool_errors] == ["edit_file"]


def test_explicit_empty_new_string_still_deletes(tmp_path):
    """The converse: deleting the anchor is a legitimate edit when asked for."""
    f = tmp_path / "del2.py"
    f.write_text("def f():\n    return 1\n")
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("edit_file", {
        "path": "del2.py", "old_string": "    return 1\n", "new_string": ""}))
    assert "error" not in result
    assert f.read_text() == "def f():\n"


def test_overlapping_matches_count_as_ambiguous(tmp_path):
    """`str.count` is non-overlapping, so the uniqueness promise is not kept.

    "aaa".count("aa") == 1 although "aa" matches at index 0 and 1. The edit then
    lands at the first position, which may not be the one the model meant — and
    uniqueness is the single invariant this tool is built on.
    """
    f = tmp_path / "ov.txt"
    f.write_text("aaa")
    tb = ToolBox(cwd=str(tmp_path))
    result = json.loads(tb.dispatch("edit_file", {
        "path": "ov.txt", "old_string": "aa", "new_string": "B"}))
    assert "error" in result, "overlapping matches must read as ambiguous"
    assert f.read_text() == "aaa", "and the file must be untouched"


def test_mcp_tool_error_recorded_in_tool_errors(tmp_path):
    # #271: Every bridged MCP tool call failure must be captured in tool_errors
    class FailingMCP:
        def call_tool(self, name, args):
            raise RuntimeError("mcp server timed out")

    tb = ToolBox(cwd=str(tmp_path), mcp_client=FailingMCP(), mcp_names={"mcp__custom_tool": "custom_tool"})
    res = json.loads(tb.dispatch("mcp__custom_tool", {}))
    assert "error" in res
    assert [e["tool"] for e in tb.tool_errors] == ["mcp__custom_tool"]
    assert "RuntimeError" in tb.tool_errors[0]["error"]


def test_every_mutating_builtin_stays_error_relevant():
    """Tripwire: a mutating tool absent from the set fails silently.

    A tool that writes but is not listed returns {"error": ...} and leaves
    .tool_errors empty, so the cron gate passes a run that broke something
    (#215). Adding a mutating tool without adding it here is invisible
    everywhere else — no test fails, and the gate keeps reporting success.
    """
    assert {"write_file", "edit_file", "git", "run_shell"} <= ERROR_RELEVANT_TOOLS
