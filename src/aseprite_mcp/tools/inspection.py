"""Image inspection (spec section 12).

Spec section 2.2 makes visual verification mandatory: a command returning ok is
not evidence that the result looks right. These are the tools that close that
loop, so they matter more than their count suggests.

get_frame_preview from the spec is deliberately absent -- it is exactly
get_canvas_preview(frame=N), and section 2.3 asks for reusable primitives over
specialized commands.
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


def describe(result: dict[str, Any]) -> str:
    """Summarise a render so the agent knows exactly what it is looking at."""
    parts = []
    if "frame" in result:
        parts.append(f"frame {result['frame']}")
    if "layer" in result:
        parts.append(f"layer {result['layer']!r}")
    if "width" in result and "height" in result:
        parts.append(f"{result['width']}x{result['height']} source")
    if result.get("scale"):
        parts.append(f"scaled {result['scale']}x nearest-neighbour")
    if result.get("scaleReduced"):
        parts.append(
            f"(scale reduced from {result['requestedScale']} to stay within the size limit)"
        )
    if result.get("empty"):
        parts.append("WARNING: the rendered area is entirely transparent")
    return ", ".join(parts) if parts else "rendered"


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get canvas preview",
        description=(
            "Render the composited sprite as a PNG and return it as an image to look at. "
            "Scaled with nearest-neighbour so pixel edges stay hard. Defaults to the "
            "active frame; pass frame to preview a specific one. Call this after every "
            "substantial edit and actually inspect the result."
        ),
    )
    async def get_canvas_preview(scale: int = 8, frame: int | None = None) -> list[Image | str]:
        check_scale(scale)
        params: dict[str, Any] = {"scale": scale}
        if frame is not None:
            params["frame"] = frame
        image, result = await render_to_image(ctx, "render.canvas", params)
        return [image, describe(result)]

    @mcp.tool(
        title="Get layer preview",
        description=(
            "Render a single layer on its own, ignoring every other layer. Useful for "
            "debugging one sprite component without disturbing layer visibility. The "
            "layer argument is a uuid from list_layers or an exact layer name."
        ),
    )
    async def get_layer_preview(
        layer: str, scale: int = 8, frame: int | None = None
    ) -> list[Image | str]:
        check_scale(scale)
        params: dict[str, Any] = {"scale": scale, "layer": layer}
        if frame is not None:
            params["frame"] = frame
        image, result = await render_to_image(ctx, "render.layer", params)
        return [image, describe(result)]

    @mcp.tool(
        title="Get region pixels",
        description=(
            "Read exact pixel values for a rectangle, as a compact character map plus a "
            "legend of the colors used. Use this when you need certainty about specific "
            "pixels or colors rather than visual impression."
        ),
    )
    async def get_region(
        x: int,
        y: int,
        width: int,
        height: int,
        frame: int | None = None,
        layer: str | None = None,
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
        if layer is not None:
            params["layer"] = layer
        return as_json(await ctx.bridge.call("inspect.region", params))

    @mcp.tool(
        title="Get palette",
        description=(
            "List the palette of the active sprite as index and hex color. Read this "
            "before drawing so you reuse existing colors instead of introducing "
            "near-duplicates, and so you can address indexed sprites by index."
        ),
    )
    async def get_palette() -> str:
        return as_json(await ctx.bridge.call("inspect.palette"))
