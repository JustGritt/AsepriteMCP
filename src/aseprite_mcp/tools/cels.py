"""Cel transforms and recolor (spec section 19).

A 1px idle bob, a mirrored pose or a copied frame would otherwise mean the agent
redrawing every pixel, thousands of output tokens per frame. These make each one
a short call, and a recolor across a whole animation a single call.
"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from ..colors import normalize_color
from .base import ToolContext, as_json
from .drawing import _target
from .inspection import check_region


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Shift cel",
        description=(
            "Move one cel's pixels by dx, dy without redrawing them; positive is right "
            "and down. The cheap way to make a bob, a step or a nudge."
        ),
    )
    async def shift_cel(
        dx: int = 0, dy: int = 0, layer: str | None = None, frame: int | None = None
    ) -> str:
        if dx == 0 and dy == 0:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "dx and dy are both 0: nothing to move.")
        params = {"dx": dx, "dy": dy, **_target(layer, frame)}
        return as_json(await ctx.bridge.call("cel.shift", params))

    @mcp.tool(
        title="Flip cel",
        description=(
            "Mirror one cel horizontally or vertically within the canvas, so a sprite "
            "facing right faces left in the same place."
        ),
    )
    async def flip_cel(
        direction: Literal["horizontal", "vertical"] = "horizontal",
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        params = {"direction": direction, **_target(layer, frame)}
        return as_json(await ctx.bridge.call("cel.flip", params))

    @mcp.tool(
        title="Copy cel",
        description=(
            "Copy one cel's pixels and position to another frame, and optionally another "
            "layer, replacing whatever was there. to_layer defaults to from_layer, "
            "which defaults to the active layer."
        ),
    )
    async def copy_cel(
        from_frame: int,
        to_frame: int,
        from_layer: str | None = None,
        to_layer: str | None = None,
    ) -> str:
        params: dict[str, Any] = {"fromFrame": from_frame, "toFrame": to_frame}
        if from_layer is not None:
            params["fromLayer"] = from_layer
        if to_layer is not None:
            params["toLayer"] = to_layer
        return as_json(await ctx.bridge.call("cel.copy", params))

    @mcp.tool(
        title="Replace color",
        description=(
            "Swap one color for another on a layer, without redrawing. frames is a list "
            "of frame numbers or 'all' (default: the active frame). Optional tolerance "
            "0-255 per RGBA channel and region=[x, y, width, height]. Needs no preview "
            "to trust: the reply counts what changed."
        ),
    )
    async def replace_color(
        from_color: str,
        to_color: str,
        tolerance: int = 0,
        layer: str | None = None,
        frames: list[int] | Literal["all"] | None = None,
        region: list[int] | None = None,
    ) -> str:
        if not 0 <= tolerance <= 255:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS, f"tolerance must be 0-255, got {tolerance}."
            )
        params: dict[str, Any] = {
            "from": normalize_color(from_color),
            "to": normalize_color(to_color),
            "tolerance": tolerance,
        }
        if layer is not None:
            params["layer"] = layer
        if frames is not None:
            if frames != "all" and not frames:
                raise BridgeError(ErrorCode.INVALID_PARAMS, "frames must not be empty.")
            params["frames"] = frames
        area = check_region(region)
        if area is not None:
            params["region"] = area
        return as_json(
            await ctx.bridge.call("cel.replaceColor", params, timeout=ctx.config.render_timeout)
        )
