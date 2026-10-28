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
            "Move a cel's pixels by dx, dy (positive is right and down) without redrawing "
            "them, e.g. for a bob."
        ),
    )
    async def shift_cel(
        dx: int = 0, dy: int = 0, layer: str | None = None, frame: int | None = None
    ) -> str:
        if dx == 0 and dy == 0:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "dx and dy are both 0: nothing to move.")
        params = {"dx": dx, "dy": dy, **_target(layer, frame)}
        return as_json(await ctx.call("cel.shift", params))

    @mcp.tool(
        title="Flip cel",
        description="Mirror a cel horizontally or vertically within the canvas, keeping its place.",
    )
    async def flip_cel(
        direction: Literal["horizontal", "vertical"] = "horizontal",
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        params = {"direction": direction, **_target(layer, frame)}
        return as_json(await ctx.call("cel.flip", params))

    @mcp.tool(
        title="Copy cel",
        description=(
            "Copy a cel to another frame, and optionally another layer, replacing what is "
            "there."
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
        return as_json(await ctx.call("cel.copy", params))

    @mcp.tool(
        title="Replace color",
        description=(
            "Swap one color for another on a layer. frames is a list or 'all' (default: "
            "active frame). Optional tolerance 0-255 and region [x, y, width, height]."
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
            await ctx.call("cel.replaceColor", params, timeout=ctx.config.render_timeout)
        )
