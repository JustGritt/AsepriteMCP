"""MCP server wiring: build the server, start the bridge, register the tools."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from mcp.server.mcpserver import MCPServer

from .bridge.ws_server import AsepriteBridge
from .config import Config
from .tools import animation, connection, drawing, frames, history, inspection, layers, sprite
from .tools.base import ToolContext

log = logging.getLogger(__name__)

# Shown to the client as server-level guidance. This is where the workflow from
# docs/ASEPRITE_MCP.md section 17 lives, so the agent inherits it without the
# user having to restate it in every prompt.
INSTRUCTIONS = """\
Drive a live Aseprite session to create and edit pixel-art sprites and animations.

Work in a loop: EDIT -> PREVIEW -> ANALYZE -> CORRECT. A command returning ok is
not evidence that the result looks right; only looking at a preview is.

Before editing, inspect the document rather than assuming its structure:
get_sprite_info, list_layers, list_frames, list_animation_tags, get_palette.

After a substantial edit, call get_canvas_preview and actually look at it. After
changing several animation frames, call get_animation_contact_sheet and
get_onion_skin_preview to judge motion arcs, spacing, volume consistency and
pixel jitter across frames.

Prefer duplicate_frame followed by a targeted change over redrawing a pose from
scratch. Prefer batching pixels into one draw_pixels call over many small calls.
Reuse existing palette colors instead of introducing near-duplicates.

Each tool call is one native undo step, so undo reverses exactly one call.
"""


def build_server(config: Config | None = None) -> tuple[MCPServer, ToolContext]:
    """Construct the server and its tool context.

    Returned as a pair so tests can reach the context (and therefore the bridge)
    without going through the MCP transport.
    """
    config = config or Config.from_env()
    bridge = AsepriteBridge(config)
    ctx = ToolContext(bridge=bridge, config=config)

    @asynccontextmanager
    async def lifespan(_server: MCPServer):
        await bridge.start()
        try:
            yield ctx
        finally:
            await bridge.stop()
            ctx.cleanup()

    mcp = MCPServer(
        name="aseprite",
        version="0.1.0",
        instructions=INSTRUCTIONS,
        lifespan=lifespan,
        log_level=config.log_level,
    )

    for module in (connection, sprite, layers, frames, drawing, inspection, animation, history):
        module.register(mcp, ctx)

    return mcp, ctx
