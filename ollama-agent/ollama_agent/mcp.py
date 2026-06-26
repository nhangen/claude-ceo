"""Bridge an MCP server's tools into the ollama /api/chat tool schema.

MCP speaks JSON-RPC 2.0 over a transport (stdio newline-delimited JSON is the
common one). This module is transport-injectable: MCPClient takes any object with
`send(obj)`/`recv()->obj`, so the protocol logic is testable with an in-memory
fake and the real subprocess transport (StdioMCPTransport) is a thin wrapper.

Success is checked explicitly on every call: a JSON-RPC `error` member and an
MCP `isError` result both raise MCPError, so a server-side failure routes to the
agent's failure path rather than reading as a successful tool turn
(non-throwing-client-success-check).
"""
import json
import shlex
import subprocess

PROTOCOL_VERSION = "2024-11-05"


class MCPError(RuntimeError):
    pass


def _result_text(result):
    """MCP tool results carry a content array; pull the text parts out for the
    model. Falls back to the raw result for non-text content."""
    content = result.get("content") if isinstance(result, dict) else None
    if isinstance(content, list):
        texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        if texts:
            return "\n".join(texts)
    return result


class MCPClient:
    def __init__(self, transport):
        self.t = transport
        self._id = 0

    def _rpc(self, method, params=None):
        self._id += 1
        self.t.send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}})
        resp = self.t.recv()
        if not isinstance(resp, dict):
            raise MCPError(f"{method}: non-object response {resp!r}")
        if resp.get("error"):
            raise MCPError(f"{method}: {resp['error']}")
        return resp.get("result", {})

    def _notify(self, method, params=None):
        self.t.send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def initialize(self):
        result = self._rpc("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "ollama-agent", "version": "0"},
        })
        self._notify("notifications/initialized")
        return result

    def list_tools(self):
        return self._rpc("tools/list").get("tools", [])

    def call_tool(self, name, arguments):
        result = self._rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if isinstance(result, dict) and result.get("isError"):
            raise MCPError(f"tool {name} returned isError: {_result_text(result)}")
        return _result_text(result)


def mcp_tools_to_ollama(tools, prefix="mcp"):
    """Map MCP tool descriptors to ollama tool schemas. Names are prefixed
    (mcp__<name>) so they can't collide with the built-in tools, and the schema
    map back to (prefixed_name -> real_name) is returned for dispatch."""
    schemas, name_map = [], {}
    for t in tools:
        real = t["name"]
        prefixed = f"{prefix}__{real}"
        schemas.append({"type": "function", "function": {
            "name": prefixed,
            "description": t.get("description", ""),
            "parameters": t.get("inputSchema") or {"type": "object", "properties": {}},
        }})
        name_map[prefixed] = real
    return schemas, name_map


class StdioMCPTransport:
    """Spawn an MCP server subprocess and exchange newline-delimited JSON-RPC."""

    def __init__(self, command, cwd=None):
        argv = command if isinstance(command, list) else shlex.split(command)
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, cwd=cwd, bufsize=1)

    def send(self, obj):
        if self.proc.stdin is None:
            raise MCPError("server stdin closed")
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def recv(self):
        line = self.proc.stdout.readline() if self.proc.stdout else ""
        if not line:
            raise MCPError("server closed stdout (crashed or exited)")
        return json.loads(line)

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
