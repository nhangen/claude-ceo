"""The real (non-stub) tool layer the local model drives.

Trust boundary: every tool runs bounded inside a single working directory
(`cwd`) with a wall-clock timeout and truncated output. There is intentionally
no command allowlist or path jail yet — per-task tool restriction and
safe-delegation tiering land in the governance slice (#190). Until then this is
a deliberately-invoked local tool, not an unattended one; the caller picks cwd.
"""
import json
import subprocess
from pathlib import Path

MAX_OUTPUT = 4000      # chars of stdout/stderr returned to the model per call
MAX_READ = 20000       # chars returned by read_file


def _clip(s, n):
    s = s or ""
    return s if len(s) <= n else s[:n] + f"\n…[truncated {len(s) - n} chars]"


class ToolBox:
    def __init__(self, cwd=".", timeout=30):
        self.cwd = Path(cwd).resolve()
        self.timeout = timeout
        self.calls = []            # (name, args) of every dispatched call
        self.unknown_calls = []    # names the model hallucinated

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
        argv = args if isinstance(args, list) else str(args).split()
        try:
            p = subprocess.run(["git", *argv], cwd=self.cwd, capture_output=True,
                               text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return json.dumps({"returncode": None, "error": f"timeout>{self.timeout}s"})
        return json.dumps({"returncode": p.returncode,
                           "stdout": _clip(p.stdout, MAX_OUTPUT),
                           "stderr": _clip(p.stderr, MAX_OUTPUT)})

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
        }.get(name)
        if handler is None:
            self.unknown_calls.append(name)
            return json.dumps({"error": f"unknown tool: {name}"})
        try:
            return handler(args)
        except Exception as e:
            # A tool that raises (PermissionError, ENOSPC, UnicodeError, cwd
            # deleted, …) must return a recorded error to the model, never abort
            # the run — keep the loop and transcript alive (safety-invariant-scope).
            return json.dumps({"error": f"{name} failed: {type(e).__name__}: {e}"})


TOOLS = [
    {"type": "function", "function": {"name": "run_shell",
        "description": "Run a shell command in the working directory and return its returncode, stdout, and stderr.",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string", "description": "The shell command to run."}},
            "required": ["command"]}}},
    {"type": "function", "function": {"name": "git",
        "description": "Run a git subcommand in the working directory (e.g. args=[\"status\",\"--short\"]).",
        "parameters": {"type": "object", "properties": {
            "args": {"type": "array", "items": {"type": "string"}}},
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
