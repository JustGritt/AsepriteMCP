"""Drawing tools (spec section 11).

The API is built around batches. Spec section 11 is explicit that the agent must
never be forced into one MCP call per pixel, so draw_pixels takes an arbitrarily
large array and fill / draw_line / draw_rect cover regions and runs without
enumerating them.

Tool arguments are written by the model, so they cost output tokens -- the most
expensive kind. One JSON object per pixel runs to 10-20 tokens a pixel, which is
why draw_rows exists: the same character-map format get_region reads back, at
roughly a token for every few pixels.

Every call targets one cel: the active layer and frame unless overridden. The Lua
side expands the cel when pixels fall outside its current bounds, so drawing near
the edge of a sprite does not silently clip.
"""

from __future__ import annotations

from typing import Any, Literal

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


# Characters draw_rows reserves, matching what get_region emits.
TRANSPARENT = "."
OUTSIDE = " "


def _resolve_legend(legend: dict[str, str | int]) -> dict[str, dict[str, Any]]:
    """Validate a draw_rows legend into the color/index spec draw.pixels takes."""
    if not legend:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "legend must map at least one character.")
    resolved: dict[str, dict[str, Any]] = {}
    for char, value in legend.items():
        if len(char) != 1 or char in (TRANSPARENT, OUTSIDE):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"Legend key {char!r} must be one character other than '.' and ' ', "
                "which always mean transparent and skip.",
            )
        if isinstance(value, int) and not isinstance(value, bool):
            resolved[char] = {"index": value}
        else:
            resolved[char] = {"color": normalize_color(value)}
    return resolved


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
            "Write a batch of individual pixels to one cel. Best for a few scattered "
            "pixels: for anything denser use draw_rows, which costs a fraction of the "
            "tokens, and for runs and regions use draw_line, draw_rect or fill. Drawing "
            "outside the current cel bounds expands the cel rather than clipping."
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
        title="Draw rows",
        description=(
            "Write pixels as a character map, the same rows-and-legend format get_region "
            "returns, so you can read a region, edit it and write it back. Row 0 lands at "
            "y and column 0 at x. legend maps each character to a hex color, or to a "
            "palette index on indexed sprites; omit it to reuse the previous draw_rows "
            "legend. '.' is transparent: blank='skip' leaves those pixels as they are, "
            "blank='erase' clears them. ' ' is always skipped. Use this for any shape "
            "denser than a few pixels; it costs a fraction of draw_pixels."
        ),
    )
    async def draw_rows(
        x: int,
        y: int,
        rows: list[str],
        legend: dict[str, str | int] | None = None,
        blank: Literal["skip", "erase"] = "skip",
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        reused = legend is None
        if reused:
            if ctx.last_legend is None:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    "legend is required: there is no earlier draw_rows legend to reuse.",
                )
            legend = ctx.last_legend
        resolved = _resolve_legend(legend)

        encoded: list[dict[str, Any]] = []
        for row_index, row in enumerate(rows):
            for col, char in enumerate(row):
                if char == OUTSIDE:
                    continue
                if char == TRANSPARENT:
                    if blank == "erase":
                        encoded.append({"x": x + col, "y": y + row_index, "erase": True})
                    continue
                spec = resolved.get(char)
                if spec is None:
                    raise BridgeError(
                        ErrorCode.INVALID_PARAMS,
                        f"rows[{row_index}][{col}] is {char!r}, which is not in the legend "
                        f"({''.join(sorted(resolved))}).",
                    )
                encoded.append({"x": x + col, "y": y + row_index, **spec})

        if not encoded:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                "rows hold nothing to draw: every character is '.' or ' '. "
                "Pass blank='erase' to clear the '.' pixels.",
            )
        _check_batch(len(encoded))
        ctx.last_legend = legend

        params = {"pixels": encoded, **_target(layer, frame)}
        result = await ctx.bridge.call("draw.pixels", params, timeout=ctx.config.render_timeout)
        if reused:
            result["legend"] = "reused"
        return as_json(result)

    @mcp.tool(
        title="Draw rectangle",
        description=(
            "Draw a rectangle with its top-left corner at x, y: filled by default, or a "
            "1px outline with filled=false."
        ),
    )
    async def draw_rect(
        x: int,
        y: int,
        width: int,
        height: int,
        color: str,
        filled: bool = True,
        layer: str | None = None,
        frame: int | None = None,
    ) -> str:
        if width <= 0 or height <= 0:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"width and height must be positive, got {width}x{height}.",
            )
        value = normalize_color(color)
        right, bottom = x + width - 1, y + height - 1
        points = [
            {"x": px, "y": py, "color": value}
            for py in range(y, bottom + 1)
            for px in range(x, right + 1)
            if filled or px in (x, right) or py in (y, bottom)
        ]
        _check_batch(len(points))
        params = {"pixels": points, **_target(layer, frame)}
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
