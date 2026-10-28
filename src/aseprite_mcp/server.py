"""MCP server wiring: build the server, start the bridge, register the tools."""

from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager
from typing import Any

from mcp.server.mcpserver import MCPServer

from .bridge.ws_server import AsepriteBridge
from .config import Config
from .tools import (
    animation,
    cels,
    connection,
    drawing,
    frames,
    history,
    inspection,
    layers,
    sprite,
)
from .tools.base import ToolContext
from .usage import UsageLog

log = logging.getLogger(__name__)

# Shown to the client as server-level guidance. This is where the workflow from
# docs/ASEPRITE_MCP.md section 17 lives, so the agent inherits it without the
# user having to restate it in every prompt.
INSTRUCTIONS = """\
Drive a live Aseprite session to create and edit pixel-art sprites and animations.

Work in a loop: EDIT -> PREVIEW -> ANALYZE -> CORRECT. A command returning ok is
not evidence that the result looks right; only looking at a preview is.

Before editing, call get_sprite_info once rather than assuming the document's
structure: it returns the layers, frame durations and tags. Read get_palette when
choosing colors.

After a substantial edit, call get_canvas_preview and actually look at it; pass a
draw call's changed box as region to zoom into just that area. After
changing several animation frames, call get_animation_contact_sheet and
get_onion_skin_preview to judge motion arcs, spacing, volume consistency and
pixel jitter across frames.

Prefer duplicate_frame followed by a targeted change over redrawing a pose from
scratch. Write shapes with draw_rows (the character-map format get_region reads
back) rather than draw_pixels: it costs a fraction of the tokens.
Reuse existing palette colors instead of introducing near-duplicates.

Each tool call is one native undo step, so undo reverses exactly one call.
"""


class AsepriteServer(MCPServer):
    """MCPServer with this project's tool defaults, applied in one place."""

    def __init__(self, *args: Any, usage_log: UsageLog | None = None, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._usage_log = usage_log

    def tool(self, *args: Any, structured_output: bool | None = False, **kwargs: Any):
        # Every tool already returns JSON as text. Left on, the SDK also derives
        # an outputSchema for each tool and sends every reply a second time as
        # structuredContent {"result": "<the same JSON, escaped>"}.
        return super().tool(*args, structured_output=structured_output, **kwargs)

    async def call_tool(self, name: str, arguments: dict[str, Any], context: Any = None):
        if self._usage_log is None:
            return await super().call_tool(name, arguments, context)
        started = time.perf_counter()
        try:
            result = await super().call_tool(name, arguments, context)
        except Exception as exc:
            self._usage_log.record(name, arguments, None, time.perf_counter() - started, str(exc))
            raise
        self._usage_log.record(name, arguments, result, time.perf_counter() - started)
        return result


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

    mcp = AsepriteServer(
        name="aseprite",
        version="0.1.0",
        instructions=INSTRUCTIONS,
        lifespan=lifespan,
        log_level=config.log_level,
        usage_log=UsageLog(config.usage_log) if config.usage_log else None,
    )

    for module in (connection, sprite, layers, frames, drawing, cels, inspection, animation, history):
        module.register(mcp, ctx)

    return mcp, ctx
