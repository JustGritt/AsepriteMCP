"""Layer tools (spec section 9).

Layers are addressed by the stable ``uuid`` Aseprite assigns them, which is what
spec section 9 asks for when it says to avoid relying solely on names. The
agent sees and types an 8-character prefix of it (the ``id`` get_sprite_info
reports), because a full uuid is 36 characters of output on every call. Names
are accepted as a fallback and rejected when ambiguous.
"""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from .base import ToolContext, as_json


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Select layer",
        description="Make a layer the active one, so tools that omit layer target it.",
    )
    async def select_layer(layer: str) -> str:
        return as_json(await ctx.call("layer.select", {"layer": layer}))

    @mcp.tool(
        title="Create layer",
        description="Add an image layer above the active one, select it and return its id.",
    )
    async def create_layer(name: str) -> str:
        return as_json(await ctx.call("layer.create", {"name": name}))

    @mcp.tool(
        title="Delete layer",
        description=(
            "Delete a layer and its cels (undoable). Ask the user first if it holds work "
            "you did not create."
        ),
    )
    async def delete_layer(layer: str) -> str:
        return as_json(await ctx.call("layer.delete", {"layer": layer}))

    @mcp.tool(
        title="Set layer visibility",
        description=(
            "Show or hide a layer, e.g. to isolate one before a preview. Restore it "
            "afterwards."
        ),
    )
    async def set_layer_visibility(layer: str, visible: bool) -> str:
        return as_json(
            await ctx.call("layer.setVisibility", {"layer": layer, "visible": visible})
        )
