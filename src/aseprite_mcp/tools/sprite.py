"""Sprite-level tools (spec section 8)."""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..paths import OPEN_SUFFIXES, SAVE_SUFFIXES, resolve_in_sandbox
from .base import ToolContext, as_json


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get sprite info",
        description=(
            "The whole open document in one call: size, color mode, palette size, active "
            "frame and layer, every layer (id, name, non-default flags), each frame's "
            "duration in ms (frameMs[0] is frame 1) and every tag. Call it once before "
            "editing."
        ),
    )
    async def get_sprite_info() -> str:
        return as_json(await ctx.call("sprite.info"))

    @mcp.tool(
        title="Open sprite",
        description=(
            "Open a .aseprite, .ase or .png file inside an allowed directory and make it "
            "active. Relative paths resolve against the first allowed directory."
        ),
    )
    async def open_sprite(path: str) -> str:
        resolved = resolve_in_sandbox(
            path, ctx.config.allowed_dirs, suffixes=OPEN_SUFFIXES, must_exist=True
        )
        return as_json(await ctx.call("sprite.open", {"path": str(resolved)}))

    @mcp.tool(
        title="Save sprite",
        description=(
            "Save the active sprite over its file, or to path: a .aseprite or .ase file "
            "inside an allowed directory, so layers are never flattened."
        ),
    )
    async def save_sprite(path: str | None = None) -> str:
        params: dict[str, object] = {}
        if path:
            resolved = resolve_in_sandbox(path, ctx.config.allowed_dirs, suffixes=SAVE_SUFFIXES)
            resolved.parent.mkdir(parents=True, exist_ok=True)
            params["path"] = str(resolved)
        return as_json(await ctx.call("sprite.save", params, timeout=ctx.config.render_timeout))
