"""Frame tools (spec section 10).

Frames are addressed by 1-based index, matching how Aseprite numbers them in the
timeline. Durations are milliseconds everywhere on this side of the wire; the Lua
side converts to and from the seconds that Aseprite actually stores.
"""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from .base import ToolContext, as_json

# Aseprite stores duration as a float in seconds, so 1ms is the practical floor
# and anything beyond a few seconds per frame is almost certainly a unit mistake.
MIN_DURATION_MS = 1
MAX_DURATION_MS = 65_535


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Select frame",
        description="Make a frame the active one, so tools that omit frame target it.",
    )
    async def select_frame(frame: int) -> str:
        return as_json(await ctx.call("frame.select", {"frame": frame}))

    @mcp.tool(
        title="Create frame",
        description=(
            "Insert an empty frame after `after`, or at the end. To animate, prefer "
            "duplicate_frame."
        ),
    )
    async def create_frame(after: int | None = None) -> str:
        params = {} if after is None else {"after": after}
        return as_json(await ctx.call("frame.create", params))

    @mcp.tool(
        title="Duplicate frame",
        description=(
            "Copy a frame and all its cels to frame + 1: the usual way to start the next "
            "pose."
        ),
    )
    async def duplicate_frame(frame: int) -> str:
        return as_json(await ctx.call("frame.duplicate", {"frame": frame}))

    @mcp.tool(
        title="Delete frame",
        description="Delete a frame; later frames shift down by one. Undoable.",
    )
    async def delete_frame(frame: int) -> str:
        return as_json(await ctx.call("frame.delete", {"frame": frame}))

    @mcp.tool(
        title="Set frame duration",
        description=(
            "Set how long a frame is held, in milliseconds (1-65535). Timing is part of the "
            "animation."
        ),
    )
    async def set_frame_duration(frame: int, duration_ms: int) -> str:
        if not MIN_DURATION_MS <= duration_ms <= MAX_DURATION_MS:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"duration_ms must be between {MIN_DURATION_MS} and {MAX_DURATION_MS}; "
                f"got {duration_ms}. This value is in milliseconds, not seconds.",
            )
        return as_json(
            await ctx.call(
                "frame.setDuration", {"frame": frame, "durationMs": duration_ms}
            )
        )
