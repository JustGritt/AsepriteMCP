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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Image

from ..bridge.protocol import BridgeError, ErrorCode
from ..bridge.ws_server import AsepriteBridge
from ..config import Config

log = logging.getLogger(__name__)


@dataclass
class ToolContext:
    """Everything a tool needs, in one injectable object."""

    bridge: AsepriteBridge
    config: Config
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

    def cleanup(self) -> None:
        if self._temp_dir is not None:
            shutil.rmtree(self._temp_dir, ignore_errors=True)
            self._temp_dir = None


def as_json(payload: Any) -> str:
    """Render a tool result as JSON the model can parse without ambiguity."""
    return json.dumps(payload, indent=2, ensure_ascii=False)


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
        result = await ctx.bridge.call(command, request, timeout=ctx.config.render_timeout)
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
