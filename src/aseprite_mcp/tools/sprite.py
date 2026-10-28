"""Sprite-level tools (spec section 8)."""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..paths import OPEN_SUFFIXES, SAVE_SUFFIXES, resolve_in_sandbox
from .base import ToolContext, as_json


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get sprite info",
        description=(
            "Describe the open sprite in one call: size, color mode, palette size, the "
            "active frame and layer, every layer (id, name, and any non-default type, "
            "visibility, lock, opacity or nesting), every frame's duration in ms "
            "(frameMs[0] is frame 1) and every tag. Call it once before editing rather "
            "than assuming the document structure."
        ),
    )
    async def get_sprite_info() -> str:
        return as_json(await ctx.bridge.call("sprite.info"))

    @mcp.tool(
        title="Open sprite",
        description=(
            "Open a sprite file in Aseprite and make it the active document. The path "
            "must sit inside an allowed directory; relative paths are resolved against "
            "the first one. Accepts .aseprite, .ase and .png."
        ),
    )
    async def open_sprite(path: str) -> str:
        resolved = resolve_in_sandbox(
            path, ctx.config.allowed_dirs, suffixes=OPEN_SUFFIXES, must_exist=True
        )
        return as_json(await ctx.bridge.call("sprite.open", {"path": str(resolved)}))

    @mcp.tool(
        title="Save sprite",
        description=(
            "Save the active sprite. With no path it saves over the file it came from. "
            "Pass a path to save elsewhere inside an allowed directory; only .aseprite "
            "and .ase are accepted, so a layered source file is never flattened."
        ),
    )
    async def save_sprite(path: str | None = None) -> str:
        params: dict[str, object] = {}
        if path:
            resolved = resolve_in_sandbox(path, ctx.config.allowed_dirs, suffixes=SAVE_SUFFIXES)
            resolved.parent.mkdir(parents=True, exist_ok=True)
            params["path"] = str(resolved)
        return as_json(await ctx.bridge.call("sprite.save", params, timeout=ctx.config.render_timeout))
