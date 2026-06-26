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
import select
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
        # Correlate the response to this request id. A server may interleave a
        # notification/log frame (no id) before the reply; skip those (bounded, so
        # a notification flood can't loop forever), and treat a mismatched id as a
        # protocol desync rather than silently returning the wrong call's result.
        for _ in range(100):
            resp = self.t.recv()
            if not isinstance(resp, dict):
                raise MCPError(f"{method}: non-object response {resp!r}")
            if "id" not in resp:
                continue
            if resp["id"] != self._id:
                raise MCPError(f"{method}: response id {resp['id']} != request {self._id}")
            break
        else:
            raise MCPError(f"{method}: no response with id {self._id} after 100 frames")
        if "error" in resp:
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

    def __init__(self, command, cwd=None, timeout=30):
        argv = command if isinstance(command, list) else shlex.split(command)
        self.timeout = timeout
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, cwd=cwd, bufsize=1)

    def send(self, obj):
        if self.proc.stdin is None:
            raise MCPError("server stdin closed")
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def recv(self):
        # Bound the read: a server that is alive but never writes a response would
        # otherwise block readline() forever and hang the whole agent (the sibling
        # ollama_transport bounds its read for the same reason). select on the pipe
        # surfaces a stuck server as a typed error instead of a silent hang.
        if not self.proc.stdout:
            raise MCPError("server has no stdout")
        ready, _, _ = select.select([self.proc.stdout], [], [], self.timeout)
        if not ready:
            raise MCPError(f"server did not respond within {self.timeout}s")
        line = self.proc.stdout.readline()
        if not line:
            raise MCPError("server closed stdout (crashed or exited)")
        return json.loads(line)

    def close(self):
        # Runs in a finally; must never raise, and must reap the process even when
        # it ignores SIGTERM (otherwise a zombie lingers).
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
                self.proc.wait(timeout=5)
            except Exception:
                pass
