"""Drawing tools (spec section 11).

The API is built around batches. Spec section 11 is explicit that the agent must
never be forced into one MCP call per pixel, so draw_pixels takes an arbitrarily
large array and fill / draw_line cover regions and runs without enumerating them.

Every call targets one cel: the active layer and frame unless overridden. The Lua
side expands the cel when pixels fall outside its current bounds, so drawing near
the edge of a sprite does not silently clip.
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer
from pydantic import BaseModel, Field

from ..bridge.protocol import BridgeError, ErrorCode
from ..colors import normalize_color
from .base import ToolContext, as_json


class PixelSpec(BaseModel):
    """One pixel to write."""

    x: int = Field(description="Column, 0-based, measured from the left of the sprite.")
    y: int = Field(description="Row, 0-based, measured from the top of the sprite.")
    color: str | None = Field(
        default=None,
        description=(
            "Hex color such as #E6A15C or #E6A15CFF. Omit to use the color argument "
            "shared by the whole batch."
        ),
    )
    index: int | None = Field(
        default=None,
        description=(
            "Palette index, for indexed sprites only. Takes precedence over color and "
            "guarantees an exact palette match rather than a nearest-color snap."
        ),
    )


class PointSpec(BaseModel):
    x: int
    y: int


def _target(layer: str | None, frame: int | None) -> dict[str, Any]:
    """The layer/frame selector shared by every drawing command."""
    target: dict[str, Any] = {}
    if layer is not None:
        target["layer"] = layer
    if frame is not None:
        target["frame"] = frame
    return target


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    def _check_batch(count: int) -> None:
        if count == 0:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "No pixels were supplied.")
        if count > ctx.config.max_pixels_per_call:
            raise BridgeError(
                ErrorCode.TOO_MANY_PIXELS,
                f"{count} pixels exceeds the per-call limit of "
                f"{ctx.config.max_pixels_per_call}. Split the edit into several calls, "
                "or use fill or draw_line to cover large areas.",
            )

    @mcp.tool(
        title="Draw pixels",
        description=(
            "Write a batch of pixels to one cel. Send as many pixels as the edit needs "
            "in a single call rather than many small calls. For a solid run of pixels "
            "prefer draw_line, and for a connected region prefer fill. Drawing outside "
            "the current cel bounds expands the cel rather than clipping."
        ),
    )
    async def draw_pixels(
        pixels: list[PixelSpec],
        color: str | None = None,
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        _check_batch(len(pixels))
        default = normalize_color(color) if color else None

        encoded: list[dict[str, Any]] = []
        for i, pixel in enumerate(pixels):
            if pixel.index is not None:
                encoded.append({"x": pixel.x, "y": pixel.y, "index": pixel.index})
                continue
            raw = pixel.color or color
            if raw is None:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"pixels[{i}] has no color and no batch-level color was given.",
                )
            encoded.append(
                {
                    "x": pixel.x,
                    "y": pixel.y,
                    "color": normalize_color(pixel.color) if pixel.color else default,
                }
            )

        params = {"pixels": encoded, **_target(layer, frame)}
        return as_json(await ctx.bridge.call("draw.pixels", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Erase pixels",
        description=(
            "Make a batch of pixels fully transparent in one cel. Equivalent to drawing "
            "a transparent color, but clearer about intent."
        ),
    )
    async def erase_pixels(
        pixels: list[PointSpec],
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        _check_batch(len(pixels))
        params = {
            "pixels": [{"x": p.x, "y": p.y} for p in pixels],
            **_target(layer, frame),
        }
        return as_json(await ctx.bridge.call("draw.erase", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Clear cel",
        description="Erase the entire contents of one cel, leaving the frame empty on that layer.",
    )
    async def clear_cel(layer: str | None = None, frame: int | None = None) -> str:
        return as_json(await ctx.bridge.call("draw.clearCel", _target(layer, frame)))

    @mcp.tool(
        title="Flood fill",
        description=(
            "Flood-fill the connected region of matching color that contains the given "
            "point. Tolerance is 0-255 and defaults to an exact color match."
        ),
    )
    async def fill(
        x: int,
        y: int,
        color: str,
        tolerance: int = 0,
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        if not 0 <= tolerance <= 255:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS, f"tolerance must be 0-255, got {tolerance}."
            )
        params = {
            "x": x,
            "y": y,
            "color": normalize_color(color),
            "tolerance": tolerance,
            **_target(layer, frame),
        }
        return as_json(await ctx.bridge.call("draw.fill", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Draw line",
        description=(
            "Draw a 1px Bresenham line between two points. Much cheaper than "
            "enumerating the same pixels through draw_pixels."
        ),
    )
    async def draw_line(
        x1: int,
        y1: int,
        x2: int,
        y2: int,
        color: str,
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        params = {
            "x1": x1,
            "y1": y1,
            "x2": x2,
            "y2": y2,
            "color": normalize_color(color),
            **_target(layer, frame),
        }
        return as_json(await ctx.bridge.call("draw.line", params, timeout=ctx.config.render_timeout))
