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
            "Undo the most recent change to the active sprite using Aseprite native "
            "history. One call reverses one previous tool call. Preview afterwards to "
            "confirm the document is back in the state you expected."
        ),
    )
    async def undo() -> str:
        return as_json(await ctx.bridge.call("history.undo"))

    @mcp.tool(
        title="Redo",
        description="Redo the most recently undone change to the active sprite.",
    )
    async def redo() -> str:
        return as_json(await ctx.bridge.call("history.redo"))
