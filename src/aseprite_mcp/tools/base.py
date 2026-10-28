"""Shared plumbing for the MCP tool modules.

Every tool group receives a :class:`ToolContext` and registers itself onto the
MCPServer instance. Keeping the bridge on a context object rather than a module
global is what lets the tests drive the whole tool surface against a fake
extension.
"""

from __future__ import annotations

import json
import logging
import shutil
import tempfile
import uuid
from contextvars import ContextVar
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Image

from ..bridge.protocol import BridgeError, ErrorCode
from ..bridge.ws_server import AsepriteBridge
from ..config import Config

log = logging.getLogger(__name__)


# Set by the batch tool while it collects commands: each tool then validates and
# encodes its arguments as usual, but its command is recorded instead of sent.
_recording: ContextVar[list[tuple[str, dict[str, Any]]] | None] = ContextVar(
    "aseprite_mcp_recording", default=None
)


@dataclass
class ToolContext:
    """Everything a tool needs, in one injectable object."""

    bridge: AsepriteBridge
    config: Config
    # The most recent draw_rows legend, so a run of edits in the same colors does
    # not have to restate it. Memory only: it is gone when the server restarts.
    last_legend: dict[str, str | int] | None = field(default=None, init=False, repr=False)
    _temp_dir: Path | None = field(default=None, init=False, repr=False)

    @property
    def temp_dir(self) -> Path:
        """Server-owned scratch directory for rendered previews.

        Deliberately outside the sandbox allowlist and never derived from agent
        input, so a render path can never be used to write somewhere else.
        """
        if self._temp_dir is None:
            self._temp_dir = Path(tempfile.mkdtemp(prefix="aseprite-mcp-"))
        return self._temp_dir

    async def call(
        self, command: str, params: dict[str, Any] | None = None, timeout: float | None = None
    ) -> dict[str, Any]:
        """Send one command to Aseprite, or record it when a batch is collecting."""
        recording = _recording.get()
        if recording is not None:
            recording.append((command, dict(params or {})))
            return {}
        return await self.bridge.call(command, params, timeout=timeout)

    def cleanup(self) -> None:
        if self._temp_dir is not None:
            shutil.rmtree(self._temp_dir, ignore_errors=True)
            self._temp_dir = None


def _prune(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: _prune(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [_prune(v) for v in value]
    return value


def as_json(payload: Any) -> str:
    """Render a tool result as compact JSON.

    No indentation and no nulls: the model reads every byte of every reply, and
    each reply stays in its context for the rest of the session.
    """
    return json.dumps(_prune(payload), separators=(",", ":"), ensure_ascii=False)


async def render_to_image(
    ctx: ToolContext,
    command: str,
    params: dict[str, Any] | None = None,
) -> tuple[Image, dict[str, Any]]:
    """Ask Aseprite to render a PNG to disk, then hand it back as MCP image content.

    Images travel as files rather than WebSocket payloads: the Lua side has to
    write a PNG anyway (there is no in-memory PNG encoder in the script API), and
    a file handoff avoids correlating binary frames with request ids. Both
    processes are on the same machine by construction.
    """
    out_path = ctx.temp_dir / f"{uuid.uuid4().hex}.png"
    request = dict(params or {})
    request["outPath"] = str(out_path)

    try:
        result = await ctx.call(command, request, timeout=ctx.config.render_timeout)
        if not out_path.is_file():
            raise BridgeError(
                ErrorCode.LUA_ERROR,
                f"Aseprite reported success for {command} but wrote no file to {out_path}. "
                "The most common cause is that the script was not granted file-system "
                "access; see docs/SETUP.md.",
            )
        data = out_path.read_bytes()
    finally:
        out_path.unlink(missing_ok=True)

    if not data:
        raise BridgeError(ErrorCode.LUA_ERROR, f"{command} produced an empty PNG.")
    return Image(data=data, format="png"), result
