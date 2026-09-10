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
        title="List frames",
        description=(
            "List every frame with its 1-based index, duration in milliseconds and the "
            "tags covering it."
        ),
    )
    async def list_frames() -> str:
        return as_json(await ctx.bridge.call("frame.list"))

    @mcp.tool(
        title="Select frame",
        description="Make a frame the active one, so subsequent drawing lands on it.",
    )
    async def select_frame(frame: int) -> str:
        return as_json(await ctx.bridge.call("frame.select", {"frame": frame}))

    @mcp.tool(
        title="Create frame",
        description=(
            "Insert an empty frame after the given frame, or at the end when frame is "
            "omitted. Prefer duplicate_frame when animating from an existing pose."
        ),
    )
    async def create_frame(after: int | None = None) -> str:
        params = {} if after is None else {"after": after}
        return as_json(await ctx.bridge.call("frame.create", params))

    @mcp.tool(
        title="Duplicate frame",
        description=(
            "Copy a frame, including its cels on every layer, and insert the copy "
            "directly after it. This is the main way to build an animation: duplicate "
            "the previous pose, then make a targeted change to the copy."
        ),
    )
    async def duplicate_frame(frame: int) -> str:
        return as_json(await ctx.bridge.call("frame.duplicate", {"frame": frame}))

    @mcp.tool(
        title="Delete frame",
        description="Delete a frame and shift later frames down. Undoable.",
    )
    async def delete_frame(frame: int) -> str:
        return as_json(await ctx.bridge.call("frame.delete", {"frame": frame}))

    @mcp.tool(
        title="Set frame duration",
        description=(
            "Set how long a frame is held, in milliseconds. Timing is part of the "
            "animation: do not assume every frame should have the same duration."
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
            await ctx.bridge.call(
                "frame.setDuration", {"frame": frame, "durationMs": duration_ms}
            )
        )
