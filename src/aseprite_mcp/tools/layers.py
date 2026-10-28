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

# Appended to every tool that takes a layer reference, so the agent learns the
# addressing rule from whichever tool it reads first.
_LAYER_ARG = " Pass layer as an id from get_sprite_info (stable across renames) or an exact name."


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Select layer",
        description=(
            "Make a layer the active one, so subsequent drawing lands on it." + _LAYER_ARG
        ),
    )
    async def select_layer(layer: str) -> str:
        return as_json(await ctx.bridge.call("layer.select", {"layer": layer}))

    @mcp.tool(
        title="Create layer",
        description=(
            "Create a normal image layer above the active one and select it. Returns "
            "the new layer id."
        ),
    )
    async def create_layer(name: str) -> str:
        return as_json(await ctx.bridge.call("layer.create", {"name": name}))

    @mcp.tool(
        title="Delete layer",
        description=(
            "Delete a layer and all of its cels. Undoable with the undo tool, but "
            "confirm with the user first if the layer holds work you did not create."
            + _LAYER_ARG
        ),
    )
    async def delete_layer(layer: str) -> str:
        return as_json(await ctx.bridge.call("layer.delete", {"layer": layer}))

    @mcp.tool(
        title="Set layer visibility",
        description=(
            "Show or hide a layer. Useful for isolating a component before rendering a "
            "preview, but remember to restore visibility afterwards."
            + _LAYER_ARG
        ),
    )
    async def set_layer_visibility(layer: str, visible: bool) -> str:
        return as_json(
            await ctx.bridge.call("layer.setVisibility", {"layer": layer, "visible": visible})
        )
