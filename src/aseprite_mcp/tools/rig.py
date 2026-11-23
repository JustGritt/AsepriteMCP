"""Character rigs: part layers, a rest frame, and a pose per frame.

Animating a small character by editing the previous frame drifts, and at 18-24
px the model cannot tell which pixels are the arm. A rig fixes both: every part
is its own layer, and every frame is a pose of the rest frame, built from data
the file keeps. docs/ANIMATION.md has the design.
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer
from pydantic import BaseModel

from ..bridge.protocol import BridgeError, ErrorCode
from ..colors import normalize_color
from .base import ToolContext, as_json
from .drawing import OUTSIDE, TRANSPARENT, _target, _uneven_rows


# No field descriptions: the tool descriptions say what each field does, and
# every byte of a schema goes to the model with every request.
class PartPose(BaseModel):
    dx: int = 0
    dy: int = 0
    frame: int | None = None
    layer: str | None = None
    recolor: dict[str, str] | None = None
    hide: bool = False


class OutlineSpec(BaseModel):
    color: str
    parts: list[str] | None = None
    floor: int | None = None


def _encode_pose(name: str, pose: list[int] | PartPose) -> dict[str, Any]:
    if isinstance(pose, list):
        if len(pose) != 2:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"{name}: an offset is [dx, dy], got {len(pose)} numbers.",
            )
        return {"dx": pose[0], "dy": pose[1]}
    out: dict[str, Any] = {"dx": pose.dx, "dy": pose.dy}
    if pose.frame is not None:
        out["frame"] = pose.frame
    if pose.layer is not None:
        out["layer"] = pose.layer
    if pose.recolor:
        out["recolor"] = {
            normalize_color(src): normalize_color(dst) for src, dst in pose.recolor.items()
        }
    if pose.hide:
        out["hide"] = True
    return out


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Split layer",
        description=(
            "Move pixels out of a layer into part layers: rows in the draw_rows format, "
            "parts maps each character to a layer (created above if missing). '.' stays."
        ),
    )
    async def split_layer(
        layer: str,
        x: int,
        y: int,
        rows: list[str],
        parts: dict[str, str],
        frame: int | None = None,
    ) -> str:
        if not rows:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "rows must hold at least one row.")
        if not parts:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "parts must map at least one character.")
        for char in parts:
            if len(char) != 1 or char in (TRANSPARENT, OUTSIDE):
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"parts key {char!r} must be one character other than '.' and ' '.",
                )
        params: dict[str, Any] = {
            "layer": layer,
            "x": x,
            "y": y,
            "rows": rows,
            # Pairs rather than an object: the order is the order the new
            # layers stack in, and Lua does not keep an object's key order.
            "parts": [[char, name] for char, name in parts.items()],
            **_target(None, frame),
        }
        reply = await ctx.call("cel.split", params)
        uneven = _uneven_rows(rows, "skip")
        if uneven:
            reply["warning"] = uneven
        return as_json(reply)

    @mcp.tool(
        title="Define rig",
        description=(
            "Rig a character: parts are layers bottom to top, drawn on rest_frame (missing "
            "ones created). follows {part: leader}. outline is redrawn on every pose around "
            "its parts (default all), down to row floor. Saved in the file."
        ),
    )
    async def define_rig(
        parts: list[str],
        rest_frame: int = 1,
        follows: dict[str, str] | None = None,
        outline: OutlineSpec | None = None,
    ) -> str:
        if not parts:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "parts must name at least one layer.")
        params: dict[str, Any] = {"parts": parts, "rest": rest_frame}
        if follows:
            params["follows"] = follows
        if outline is not None:
            spec: dict[str, Any] = {"color": normalize_color(outline.color)}
            if outline.parts is not None:
                spec["parts"] = outline.parts
            if outline.floor is not None:
                spec["floor"] = outline.floor
            params["outline"] = spec
        return as_json(await ctx.call("rig.define", params))

    @mcp.tool(
        title="Pose frame",
        description=(
            "Build a frame from the rig's rest frame: parts maps a part to [dx, dy] or to "
            "{dx, dy, frame, layer, recolor {from: to}, hide}, taking another frame's or "
            "part's drawing. Unlisted parts keep their pose; hand edits are kept."
        ),
    )
    async def pose_frame(
        frame: int, parts: dict[str, list[int] | PartPose] | None = None
    ) -> str:
        params: dict[str, Any] = {"frame": frame}
        if parts:
            params["parts"] = {name: _encode_pose(name, pose) for name, pose in parts.items()}
        return as_json(await ctx.call("rig.pose", params))

    @mcp.tool(
        title="Refresh rig",
        description=(
            "Re-apply every saved pose and outline after the rest frame or a source drawing "
            "changed. Hand-edited cels are kept and listed unless force."
        ),
    )
    async def refresh_rig(frames: list[int] | None = None, force: bool = False) -> str:
        params: dict[str, Any] = {}
        if frames is not None:
            if not frames:
                raise BridgeError(ErrorCode.INVALID_PARAMS, "frames must not be empty.")
            params["frames"] = frames
        if force:
            params["force"] = True
        return as_json(
            await ctx.call("rig.refresh", params, timeout=ctx.config.render_timeout)
        )
