import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ollama_agent import ToolBox  # noqa: E402
from ollama_agent.mcp import (  # noqa: E402
    MCPClient, MCPError, StdioMCPTransport, mcp_tools_to_ollama, _result_text,
)


class FakeTransport:
    """In-memory JSON-RPC server: send() computes the response, recv() returns it."""

    def __init__(self, tools=None, tool_results=None, error_on=None, is_error_tools=None):
        self.tools = tools or []
        self.tool_results = tool_results or {}
        self.error_on = error_on
        self.is_error_tools = is_error_tools or set()
        self._pending = None
        self.notifications = []

    def send(self, obj):
        if "id" not in obj:
            self.notifications.append(obj["method"])
            return
        method, rid = obj["method"], obj["id"]
        if self.error_on == method:
            self._pending = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "boom"}}
            return
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05"}
        elif method == "tools/list":
            result = {"tools": self.tools}
        elif method == "tools/call":
            name = obj["params"]["name"]
            if name in self.is_error_tools:
                result = {"isError": True, "content": [{"type": "text", "text": "tool blew up"}]}
            else:
                result = self.tool_results.get(name, {"content": [{"type": "text", "text": "ok"}]})
        else:
            result = {}
        self._pending = {"jsonrpc": "2.0", "id": rid, "result": result}

    def recv(self):
        r, self._pending = self._pending, None
        return r


def test_initialize_sends_initialized_notification():
    t = FakeTransport()
    MCPClient(t).initialize()
    assert "notifications/initialized" in t.notifications


def test_list_tools():
    t = FakeTransport(tools=[{"name": "echo", "description": "e"}])
    assert MCPClient(t).list_tools()[0]["name"] == "echo"


def test_call_tool_returns_text():
    t = FakeTransport(tool_results={"echo": {"content": [{"type": "text", "text": "hi there"}]}})
    assert MCPClient(t).call_tool("echo", {"text": "x"}) == "hi there"


def test_call_tool_iserror_raises():
    t = FakeTransport(is_error_tools={"boom"})
    with pytest.raises(MCPError, match="isError"):
        MCPClient(t).call_tool("boom", {})


def test_rpc_error_member_raises():
    t = FakeTransport(error_on="tools/list")
    with pytest.raises(MCPError, match="tools/list"):
        MCPClient(t).list_tools()


def test_result_text_falls_back_to_raw():
    assert _result_text({"weird": 1}) == {"weird": 1}


def test_mcp_tools_to_ollama_prefixes_and_maps():
    schemas, name_map = mcp_tools_to_ollama(
        [{"name": "read_file", "description": "d", "inputSchema": {"type": "object", "properties": {"p": {}}}}])
    assert schemas[0]["function"]["name"] == "mcp__read_file"
    assert schemas[0]["function"]["parameters"]["properties"] == {"p": {}}
    assert name_map == {"mcp__read_file": "read_file"}


def test_mcp_tools_to_ollama_default_schema_when_missing():
    schemas, _ = mcp_tools_to_ollama([{"name": "noargs"}])
    assert schemas[0]["function"]["parameters"] == {"type": "object", "properties": {}}


# --- ToolBox MCP dispatch ---

class FakeClient:
    def __init__(self, raises=False):
        self.raises = raises
        self.calls = []

    def call_tool(self, name, args):
        self.calls.append((name, args))
        if self.raises:
            raise MCPError("server down")
        return f"result of {name}({args})"


def test_toolbox_dispatches_mcp_tool(tmp_path):
    client = FakeClient()
    tb = ToolBox(cwd=tmp_path, mcp_client=client, mcp_names={"mcp__echo": "echo"})
    out = json.loads(tb.dispatch("mcp__echo", {"text": "hi"}))
    assert client.calls == [("echo", {"text": "hi"})]
    assert "result of echo" in out["result"]


def test_toolbox_mcp_error_recorded_not_crash(tmp_path):
    tb = ToolBox(cwd=tmp_path, mcp_client=FakeClient(raises=True), mcp_names={"mcp__echo": "echo"})
    out = json.loads(tb.dispatch("mcp__echo", {}))
    assert "error" in out and "MCPError" in out["error"]


def test_toolbox_unknown_mcp_name_still_unknown(tmp_path):
    tb = ToolBox(cwd=tmp_path, mcp_client=FakeClient(), mcp_names={"mcp__echo": "echo"})
    out = json.loads(tb.dispatch("mcp__not_a_tool", {}))
    assert "unknown tool" in out["error"] and tb.unknown_calls == ["mcp__not_a_tool"]


# --- real subprocess integration ---

_SERVER = r'''
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if "id" not in msg:        # notification
        continue
    m, rid = msg["method"], msg["id"]
    if m == "initialize":
        res = {"protocolVersion": "2024-11-05"}
    elif m == "tools/list":
        res = {"tools": [{"name": "echo", "description": "echo text",
                          "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
    elif m == "tools/call":
        txt = msg["params"]["arguments"].get("text", "")
        res = {"content": [{"type": "text", "text": "echo: " + txt}]}
    else:
        res = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": res}) + "\n")
    sys.stdout.flush()
'''


def test_stdio_transport_real_subprocess_roundtrip(tmp_path):
    server = tmp_path / "fake_mcp_server.py"
    server.write_text(_SERVER)
    transport = StdioMCPTransport([sys.executable, str(server)])
    try:
        client = MCPClient(transport)
        client.initialize()
        tools = client.list_tools()
        assert tools[0]["name"] == "echo"
        assert client.call_tool("echo", {"text": "hello"}) == "echo: hello"
    finally:
        transport.close()


def test_stdio_transport_recv_on_dead_server_raises(tmp_path):
    server = tmp_path / "exits.py"
    server.write_text("import sys; sys.exit(0)")
    transport = StdioMCPTransport([sys.executable, str(server)])
    with pytest.raises(MCPError, match="closed stdout"):
        transport.recv()
    transport.close()
