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
            "Frame range, direction, repeat count and per-frame durations of a tag, or of "
            "every frame."
        ),
    )
    async def get_animation_info(tag: str | None = None) -> str:
        params = {} if tag is None else {"tag": tag}
        return as_json(await ctx.call("anim.info", params))

    @mcp.tool(
        title="Compare frames",
        description=(
            "What differs between frames a and b, as counts (appeared, vanished, "
            "recolored), the changed box and each frame's opaque bounds. diff_map=true adds "
            "a map of the changed box (+ appeared, - vanished, * recolored). Far cheaper "
            "than an onion skin."
        ),
    )
    async def compare_frames(
        a: int, b: int, layer: str | None = None, diff_map: bool = False
    ) -> str:
        params: dict[str, Any] = {"a": a, "b": b, "diffMap": diff_map}
        if layer is not None:
            params["layer"] = layer
        params["maxMapPixels"] = ctx.config.max_region_pixels
        return as_json(await ctx.call("anim.compare", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Get animation bounds",
        description=(
            "The opaque bounding box of each frame in a tag, or of every frame, plus their "
            "union, so drift shows up as numbers."
        ),
    )
    async def get_animation_bounds(tag: str | None = None, layer: str | None = None) -> str:
        params: dict[str, Any] = {}
        if tag is not None:
            params["tag"] = tag
        if layer is not None:
            params["layer"] = layer
        return as_json(await ctx.call("anim.bounds", params, timeout=ctx.config.render_timeout))

    @mcp.tool(
        title="Get animation contact sheet",
        description=(
            "Every frame in one labelled grid, with durations and tags as text. Use it once "
            "per animation pass to judge silhouette, volume, arcs, spacing and jitter."
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
        params: dict[str, Any] = {"scale": scale, "maxEdge": ctx.config.sheet_max_edge}
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
        return [ctx.image_or_note(image, f"contact sheet, {summary[0]}"), "\n".join(summary)]

    @mcp.tool(
        title="Get onion skin preview",
        description=(
            "The previous (red tint), current and next (blue tint) frames superimposed, for "
            "a specific question about motion between them."
        ),
    )
    async def get_onion_skin_preview(
        frame: int | None = None, scale: int = 8
    ) -> list[Image | str]:
        check_scale(scale)
        params: dict[str, Any] = {"scale": scale, "maxEdge": ctx.config.preview_max_edge}
        if frame is not None:
            params["frame"] = frame
        image, result = await render_to_image(ctx, "render.onionSkin", params)
        legend = (
            "previous frame is tinted and faint, current frame is fully opaque, "
            "next frame is tinted and faint"
        )
        label = describe(result)
        return [ctx.image_or_note(image, f"onion skin, {label}"), f"{label}. {legend}"]

    # ------------------------------------------------------------------------ tags

    @mcp.tool(
        title="Create animation tag",
        description=(
            "Tag frames from_frame to to_frame (1-based, inclusive) as a named animation. "
            "repeats=0 loops forever."
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
            await ctx.call(
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
            "Change a tag's name, range, direction or repeats; only the fields you pass "
            "change."
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
        return as_json(await ctx.call("tag.update", params))

    @mcp.tool(
        title="Delete animation tag",
        description="Delete a tag. The frames themselves are kept.",
    )
    async def delete_animation_tag(name: str) -> str:
        return as_json(await ctx.call("tag.delete", {"name": name}))
