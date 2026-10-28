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
    "select_layer", "create_layer", "set_layer_visibility",
    "create_animation_tag", "update_animation_tag", "delete_animation_tag",
})


class BatchOp(BaseModel):
    tool: str = Field(description="Name of an editing tool, e.g. draw_rows or shift_cel.")
    args: dict[str, Any] = Field(default_factory=dict, description="That tool's arguments.")


def _reason(exc: Exception) -> str:
    """The tool's own message, without the SDK's 'Error executing tool' prefix."""
    return str(exc.__cause__) if exc.__cause__ else str(exc)


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Batch",
        description=(
            "Run several editing tools in one call and one undo step: ops=[{tool, args}], "
            "in order. All or nothing. preview=true appends a preview of the last frame "
            "edited. Previews, save/open, undo/redo and delete_layer must be called "
            "directly."
        ),
    )
    async def batch(ops: list[BatchOp], preview: bool = False) -> list[Image | str]:
        if not ops:
            raise BridgeError(ErrorCode.INVALID_PARAMS, "ops must hold at least one op.")

        commands: list[dict[str, Any]] = []
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
                text = "".join(b.text for b in result.content if getattr(b, "type", None) == "text")
                raise BridgeError(ErrorCode.INVALID_PARAMS, f"ops[{i}] ({op.tool}): {text}")
            commands.extend({"command": c, "params": p} for c, p in recorded)

        reply = await ctx.call(
            "batch.run", {"ops": commands}, timeout=ctx.config.render_timeout
        )
        content: list[Image | str] = [as_json(reply)]

        if preview:
            frames = [r["frame"] for r in reply.get("results", []) if isinstance(r, dict) and "frame" in r]
            params: dict[str, Any] = {"scale": 8, "maxEdge": ctx.config.preview_max_edge}
            if frames:
                params["frame"] = frames[-1]
            image, result = await render_to_image(ctx, "render.canvas", params)
            content = [image, describe(result), content[0]]
        return content
