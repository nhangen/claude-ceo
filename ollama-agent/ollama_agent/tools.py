"""The real (non-stub) tool layer the local model drives.

Trust boundary: every tool runs bounded inside a single working directory
(`cwd`) with a wall-clock timeout and truncated output. There is intentionally
no command allowlist or path jail yet — per-task tool restriction and
safe-delegation tiering land in the governance slice (#190). Until then this is
a deliberately-invoked local tool, not an unattended one; the caller picks cwd.
"""
import json
import shlex
import subprocess
from pathlib import Path

from .skills import MAX_SKILL_BODY

MAX_OUTPUT = 4000      # chars of stdout/stderr returned to the model per call
MAX_READ = 20000       # chars returned by read_file

# Tools whose error result signals an operational failure the cron gate should
# fail the run on. A read_file/list_dir "error" is a benign path probe, and a
# run_shell non-zero returncode (grep no-match, [ -f x ]) is not an error key —
# only a run_shell timeout/exception sets one. A git args string that cannot be
# tokenized (unbalanced quote) raises and so does set one: the model asked for a
# mutation that never ran. unknown tools/skills are gated separately via
# .unknown_calls.
ERROR_RELEVANT_TOOLS = {"write_file", "git", "run_shell"}

# git subcommands that change something. A non-zero exit from one of these is an
# operational failure the cron gate must see; a non-zero exit from a read verb is
# that verb's answer — `diff --quiet` returns 1 to say "there are differences",
# and failing a run over it would fail runs that did exactly what they meant to.
# So the guard keys on the subcommand, not on the returncode alone.
MUTATING_GIT_SUBCOMMANDS = {
    "add", "am", "apply", "branch", "checkout", "cherry-pick", "clean", "clone",
    "commit", "fetch", "init", "merge", "mv", "pull", "push", "rebase", "reset",
    "restore", "revert", "rm", "stash", "switch", "tag", "worktree",
}


def _clip(s, n):
    s = s or ""
    return s if len(s) <= n else s[:n] + f"\n…[truncated {len(s) - n} chars]"


class ToolBox:
    def __init__(self, cwd=".", timeout=30, skills=None, mcp_client=None, mcp_names=None):
        self.cwd = Path(cwd).resolve()
        self.timeout = timeout
        self.skills = list(skills) if skills else []   # [Skill] for use_skill, if any
        self.mcp_client = mcp_client                   # MCPClient, if an MCP server is bridged
        self.mcp_names = dict(mcp_names) if mcp_names else {}  # prefixed_name -> real MCP tool name
        self.calls = []            # (name, args) of every dispatched call
        self.unknown_calls = []    # tool/skill names the model hallucinated
        self.tool_errors = []      # {tool, error} for mutating-tool failures (#215)

    def _resolve(self, path):
        p = Path(path)
        return p if p.is_absolute() else (self.cwd / p)

    def run_shell(self, command):
        try:
            p = subprocess.run(command, shell=True, cwd=self.cwd, capture_output=True,
                               text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return json.dumps({"returncode": None, "error": f"timeout>{self.timeout}s"})
        return json.dumps({"returncode": p.returncode,
                           "stdout": _clip(p.stdout, MAX_OUTPUT),
                           "stderr": _clip(p.stderr, MAX_OUTPUT)})

    def git(self, args):
        argv = args if isinstance(args, list) else shlex.split(str(args))
        try:
            p = subprocess.run(["git", *argv], cwd=self.cwd, capture_output=True,
                               text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return json.dumps({"returncode": None, "error": f"timeout>{self.timeout}s"})
        out = {"returncode": p.returncode,
               "stdout": _clip(p.stdout, MAX_OUTPUT),
               "stderr": _clip(p.stderr, MAX_OUTPUT)}
        # Gated here rather than at the caller, so no caller can opt out
        # (safety-invariant-scope step 4). An empty argv counts: a git call that
        # named no subcommand did not do the work its caller intended, and
        # reporting it clean hides that from the same gate.
        if p.returncode != 0 and (not argv or argv[0] in MUTATING_GIT_SUBCOMMANDS):
            sub = argv[0] if argv else "(no subcommand)"
            out["error"] = f"git {sub} exited {p.returncode}: {_clip(p.stderr, 500)}"
        return json.dumps(out)

    def read_file(self, path):
        f = self._resolve(path)
        if not f.is_file():
            return json.dumps({"error": f"not a file: {path}"})
        return json.dumps({"path": str(f), "content": _clip(f.read_text(errors="replace"), MAX_READ)})

    def write_file(self, path, content):
        f = self._resolve(path)
        f.parent.mkdir(parents=True, exist_ok=True)
        data = content if content is not None else ""
        f.write_text(data)
        return json.dumps({"path": str(f), "bytes": len(data.encode())})

    def list_dir(self, path="."):
        d = self._resolve(path)
        if not d.is_dir():
            return json.dumps({"error": f"not a directory: {path}"})
        return json.dumps({"path": str(d),
                           "entries": sorted(p.name + ("/" if p.is_dir() else "") for p in d.iterdir())})

    def use_skill(self, name):
        for s in self.skills:
            if s.name == name:
                return json.dumps({"name": s.name, "body": _clip(s.body(), MAX_SKILL_BODY)})
        self.unknown_calls.append(name)
        return json.dumps({"error": f"unknown skill: {name}",
                           "available": [s.name for s in self.skills]})

    def call_mcp(self, prefixed_name, args):
        real = self.mcp_names[prefixed_name]
        result = self.mcp_client.call_tool(real, args)
        return json.dumps({"tool": prefixed_name, "result": _clip(str(result), MAX_READ)})

    def dispatch(self, name, args):
        """Route one tool call. Records every call; unknown names are recorded
        separately and returned as an error string (never silently dropped)."""
        self.calls.append((name, args))
        handler = {
            "run_shell": lambda a: self.run_shell(a.get("command", "")),
            "git": lambda a: self.git(a.get("args", [])),
            "read_file": lambda a: self.read_file(a.get("path", "")),
            "write_file": lambda a: self.write_file(a.get("path", ""), a.get("content", "")),
            "list_dir": lambda a: self.list_dir(a.get("path", ".")),
            "use_skill": lambda a: self.use_skill(a.get("name", "")),
        }.get(name)
        if handler is None and name in self.mcp_names:
            handler = lambda a: self.call_mcp(name, a)  # noqa: E731
        if handler is None:
            self.unknown_calls.append(name)
            return json.dumps({"error": f"unknown tool: {name}"})
        try:
            result = handler(args)
        except Exception as e:
            # A tool that raises (PermissionError, ENOSPC, UnicodeError, cwd
            # deleted, …) must return a recorded error to the model, never abort
            # the run — keep the loop and transcript alive (safety-invariant-scope).
            result = json.dumps({"error": f"{name} failed: {type(e).__name__}: {e}"})
        self._note_tool_error(name, result)
        return result

    def _note_tool_error(self, name, result):
        """Record a mutating-tool failure so the dispatcher (cron) can fail a
        completed-but-errored run (#215). Inspects the result's "error" key —
        absence-of-throw is not success (non-throwing-client-success-check).
        Every MCP tool dispatch is treated as error-relevant (#271)."""
        if name not in ERROR_RELEVANT_TOOLS and name not in self.mcp_names:
            return
        try:
            parsed = json.loads(result)
        except (json.JSONDecodeError, TypeError):
            return
        if isinstance(parsed, dict) and parsed.get("error"):
            self.tool_errors.append({"tool": name, "error": parsed["error"]})


TOOLS = [
    {"type": "function", "function": {"name": "run_shell",
        "description": "Run a shell command in the working directory and return its returncode, stdout, and stderr.",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string", "description": "The shell command to run."}},
            "required": ["command"]}}},
    {"type": "function", "function": {"name": "git",
        "description": "Run a git subcommand in the working directory (e.g. args=[\"status\",\"--short\"]). args may also be a single string, tokenized with shell quoting rules: quote any path or message containing spaces, and escape a literal backslash.",
        "parameters": {"type": "object", "properties": {
            "args": {"type": ["array", "string"], "items": {"type": "string"}}},
            "required": ["args"]}}},
    {"type": "function", "function": {"name": "read_file",
        "description": "Read a file (relative to the working directory) and return its content.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "write_file",
        "description": "Write content to a file (relative to the working directory), creating parent dirs.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "list_dir",
        "description": "List the entries of a directory (relative to the working directory).",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}}, "required": []}}},
]
