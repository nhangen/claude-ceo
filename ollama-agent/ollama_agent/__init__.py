"""ollama-agent: run a local ollama model as a tool-using agent.

Slice 1 (#186) — the bridge core and the real (non-stub) tool layer. Later
slices add rule loading (#187), skills (#188), an MCP adapter (#189), and a
governed task registry (#190).
"""
from .agent import run_agent
from .mcp import MCPClient, MCPError, StdioMCPTransport, mcp_tools_to_ollama
from .rules import compose_system, load_rule_index, select_rules
from .skills import USE_SKILL_TOOL, get_skill, load_skill_index, render_catalog
from .tools import ToolBox, TOOLS
from .transport import ollama_transport, parse_chat_response

__all__ = ["run_agent", "ToolBox", "TOOLS", "ollama_transport", "parse_chat_response",
           "compose_system", "load_rule_index", "select_rules",
           "USE_SKILL_TOOL", "get_skill", "load_skill_index", "render_catalog",
           "MCPClient", "MCPError", "StdioMCPTransport", "mcp_tools_to_ollama"]
