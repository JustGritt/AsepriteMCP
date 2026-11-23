"""Bring an image file into the active sprite as a reference layer (#23).

A master design (a photo, or a generated 1024x1024 image) is worked from, not
converted: reducing it to pixel art automatically came out mushy, while painting
over it as a guide worked. So import_image places it on its own layer, scaled
down by averaging pixels, and can snap it to a palette so get_region reads it as
a grid to trace. The file is read by Aseprite, through fsio.lua.
"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from ..colors import normalize_color
from ..paths import IMAGE_SUFFIXES, resolve_in_sandbox
from .base import ToolContext, as_json

MAX_PALETTE = 256


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Import image",
        description=(
            "Put an image file (PNG, JPEG...) on a reference layer of the active sprite, "
            "centered and scaled to fit, or to width/height, by averaging pixels. transparent "
            "(a hex color, or 'corner') drops a flat background. palette (hex colors, or "
            "'sprite') snaps it so get_region reads it as a grid to trace."
        ),
    )
    async def import_image(
        path: str,
        width: int | None = None,
        height: int | None = None,
        layer: str = "Reference",
        frame: int | None = None,
        palette: list[str] | Literal["sprite"] | None = None,
        transparent: str | None = None,
    ) -> str:
        limit = ctx.config.max_sprite_size
        for name, value in (("width", width), ("height", height)):
            if value is not None and not 1 <= value <= limit:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS, f"{name} must be 1-{limit}, got {value}."
                )
        if not layer.strip():
            raise BridgeError(ErrorCode.INVALID_PARAMS, "layer must name a layer.")
        resolved = resolve_in_sandbox(
            path, ctx.config.allowed_dirs, suffixes=IMAGE_SUFFIXES, must_exist=True
        )
        params: dict[str, Any] = {"path": str(resolved), "layer": layer}
        if width is not None:
            params["width"] = width
        if height is not None:
            params["height"] = height
        if frame is not None:
            params["frame"] = frame
        if palette == "sprite":
            params["palette"] = "sprite"
        elif palette is not None:
            if not palette or len(palette) > MAX_PALETTE:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"palette must list 1-{MAX_PALETTE} colors, or be 'sprite'.",
                )
            params["palette"] = [normalize_color(c) for c in palette]
        if transparent is not None:
            params["transparent"] = (
                "corner" if transparent == "corner" else normalize_color(transparent)
            )
        return as_json(
            await ctx.call("image.import", params, timeout=ctx.config.render_timeout)
        )
