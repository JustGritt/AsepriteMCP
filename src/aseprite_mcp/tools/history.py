"""Undo and redo (spec section 15).

These drive the native document history. Every mutating command on the Lua side
runs inside a single app.transaction, so one undo reverses exactly one MCP call --
which is the property that makes it safe for the agent to experiment.
"""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from .base import ToolContext, as_json


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Undo",
        description=(
            "Undo the most recent change. Each step reverses exactly one tool call, or one "
            "whole batch."
        ),
    )
    async def undo() -> str:
        return as_json(await ctx.call("history.undo"))

    @mcp.tool(
        title="Redo",
        description="Redo the most recently undone change to the active sprite.",
    )
    async def redo() -> str:
        return as_json(await ctx.call("history.redo"))
