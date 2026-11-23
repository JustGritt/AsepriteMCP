"""Character rigs: part layers, a rest frame, and a pose per frame.

Animating a small character by editing the previous frame drifts, and at 18-24
px the model cannot tell which pixels are the arm. A rig fixes both: every part
is its own layer, and every frame is a pose of the rest frame, built from data
the file keeps. docs/ANIMATION.md has the design.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Literal

from mcp.server.mcpserver import MCPServer
from pydantic import BaseModel

from ..bridge.protocol import BridgeError, ErrorCode
from ..colors import normalize_color
from ..paths import resolve_in_sandbox
from .base import ToolContext, as_json
from .drawing import OUTSIDE, TRANSPARENT, _target, _uneven_rows

# Pose templates are JSON: readable, diffable, and written by the server, so
# Aseprite needs no file access for them. See docs/ANIMATION.md, "Templates".
TEMPLATE_SUFFIXES = frozenset({".json"})
TEMPLATE_FORMAT = "aseprite-mcp-poses"


def _is_template(path: Path) -> bool:
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("format") == TEMPLATE_FORMAT
    except (OSError, ValueError, AttributeError):
        return False


def _read_template(path: Path) -> dict[str, Any]:
    try:
        template = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS, f"Could not read {path.name} as JSON: {exc}"
        ) from exc
    if not isinstance(template, dict) or template.get("format") != TEMPLATE_FORMAT:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"{path.name} is not a pose template. Make one with export_poses.",
        )
    return template


def _check_tags(tags: list[str] | None) -> None:
    if tags is not None and not tags:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS, "tags must name at least one tag, or be left out for all."
        )


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

    @mcp.tool(
        title="Export poses",
        description=(
            "Save the rigged sprite's tags (default all) as a .json pose template: frames, "
            "timing, poses and hand-drawn parts, for import_poses on another character."
        ),
    )
    async def export_poses(path: str, tags: list[str] | None = None) -> str:
        _check_tags(tags)
        resolved = resolve_in_sandbox(path, ctx.config.allowed_dirs, suffixes=TEMPLATE_SUFFIXES)
        replaced = resolved.exists()
        # Re-exporting a template is the normal loop; any other file is not ours.
        if replaced and not _is_template(resolved):
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"{resolved.name} exists and is not a pose template. Choose another path.",
            )
        params: dict[str, Any] = {}
        if tags is not None:
            params["tags"] = tags
        reply = await ctx.call("rig.exportPoses", params, timeout=ctx.config.render_timeout)
        template = reply.get("template")
        if not isinstance(template, dict):
            raise BridgeError(ErrorCode.LUA_ERROR, "Aseprite returned no template.")
        resolved.parent.mkdir(parents=True, exist_ok=True)
        temp = resolved.with_suffix(".json.tmp")
        temp.write_text(json.dumps(template, indent=1) + "\n", encoding="utf-8")
        os.replace(temp, resolved)
        return as_json({
            "path": str(resolved),
            "frames": reply.get("frames"),
            "tags": reply.get("tags"),
            "drawn": reply.get("drawn") or None,
            "replaced": replaced or None,
        })

    @mcp.tool(
        title="Import poses",
        description=(
            "Rebuild a pose template's tags (default all) on the rigged sprite from its own "
            "rest drawing. Hand-drawn parts are copied where the rest drawing matches (auto), "
            "always or never; the reply lists what is left to draw."
        ),
    )
    async def import_poses(
        path: str,
        tags: list[str] | None = None,
        drawings: Literal["auto", "copy", "skip"] = "auto",
    ) -> str:
        _check_tags(tags)
        resolved = resolve_in_sandbox(
            path, ctx.config.allowed_dirs, suffixes=TEMPLATE_SUFFIXES, must_exist=True
        )
        params: dict[str, Any] = {"template": _read_template(resolved), "drawings": drawings}
        if tags is not None:
            params["tags"] = tags
        return as_json(
            await ctx.call("rig.importPoses", params, timeout=ctx.config.render_timeout)
        )
