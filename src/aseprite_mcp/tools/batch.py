"""Several edits, and optionally a preview, in one call (issue #7).

Every tool call is a model turn that re-reads the whole context, so building a
frame from duplicate_frame + shift_cel + draw_rows + get_canvas_preview cost four
turns. batch does it in one.

Each op runs through its own tool with the batch collecting rather than sending,
so arguments are validated and encoded exactly as in a direct call. The collected
commands then go to Aseprite as one batch.run, which applies them in a single
transaction: one undo step, and all or nothing when any of them fails.
"""

from __future__ import annotations

import json
from typing import Any

from mcp.server.mcpserver import Image, MCPServer
from pydantic import BaseModel, Field

from ..bridge.protocol import BridgeError, ErrorCode
from .base import ToolContext, _recording, as_json, render_to_image
from .inspection import describe

# Tools that edit the document with exactly one command. Previews, file access,
# undo/redo and layer deletion stay out of batches.
BATCHABLE = frozenset({
    "draw_pixels", "draw_rows", "draw_rect", "erase_pixels", "clear_cel", "fill", "draw_line",
    "shift_cel", "flip_cel", "copy_cel", "replace_color",
    "select_frame", "create_frame", "duplicate_frame", "delete_frame", "set_frame_duration",
    "select_layer", "create_layer", "delete_layer", "set_layer_visibility",
    "create_animation_tag", "update_animation_tag", "delete_animation_tag",
    "split_layer", "define_rig", "pose_frame", "refresh_rig",
})


# Added up across ops. Comparing written with the expected count is how a
# miscounted row gets caught, so these stay when the per-op replies go.
_TOTALS = ("written", "filled", "erased", "replaced", "skippedOffCanvas")

_MAX_PALETTE_NOTES = 5


class BatchOp(BaseModel):
    tool: str = Field(description="Name of an editing tool, e.g. draw_rows or shift_cel.")
    args: dict[str, Any] = Field(default_factory=dict, description="That tool's arguments.")


def _reason(exc: Exception) -> str:
    """The tool's own message, without the SDK's 'Error executing tool' prefix."""
    return str(exc.__cause__) if exc.__cause__ else str(exc)


def _text_of(result: Any) -> str:
    return "".join(b.text for b in result.content if getattr(b, "type", None) == "text")


def _own_warning(result: Any) -> str | None:
    """A warning the op's tool worked out itself, such as draw_rows on uneven rows.

    Lua never sees these. While a batch collects, ctx.call returns {}, so anything
    in the tool's own reply came from the tool.
    """
    try:
        payload = json.loads(_text_of(result))
    except ValueError:
        return None
    return payload.get("warning") if isinstance(payload, dict) else None


def _union(boxes: list[list[int]]) -> list[int]:
    left = min(box[0] for box in boxes)
    top = min(box[1] for box in boxes)
    right = max(box[0] + box[2] for box in boxes)
    bottom = max(box[1] + box[3] for box in boxes)
    return [left, top, right - left, bottom - top]


def _summary(
    reply: dict[str, Any], commands: list[dict[str, Any]], own_warnings: dict[int, str]
) -> dict[str, Any]:
    """What the agent cannot work out from the ops it just sent.

    One entry per op mostly repeats the layer, frame and coordinates, and the
    reply stays in context for the rest of the session. So this keeps the totals,
    the changed box, what got created, and anything that says an op went wrong or
    did nothing, with that op's index. Each op is one command, so a result's
    position is its op's index.
    """
    summary: dict[str, Any] = {"applied": reply.get("applied"), "undoSteps": reply.get("undoSteps")}
    totals = dict.fromkeys(_TOTALS, 0)
    boxes: list[list[int]] = []
    created: list[dict[str, Any]] = []
    new_frames: list[int] = []
    # Keyed by text: the same note on 16 ops should not cost 16 sentences.
    warnings: dict[str, list[int]] = {}
    palette_notes: list[str] = []
    results = reply.get("results") or []

    for op, command in enumerate(commands):
        name = command["command"]
        result = results[op] if op < len(results) else {}
        for key in _TOTALS:
            # type(), because cel.copy reports replaced as a bool, and True is an int.
            if type(result.get(key)) in (int, float):
                totals[key] += result[key]
        if result.get("changed"):
            boxes.append(result["changed"])
        # select_layer and select_frame reply with an id or a frame too, so the
        # command is what says something new exists.
        if name == "layer.create":
            created.append({"id": result.get("id"), "name": result.get("name")})
        elif name in ("frame.create", "frame.duplicate"):
            new_frames.append(result.get("frame"))
        if "frameCount" in result:
            summary["frameCount"] = result["frameCount"]
        # A note says an op did nothing, e.g. "No pixel matched that color."
        said = [
            text
            for text in (result.get("warning"), result.get("note"), own_warnings.get(op))
            if text
        ]
        if said:
            warnings.setdefault(" ".join(said), []).append(op)
        for note in [result.get("paletteNote"), *result.get("paletteNotes", [])]:
            if note and note not in palette_notes and len(palette_notes) < _MAX_PALETTE_NOTES:
                palette_notes.append(note)

    summary.update({key: total for key, total in totals.items() if total})
    optional = {
        "changed": _union(boxes) if boxes else None,
        "created": created,
        "newFrames": new_frames,
        "warnings": [{"ops": ops, "warning": text} for text, ops in warnings.items()],
        "paletteNotes": palette_notes,
    }
    summary.update({key: value for key, value in optional.items() if value})
    return summary


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Batch",
        description=(
            "Run several editing tools in one call and one undo step: ops=[{tool, args}], "
            "in order. All or nothing. preview=true appends a preview of the last frame "
            "edited. Previews, save/open and undo/redo must be called directly."
        ),
    )
    async def batch(ops: list[BatchOp], preview: bool = False) -> list[Image | str]:
        if not ops:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "ops must hold at least one op.")

        commands: list[dict[str, Any]] = []
        own_warnings: dict[int, str] = {}
        for i, op in enumerate(ops):
            if op.tool not in BATCHABLE:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"ops[{i}]: {op.tool} cannot run inside a batch. Batchable tools: "
                    f"{', '.join(sorted(BATCHABLE))}.",
                )
            recorded: list[tuple[str, dict[str, Any]]] = []
            token = _recording.set(recorded)
            try:
                result = await mcp.call_tool(op.tool, op.args)
            except Exception as exc:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS, f"ops[{i}] ({op.tool}): {_reason(exc)}"
                ) from exc
            finally:
                _recording.reset(token)
            if getattr(result, "is_error", False):
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS, f"ops[{i}] ({op.tool}): {_text_of(result)}"
                )
            warning = _own_warning(result)
            if warning:
                own_warnings[i] = warning
            commands.extend({"command": c, "params": p} for c, p in recorded)

        reply = await ctx.call(
            "batch.run", {"ops": commands}, timeout=ctx.config.render_timeout
        )
        content: list[Image | str] = [as_json(_summary(reply, commands, own_warnings))]

        if preview:
            frames = [r["frame"] for r in reply.get("results", []) if isinstance(r, dict) and "frame" in r]
            params: dict[str, Any] = {"scale": 8, "maxEdge": ctx.config.preview_max_edge}
            if frames:
                params["frame"] = frames[-1]
            image, result = await render_to_image(ctx, "render.canvas", params)
            label = describe(result)
            content = [ctx.image_or_note(image, label), label, content[0]]
        return content
