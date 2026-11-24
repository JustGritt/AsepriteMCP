"""Shared plumbing for the MCP tool modules.

Every tool group receives a :class:`ToolContext` and registers itself onto the
MCPServer instance. Keeping the bridge on a context object rather than a module
global is what lets the tests drive the whole tool surface against a fake
extension.
"""

from __future__ import annotations

import hashlib
import json
import logging
import shutil
import tempfile
import uuid
from collections import OrderedDict
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

# Sent images remembered so an identical one is not sent again. Past this many
# the oldest is forgotten, which only means it would be sent again.
MAX_REMEMBERED_IMAGES = 64


# A window named on the call itself (aseprite_instance), which outranks the
# session's choice. Set by AsepriteServer.call_tool; see INSTANCE_ARGUMENT there.
_instance_override: ContextVar[str | None] = ContextVar(
    "aseprite_mcp_instance_override", default=None
)


# A sprite named on the call itself (aseprite_sprite): a spriteId or file name
# that Aseprite makes active before each command, so several agents can share
# one window (#34). None: the window's active sprite.
_sprite_override: ContextVar[Any] = ContextVar("aseprite_mcp_sprite_override", default=None)


@dataclass
class SessionMemory:
    """What one MCP session remembers between its calls. Gone when the server restarts."""

    # The Aseprite window this session drives, from select_instance; None means
    # "the only one connected".
    instance: str | None = None
    # The most recent draw_rows legend, so a run of edits in the same colors does
    # not have to restate it.
    last_legend: dict[str, str | int] | None = None
    # Images already sent, digest -> label, oldest first, and the digest of the
    # newest image sent under each label. See image_or_note.
    image_labels: OrderedDict[str, str] = field(default_factory=OrderedDict)
    latest_image: dict[str, str] = field(default_factory=dict)
    skipped_images: set[tuple[str, str]] = field(default_factory=set)


# The calling HTTP session's memory, set per call by AsepriteServer, so calls
# from different sessions can run at once (#33). Unset: the context's own.
_session: ContextVar[SessionMemory | None] = ContextVar("aseprite_mcp_session", default=None)


@dataclass
class ToolContext:
    """Everything a tool needs, in one injectable object."""

    bridge: AsepriteBridge
    config: Config
    _memory: SessionMemory = field(default_factory=SessionMemory, init=False, repr=False)
    _temp_dir: Path | None = field(default=None, init=False, repr=False)

    @property
    def memory(self) -> SessionMemory:
        """This call's session memory: its HTTP session's, else the server's one (stdio)."""
        return _session.get() or self._memory

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
        return await self.bridge.call(
            command, params, timeout=timeout, instance=self.selected_instance(),
            sprite=_sprite_override.get(),
        )

    def selected_instance(self) -> str | None:
        """The window this call goes to: named on the call, else the session's choice."""
        override = _instance_override.get()
        if override is None:
            return self.memory.instance
        # Accept a name or id prefix as select_instance does. Unmatched, it goes
        # through as given, and the bridge reports it as not connected.
        matched = self.bridge.match(override)
        return matched.id if matched else override

    def image_or_note(self, image: Image, label: str) -> Image | str:
        """The image, or one line of text when the agent already has this exact image.

        An image stays in the agent's context for the rest of the session, so
        sending the same one twice pays for it twice. Aseprite writes identical
        PNG bytes for identical pixels, so comparing bytes catches every repeat
        and nothing else, edits made by hand in Aseprite included.

        label names the view ("frame 2, 32x32 source, ...") so the note can point
        at the earlier image. A repeat is skipped only while it is still the
        newest image of its view: after an undo back to an older state, "the
        earlier image" would be ambiguous, so it is sent again.

        Asking again for a view that was just skipped sends the image. That is
        the way back for an agent whose copy was dropped by compaction or a
        cleared conversation, neither of which the server can see.
        """
        memory = self.memory
        digest = hashlib.blake2b(image.data or b"", digest_size=16).hexdigest()
        earlier = memory.image_labels.get(digest)
        repeat = (digest, label)
        if (
            earlier is not None
            and memory.latest_image.get(earlier) == digest
            and repeat not in memory.skipped_images
        ):
            memory.skipped_images.add(repeat)
            seen = (
                "Unchanged since this view's last image"
                if earlier == label
                else f"Identical to the last image of {earlier}"
            )
            return f"{seen}, so it was not sent again. If you no longer have it, call again."

        memory.skipped_images.discard(repeat)
        memory.image_labels[digest] = label
        memory.image_labels.move_to_end(digest)
        memory.latest_image[label] = digest
        while len(memory.image_labels) > MAX_REMEMBERED_IMAGES:
            old_digest, old_label = memory.image_labels.popitem(last=False)
            if memory.latest_image.get(old_label) == old_digest:
                del memory.latest_image[old_label]
            memory.skipped_images = {s for s in memory.skipped_images if s[0] != old_digest}
        return image

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
