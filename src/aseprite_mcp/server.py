"""MCP server wiring: build the server, start the bridge, register the tools."""

from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from collections import OrderedDict
from typing import Any

from mcp.server.mcpserver import MCPServer

from .bridge.ws_server import AsepriteBridge
from .config import Config
from .tools import (
    animation,
    batch,
    cels,
    connection,
    drawing,
    frames,
    history,
    inspection,
    layers,
    rig,
    sprite,
)
from .tools.base import ToolContext, _instance_override, _recording
from .usage import UsageLog

log = logging.getLogger(__name__)

# Shown to the client as server-level guidance. This is where the workflow from
# docs/ASEPRITE_MCP.md section 17 lives, so the agent inherits it without the
# user having to restate it in every prompt.
INSTRUCTIONS = """\
Drive a live Aseprite session to create and edit pixel-art sprites and animations.

Work in a loop: EDIT -> CHECK -> CORRECT. A command returning ok is not evidence
that the result looks right; checking it is. Every call re-reads the whole
conversation and every image stays in it, so get there in few calls:

- Start with one get_sprite_info: it has the layers, frame durations and tags.
  Read get_palette when choosing colors. Layer arguments take the 8-character id
  from get_sprite_info or an exact name; an omitted layer or frame means the
  active one.
- Draw shapes with draw_rows (the format get_region returns), runs with
  draw_line, blocks with draw_rect or fill. Keep draw_pixels for a few scattered
  pixels.
- Animate a character with a rig: one layer per body part (split_layer cuts
  up a flat drawing), define_rig once, then pose_frame builds each frame from
  the rest frame, never from the last one. Draw a new part drawing on the frame
  that first needs it and reuse it elsewhere by frame. refresh_rig after
  changing the rest frame. get_region(by_layer=true) shows which part is where.
  A character sharing another's part names gets its animations with
  import_poses from that one's export_poses template.
- For other edits, build frames from earlier ones: duplicate_frame, then
  shift_cel, flip_cel, copy_cel or replace_color, and redraw only what changed.
- Group the edits for one step into a single batch, with preview=true when you
  need to see the result. A batch is one undo step.
- Check exact facts with text: get_region for pixels, compare_frames for what
  changed, get_animation_bounds for drift. Use images for judgement: one
  get_canvas_preview per batch of edits, zoomed with region (a draw reply's
  changed box) for details; one get_animation_contact_sheet per animation pass;
  get_onion_skin_preview only for a specific motion question.
- Deterministic edits such as replace_color report what they changed and need no
  preview.
- With several Aseprite windows connected, calls fail with INSTANCE_REQUIRED
  until select_instance picks one for this session (by id, name or open
  document). A client without MCP sessions passes aseprite_instance on each call.

Reuse existing palette colors instead of introducing near-duplicates. Each call,
or each whole batch, is one undo step.
"""


_NULL = {"type": "null"}


def slim_schema(schema: Any) -> Any:
    """Drop what a JSON schema spends on Pydantic boilerplate rather than meaning.

    Every property carries a generated "title", and every optional argument is
    spelled anyOf [{type}, {"type": "null"}] with a null default. Tool schemas go
    to the model with every request, and the two account for a large share of
    them. An optional argument is already marked by its absence from "required".
    Arguments are still validated against the full Pydantic model on the server.
    """
    if isinstance(schema, list):
        return [slim_schema(item) for item in schema]
    if not isinstance(schema, dict):
        return schema
    out = {
        key: slim_schema(value)
        for key, value in schema.items()
        # Only a string title is boilerplate; a property named "title" is a dict.
        if not (key == "title" and isinstance(value, str))
    }
    any_of = out.get("anyOf")
    if isinstance(any_of, list) and _NULL in any_of:
        rest = [s for s in any_of if s != _NULL]
        del out["anyOf"]
        out = {**rest[0], **out} if len(rest) == 1 else {"anyOf": rest, **out}
        if "default" in out and out["default"] is None:
            del out["default"]
    return out


# A per-call choice of Aseprite window, for clients that keep no MCP session
# (the 2026-07-28 protocol is one self-contained POST per call, and stateless
# calls get fresh memory). Stripped from the arguments before validation, so no
# tool declares it and no schema pays for it; INSTRUCTIONS and the
# INSTANCE_REQUIRED error say it exists.
INSTANCE_ARGUMENT = "aseprite_instance"


class AsepriteServer(MCPServer):
    """MCPServer with this project's tool defaults, applied in one place."""

    def __init__(self, *args: Any, usage_log: UsageLog | None = None, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._usage_log = usage_log
        self._tool_lock = asyncio.Lock()
        self._shared_context: ToolContext | None = None
        self._session_memory: OrderedDict[str, ToolContext] = OrderedDict()

    def tool(self, *args: Any, structured_output: bool | None = False, **kwargs: Any):
        # Every tool already returns JSON as text. Left on, the SDK also derives
        # an outputSchema for each tool and sends every reply a second time as
        # structuredContent {"result": "<the same JSON, escaped>"}.
        return super().tool(*args, structured_output=structured_output, **kwargs)

    async def list_tools(self):
        return [
            tool.model_copy(update={"input_schema": slim_schema(tool.input_schema)})
            for tool in await super().list_tools()
        ]

    async def call_tool(self, name: str, arguments: dict[str, Any], context: Any = None):
        # Batch validation recursively calls tools while already holding the lock.
        if _recording.get() is not None:
            return await super().call_tool(name, arguments, context)
        if INSTANCE_ARGUMENT in arguments:
            arguments = dict(arguments)
            chosen = arguments.pop(INSTANCE_ARGUMENT)
            if chosen is not None:
                token = _instance_override.set(str(chosen))
                try:
                    return await self._call_locked(name, arguments, context)
                finally:
                    _instance_override.reset(token)
        return await self._call_locked(name, arguments, context)

    async def _call_locked(self, name: str, arguments: dict[str, Any], context: Any):
        async with self._tool_lock:
            ctx = self._shared_context
            if ctx is None or context is None:
                return await self._call_tool(name, arguments, context)
            # The SDK session proxy can be recreated for every request. HTTP's
            # transport-validated session id is stable. Stateless calls get fresh
            # memory; this id is only a cache key, never an access-control boundary.
            session = (context.headers or {}).get("mcp-session-id")
            memory = self._session_memory.get(session) if session else None
            if memory is None:
                memory = ToolContext(bridge=ctx.bridge, config=ctx.config)
            if session:
                self._session_memory[session] = memory
                self._session_memory.move_to_end(session)
                while len(self._session_memory) > 128:
                    self._session_memory.popitem(last=False)
            fields = ("last_legend", "_image_labels", "_latest_image", "_skipped_images",
                      "instance")
            for field in fields:
                setattr(ctx, field, getattr(memory, field))
            try:
                return await self._call_tool(name, arguments, context)
            finally:
                for field in fields:
                    setattr(memory, field, getattr(ctx, field))

    async def _call_tool(self, name: str, arguments: dict[str, Any], context: Any = None):
        # Ops a batch is collecting are part of the batch's own entry.
        if self._usage_log is None or _recording.get() is not None:
            return await super().call_tool(name, arguments, context)
        started = time.perf_counter()
        try:
            result = await super().call_tool(name, arguments, context)
        except Exception as exc:
            self._usage_log.record(name, arguments, None, time.perf_counter() - started, str(exc))
            raise
        self._usage_log.record(name, arguments, result, time.perf_counter() - started)
        return result


def build_server(config: Config | None = None, *, shared: bool = False) -> tuple[MCPServer, ToolContext]:
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
            if shared and bridge.bind_error:
                raise RuntimeError(
                    f"{bridge.bind_error} Stop the old stdio server, then start one "
                    "shared HTTP server and point every client at its /mcp URL."
                )
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
    if shared:
        mcp._shared_context = ctx

    for module in (
        connection, sprite, layers, frames, drawing, cels, inspection, animation, history, rig,
        batch,
    ):
        module.register(mcp, ctx)

    return mcp, ctx
