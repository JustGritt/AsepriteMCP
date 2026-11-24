"""MCP server wiring: build the server, start the bridge, register the tools."""

from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from collections import OrderedDict
from typing import Any

from mcp.server.mcpserver import MCPServer

from .bridge.protocol import BridgeError
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
    image,
    inspection,
    layers,
    rig,
    sprite,
)
from .tools.base import (
    SessionMemory,
    ToolContext,
    _instance_override,
    _recording,
    _session,
    _sprite_override,
)
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
- To work from a picture, import_image puts it on its own layer; with palette,
  get_region on that layer is a grid to trace. Hide it to judge the art.
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
- Sharing one window with other agents, pass aseprite_sprite (your sprite's
  spriteId, or its file name) on every call, so each works on its own sprite.

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
# The same for a sprite in that window (#34), so agents sharing one window each
# work on their own. Passed to Aseprite as given: a spriteId or a file name.
SPRITE_ARGUMENT = "aseprite_sprite"


class AsepriteServer(MCPServer):
    """MCPServer with this project's tool defaults, applied in one place."""

    def __init__(self, *args: Any, usage_log: UsageLog | None = None, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._usage_log = usage_log
        # One lock per Aseprite window id (#33): calls on one window never
        # interleave, calls on different windows run side by side. None is for
        # calls that resolve to no window.
        self._locks: dict[str | None, asyncio.Lock] = {None: asyncio.Lock()}
        self._context: ToolContext | None = None
        self._shared = False
        self._session_memory: OrderedDict[str, SessionMemory] = OrderedDict()

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
        # Batch validation recursively calls tools inside the batch's own call.
        if _recording.get() is not None:
            return await super().call_tool(name, arguments, context)
        arguments = dict(arguments)
        chosen = arguments.pop(INSTANCE_ARGUMENT, None)
        override = _instance_override.set(None if chosen is None else str(chosen))
        sprite = _sprite_override.set(arguments.pop(SPRITE_ARGUMENT, None))
        session = _session.set(self._memory_for(context))
        try:
            window = self._window()
            async with self._locks.setdefault(window, asyncio.Lock()):
                if window is not None:
                    # A call that found no window may be waiting for one to attach
                    # and then use it, so let it finish first.
                    async with self._locks[None]:
                        pass
                return await self._call_tool(name, arguments, context)
        finally:
            _session.reset(session)
            _sprite_override.reset(sprite)
            _instance_override.reset(override)

    def _memory_for(self, context: Any) -> SessionMemory | None:
        """The calling HTTP session's memory; None means the context's own (stdio)."""
        if not self._shared or context is None:
            return None
        # The SDK session proxy can be recreated for every request. HTTP's
        # transport-validated session id is stable. Stateless calls get fresh
        # memory; this id is only a cache key, never an access-control boundary.
        session = (context.headers or {}).get("mcp-session-id")
        if not session:
            return SessionMemory()
        memory = self._session_memory.pop(session, None) or SessionMemory()
        self._session_memory[session] = memory
        while len(self._session_memory) > 128:
            self._session_memory.popitem(last=False)
        return memory

    def _window(self) -> str | None:
        """The id of the connected window this call will drive, or None if none yet."""
        if self._context is None:
            return None
        try:
            selected = self._context.selected_instance()
        except BridgeError:  # an ambiguous name: the tool reports it
            return None
        ids = [instance.id for instance in self._context.bridge.instances]
        if selected is None and len(ids) == 1:
            return ids[0]
        return selected if selected in ids else None

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
        # A stdio server binds on its first command instead, so a session that
        # never uses Aseprite never holds the port (#19).
        if shared:
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
    mcp._context = ctx
    mcp._shared = shared

    for module in (
        connection, sprite, layers, frames, drawing, cels, inspection, animation, history, rig, image,
        batch,
    ):
        module.register(mcp, ctx)

    return mcp, ctx
