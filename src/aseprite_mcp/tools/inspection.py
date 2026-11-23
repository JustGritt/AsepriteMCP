"""Image inspection (spec section 12).

Spec section 2.2 makes visual verification mandatory: a command returning ok is
not evidence that the result looks right. These are the tools that close that
loop, so they matter more than their count suggests.

get_frame_preview from the spec is deliberately absent -- it is exactly
get_canvas_preview(frame=N), and section 2.3 asks for reusable primitives over
specialized commands. The same goes for get_layer_preview, which is
get_canvas_preview(layer=...).

An image costs the model about width*height/750 tokens and stays in its context
for the rest of the session, so every render carries a long-edge cap
(Config.preview_max_edge) and region lets the agent zoom into the part it cares
about instead of paying for the whole canvas at a high scale. An image the agent
already has is replaced by one line of text (ToolContext.image_or_note).
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import Image, MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from .base import ToolContext, as_json, render_to_image

MIN_SCALE = 1
MAX_SCALE = 32


def check_scale(scale: int) -> None:
    if not MIN_SCALE <= scale <= MAX_SCALE:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS, f"scale must be {MIN_SCALE}-{MAX_SCALE}, got {scale}."
        )


def check_region(region: list[int] | None) -> dict[str, int] | None:
    if region is None:
        return None
    if len(region) != 4 or region[2] <= 0 or region[3] <= 0:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"region must be [x, y, width, height] with a positive size, got {region}.",
        )
    x, y, width, height = region
    return {"x": x, "y": y, "width": width, "height": height}


def describe(result: dict[str, Any]) -> str:
    """Summarise a render so the agent knows exactly what it is looking at."""
    parts = []
    if "frame" in result:
        parts.append(f"frame {result['frame']}")
    if "layer" in result:
        parts.append(f"layer {result['layer']!r}")
    if result.get("region"):
        x, y, width, height = result["region"]
        parts.append(f"region {x},{y} {width}x{height}")
    elif "width" in result and "height" in result:
        parts.append(f"{result['width']}x{result['height']} source")
    if result.get("scale"):
        parts.append(f"scaled {result['scale']}x nearest-neighbour")
    if result.get("scaleReduced"):
        parts.append(
            f"(scale reduced from {result['requestedScale']} to stay within the size cap; "
            "pass region to zoom)"
        )
    if result.get("empty"):
        parts.append("WARNING: the rendered area is entirely transparent")
    return ", ".join(parts) if parts else "rendered"


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get canvas preview",
        description=(
            "Render the sprite, or one layer, as a PNG to look at. region=[x, y, width, "
            "height] zooms in; a draw reply's changed box is a ready-made region. Large "
            "renders are capped in size, so zoom rather than raising scale."
        ),
    )
    async def get_canvas_preview(
        scale: int = 8,
        frame: int | None = None,
        layer: str | None = None,
        region: list[int] | None = None,
    ) -> list[Image | str]:
        check_scale(scale)
        params: dict[str, Any] = {"scale": scale, "maxEdge": ctx.config.preview_max_edge}
        if frame is not None:
            params["frame"] = frame
        if layer is not None:
            params["layer"] = layer
        area = check_region(region)
        if area is not None:
            params["region"] = area
        command = "render.layer" if layer is not None else "render.canvas"
        image, result = await render_to_image(ctx, command, params)
        label = describe(result)
        return [ctx.image_or_note(image, label), label]

    @mcp.tool(
        title="Get region pixels",
        description=(
            "Exact pixels as rows of characters: '.' is transparent, ' ' is off-canvas, and "
            "legend maps the rest to colors. Cheaper than a preview for exact checks; "
            "draw_rows writes the same format. by_layer labels pixels by layer instead."
        ),
    )
    async def get_region(
        x: int,
        y: int,
        width: int,
        height: int,
        frame: int | None = None,
        layer: str | None = None,
        by_layer: bool = False,
    ) -> str:
        if width <= 0 or height <= 0:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"width and height must be positive, got {width}x{height}.",
            )
        if width * height > ctx.config.max_region_pixels:
            raise BridgeError(
                ErrorCode.TOO_MANY_PIXELS,
                f"{width}x{height} is {width * height} pixels, over the limit of "
                f"{ctx.config.max_region_pixels}. Request a smaller rectangle, or use "
                "get_canvas_preview to judge a large area visually.",
            )
        params: dict[str, Any] = {"x": x, "y": y, "width": width, "height": height}
        if frame is not None:
            params["frame"] = frame
        if by_layer:
            if layer is not None:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    "by_layer labels every visible layer, so it takes no layer.",
                )
            params["byLayer"] = True
        if layer is not None:
            params["layer"] = layer
        return as_json(await ctx.call("inspect.region", params))

    @mcp.tool(
        title="Get palette",
        description=(
            "The palette's colors in index order. Reuse them rather than adding "
            "near-duplicates."
        ),
    )
    async def get_palette() -> str:
        return as_json(await ctx.call("inspect.palette"))
