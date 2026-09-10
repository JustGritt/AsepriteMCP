"""Animation inspection and tags (spec sections 13 and 14).

Spec section 13 singles this group out: a model cannot reliably judge an
animation from isolated frames, so the contact sheet and onion skin are the tools
that make temporal problems -- drift, jitter, bad spacing, volume changes --
visible at all.
"""

from __future__ import annotations

from typing import Any, Literal

from mcp.server.mcpserver import Image, MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from .base import ToolContext, as_json, render_to_image
from .inspection import check_scale, describe

Direction = Literal["forward", "reverse", "pingpong", "pingpong_reverse"]


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    # ------------------------------------------------------------------ inspection

    @mcp.tool(
        title="Get animation info",
        description=(
            "Report the frame range, direction, repeat count and per-frame durations of "
            "a tag, or of the whole sprite when no tag is given."
        ),
    )
    async def get_animation_info(tag: str | None = None) -> str:
        params = {} if tag is None else {"tag": tag}
        return as_json(await ctx.bridge.call("anim.info", params))

    @mcp.tool(
        title="Get animation contact sheet",
        description=(
            "Render every frame side by side in one image, with frame numbers drawn in "
            "each cell, and return the per-frame durations and tags as text. This is how "
            "you judge an animation as a whole: check silhouette readability, volume "
            "consistency, motion arcs, spacing and pixel jitter across frames. Call it "
            "after changing several frames."
        ),
    )
    async def get_animation_contact_sheet(
        scale: int = 4,
        tag: str | None = None,
        columns: int | None = None,
    ) -> list[Image | str]:
        check_scale(scale)
        if columns is not None and columns < 1:
            raise BridgeError(ErrorCode.INVALID_PARAMS, f"columns must be >= 1, got {columns}.")
        params: dict[str, Any] = {"scale": scale}
        if tag is not None:
            params["tag"] = tag
        if columns is not None:
            params["columns"] = columns

        image, result = await render_to_image(ctx, "render.contactSheet", params)
        cells = result.get("cells") or []
        summary = [describe(result)]
        if cells:
            def describe_cell(cell: dict[str, Any]) -> str:
                text = f"F{cell.get('frame')} {cell.get('durationMs')}ms"
                tags = cell.get("tags") or []
                if tags:
                    text += f" [{', '.join(tags)}]"
                return text

            summary.append(
                "cells (left to right, top to bottom): "
                + "; ".join(describe_cell(c) for c in cells)
            )
        return [image, "\n".join(summary)]

    @mcp.tool(
        title="Get onion skin preview",
        description=(
            "Render the previous, current and next frame superimposed at distinct "
            "opacities, so motion arcs, spacing, silhouette continuity and unintended "
            "jitter become visible. Defaults to the active frame."
        ),
    )
    async def get_onion_skin_preview(
        frame: int | None = None, scale: int = 8
    ) -> list[Image | str]:
        check_scale(scale)
        params: dict[str, Any] = {"scale": scale}
        if frame is not None:
            params["frame"] = frame
        image, result = await render_to_image(ctx, "render.onionSkin", params)
        legend = (
            "previous frame is tinted and faint, current frame is fully opaque, "
            "next frame is tinted and faint"
        )
        return [image, f"{describe(result)}. {legend}"]

    # ------------------------------------------------------------------------ tags

    @mcp.tool(
        title="List animation tags",
        description="List every tag with its name, frame range, direction and repeat count.",
    )
    async def list_animation_tags() -> str:
        return as_json(await ctx.bridge.call("tag.list"))

    @mcp.tool(
        title="Create animation tag",
        description=(
            "Tag a contiguous range of frames as a named animation, such as idle, walk, "
            "attack, hit or death. Frame numbers are 1-based and inclusive."
        ),
    )
    async def create_animation_tag(
        name: str,
        from_frame: int,
        to_frame: int,
        direction: Direction = "forward",
        repeats: int = 0,
    ) -> str:
        return as_json(
            await ctx.bridge.call(
                "tag.create",
                {
                    "name": name,
                    "from": from_frame,
                    "to": to_frame,
                    "direction": direction,
                    "repeats": repeats,
                },
            )
        )

    @mcp.tool(
        title="Update animation tag",
        description=(
            "Change an existing tag. Only the fields you pass are modified; repeats of 0 "
            "means loop indefinitely."
        ),
    )
    async def update_animation_tag(
        name: str,
        new_name: str | None = None,
        from_frame: int | None = None,
        to_frame: int | None = None,
        direction: Direction | None = None,
        repeats: int | None = None,
    ) -> str:
        params: dict[str, Any] = {"name": name}
        for key, value in (
            ("newName", new_name),
            ("from", from_frame),
            ("to", to_frame),
            ("direction", direction),
            ("repeats", repeats),
        ):
            if value is not None:
                params[key] = value
        if len(params) == 1:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS, "Nothing to update: pass at least one field to change."
            )
        return as_json(await ctx.bridge.call("tag.update", params))

    @mcp.tool(
        title="Delete animation tag",
        description="Delete a tag. The frames themselves are untouched.",
    )
    async def delete_animation_tag(name: str) -> str:
        return as_json(await ctx.bridge.call("tag.delete", {"name": name}))
