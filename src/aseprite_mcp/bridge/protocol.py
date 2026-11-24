"""Wire protocol between the MCP server and the Aseprite Lua extension.

One JSON object per WebSocket text message, as specified in docs/ASEPRITE_MCP.md
section 7. This module is deliberately free of asyncio and websockets imports so
the encoding rules can be unit-tested in isolation, and so ``protocol.lua`` has a
single obvious counterpart to mirror.

    request   {"id": 42, "command": "frame.duplicate", "params": {...}, "sprite": 3}
    success   {"id": 42, "ok": true,  "result": {...}}
    failure   {"id": 42, "ok": false, "error": {"code": "...", "message": "..."}}
"""

from __future__ import annotations

import json
from enum import Enum
from typing import Any

from mcp.server.mcpserver.exceptions import ToolError


class ErrorCode(str, Enum):
    """Every failure the bridge can report.

    Kept in sync with ``ERROR`` in extension/aseprite-mcp/protocol.lua.
    """

    ASEPRITE_NOT_CONNECTED = "ASEPRITE_NOT_CONNECTED"
    NO_ACTIVE_SPRITE = "NO_ACTIVE_SPRITE"
    INVALID_FRAME = "INVALID_FRAME"
    INVALID_LAYER = "INVALID_LAYER"
    INVALID_PARAMS = "INVALID_PARAMS"
    PATH_NOT_ALLOWED = "PATH_NOT_ALLOWED"
    TIMEOUT = "TIMEOUT"
    DOCUMENT_LOCKED = "DOCUMENT_LOCKED"
    UNSUPPORTED_COLOR_MODE = "UNSUPPORTED_COLOR_MODE"
    TOO_MANY_PIXELS = "TOO_MANY_PIXELS"
    UNKNOWN_COMMAND = "UNKNOWN_COMMAND"
    PROTOCOL_ERROR = "PROTOCOL_ERROR"
    LUA_ERROR = "LUA_ERROR"
    UNAUTHORIZED = "UNAUTHORIZED"
    # Server-side only: several Aseprite windows are connected and the session
    # has not chosen one, so a command has nowhere safe to go.
    INSTANCE_REQUIRED = "INSTANCE_REQUIRED"
    # Server-side only: the window's extension differs from the server's copy,
    # so its replies cannot be trusted to mean what the tools expect (#16).
    EXTENSION_OUTDATED = "EXTENSION_OUTDATED"


class BridgeError(ToolError):
    """A structured failure that a tool surfaces verbatim to the agent.

    Subclassing ToolError is load-bearing rather than cosmetic. The SDK only
    forwards the message of a ToolError to the model; every other exception is
    treated as a crash and reported as a bare "Error executing tool <name>",
    which would hide the error code and the remedy from the one reader who needs
    them. Since every BridgeError is a failure we anticipated, this makes the
    right thing happen without each tool having to remember to convert.
    """

    def __init__(self, code: ErrorCode, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"code": self.code.value, "message": self.message}
        if self.details:
            out["details"] = self.details
        return out

    def __str__(self) -> str:  # what the agent reads in the tool error
        return f"{self.code.value}: {self.message}"


def encode_request(
    request_id: int, command: str, params: dict[str, Any] | None = None, sprite: Any = None
) -> str:
    """Serialise an outbound request. Compact separators keep frames small.

    sprite, when given, names the sprite the extension makes active before it
    runs the command (#34).
    """
    payload: dict[str, Any] = {"id": request_id, "command": command, "params": params or {}}
    if sprite is not None:
        payload["sprite"] = sprite
    return json.dumps(payload, separators=(",", ":"))


def decode_message(raw: str | bytes) -> dict[str, Any]:
    """Parse an inbound frame, raising BridgeError rather than json errors.

    Anything that is not a JSON object is a protocol violation: the Lua side
    always sends one object per message.
    """
    if isinstance(raw, (bytes, bytearray)):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BridgeError(ErrorCode.PROTOCOL_ERROR, f"Message is not valid UTF-8: {exc}") from exc
    try:
        message = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(ErrorCode.PROTOCOL_ERROR, f"Message is not valid JSON: {exc}") from exc
    if not isinstance(message, dict):
        raise BridgeError(
            ErrorCode.PROTOCOL_ERROR,
            f"Expected a JSON object, got {type(message).__name__}.",
        )
    return message


def error_from_response(message: dict[str, Any]) -> BridgeError:
    """Turn an ``ok: false`` response into a BridgeError.

    Tolerates a malformed error body: a Lua handler that fails in an unexpected
    way must still produce a usable error rather than a KeyError here.
    """
    error = message.get("error")
    if not isinstance(error, dict):
        return BridgeError(ErrorCode.PROTOCOL_ERROR, f"Malformed error payload: {error!r}")
    raw_code = error.get("code", "")
    try:
        code = ErrorCode(raw_code)
    except ValueError:
        code = ErrorCode.LUA_ERROR
    text = error.get("message") or f"Aseprite reported {raw_code or 'an unspecified error'}."
    details = error.get("details")
    return BridgeError(code, str(text), details if isinstance(details, dict) else None)
