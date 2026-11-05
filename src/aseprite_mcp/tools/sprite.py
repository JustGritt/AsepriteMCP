"""Sprite-level tools (spec section 8)."""

from __future__ import annotations

import os
from typing import Literal

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from ..paths import OPEN_SUFFIXES, SAVE_SUFFIXES, resolve_in_sandbox
from .base import ToolContext, as_json


async def _own_file(ctx: ToolContext) -> str:
    """The file a save with no path would write to, once it has passed the sandbox.

    The active document can be anything the user opened by hand, so its own file
    gets the same check as a path the agent names. Lua compares the result with
    the active document again, because the tab can change after this check.
    """
    own_file = (await ctx.call("sprite.info")).get("path") or ""
    # A sprite that was never saved reports a bare name such as "Sprite".
    if not os.path.isabs(own_file):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            "This sprite has never been saved, so there is no file to save over. "
            "Pass a path inside an allowed directory.",
        )
    try:
        resolve_in_sandbox(own_file, ctx.config.allowed_dirs, suffixes=SAVE_SUFFIXES)
    except BridgeError as exc:
        raise BridgeError(
            exc.code,
            f"Not saving over this sprite's own file. {exc.message} "
            "Pass a path to save a .aseprite copy inside an allowed directory.",
        ) from exc
    return own_file


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
        title="New sprite",
        description=(
            "Create a blank sprite and make it active. With path, also save it there "
            "(a new .aseprite file inside an allowed directory), so save_sprite() needs "
            "no path later. Replies with the same overview as get_sprite_info."
        ),
    )
    async def new_sprite(
        width: int,
        height: int,
        color_mode: Literal["rgb", "grayscale", "indexed"] = "rgb",
        path: str | None = None,
    ) -> str:
        limit = ctx.config.max_sprite_size
        if not (1 <= width <= limit and 1 <= height <= limit):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"width and height must be 1-{limit}, got {width}x{height}.",
            )
        params: dict[str, object] = {"width": width, "height": height, "colorMode": color_mode}
        if path:
            resolved = resolve_in_sandbox(path, ctx.config.allowed_dirs, suffixes=SAVE_SUFFIXES)
            # Never silently replace someone's work with a blank canvas.
            if resolved.exists():
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"{resolved.name} already exists. Open it with open_sprite, or "
                    "choose another path.",
                )
            resolved.parent.mkdir(parents=True, exist_ok=True)
            params["path"] = str(resolved)
        return as_json(await ctx.call("sprite.new", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Open sprite",
        description=(
            "Open a .aseprite, .ase or .png file inside an allowed directory and make it "
            "active. Relative paths resolve against the first allowed directory. "
            "Replies with the same overview as get_sprite_info."
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
            "Save the active sprite over its own file, or to path. Either way the target "
            "must be a .aseprite or .ase file inside an allowed directory, so layers are "
            "never flattened."
        ),
    )
    async def save_sprite(path: str | None = None) -> str:
        params: dict[str, object]
        if path:
            resolved = resolve_in_sandbox(path, ctx.config.allowed_dirs, suffixes=SAVE_SUFFIXES)
            resolved.parent.mkdir(parents=True, exist_ok=True)
            params = {"path": str(resolved)}
        else:
            params = {"expectedPath": await _own_file(ctx)}
        return as_json(await ctx.call("sprite.save", params, timeout=ctx.config.render_timeout))
