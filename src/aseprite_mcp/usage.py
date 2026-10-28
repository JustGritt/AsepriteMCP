"""What each tool call costs the model, in bytes and image tokens.

The fake-extension tests can size individual replies, but only a real session
shows where the tokens actually go: which tools get called, how often, how big
the arguments the model had to write were, and how many images it was shown.
Setting ASEPRITE_MCP_USAGE_LOG=<path.jsonl> appends one line per call, e.g.

    {"tool":"draw_rows","argBytes":412,"textBytes":96,"ms":38}
    {"tool":"get_canvas_preview","argBytes":2,"textBytes":61,"images":[[256,256]],"imageTokens":88,"ms":51}

argBytes is the closest proxy for output tokens, which are the expensive kind.
"""

from __future__ import annotations

import base64
import json
import logging
import math
import re
import time
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

# Current Claude models downscale an image past either limit before counting
# it, so nothing can cost more than MAX_IMAGE_TOKENS. Below the limits an image
# costs about width * height / PIXELS_PER_TOKEN.
MAX_IMAGE_EDGE = 2576
MAX_IMAGE_PIXELS = 3_750_000
MAX_IMAGE_TOKENS = 4784
PIXELS_PER_TOKEN = 750


def estimate_image_tokens(width: int, height: int) -> int:
    if width <= 0 or height <= 0:
        return 0
    shrink = min(
        1.0,
        MAX_IMAGE_EDGE / max(width, height),
        math.sqrt(MAX_IMAGE_PIXELS / (width * height)),
    )
    tokens = math.ceil(width * shrink * height * shrink / PIXELS_PER_TOKEN)
    return min(MAX_IMAGE_TOKENS, tokens)


def png_size(data: bytes) -> tuple[int, int] | None:
    """Width and height from a PNG's IHDR chunk, without decoding the image."""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def measure(result: Any) -> dict[str, Any]:
    """Text bytes and image sizes of a CallToolResult's content blocks."""
    text_bytes = 0
    images: list[list[int]] = []
    for block in getattr(result, "content", None) or []:
        kind = getattr(block, "type", None)
        if kind == "text":
            text_bytes += len(block.text.encode("utf-8"))
        elif kind == "image":
            # 32 base64 characters decode to the 24 bytes that hold IHDR.
            size = png_size(base64.b64decode(block.data[:32]))
            if size:
                images.append(list(size))
    entry: dict[str, Any] = {"textBytes": text_bytes}
    if images:
        entry["images"] = images
        entry["imageTokens"] = sum(estimate_image_tokens(w, h) for w, h in images)
    return entry


def error_code(message: str) -> str:
    """The CODE of a 'CODE: message' failure, which the SDK may have prefixed."""
    match = re.search(r"\b([A-Z][A-Z0-9_]{2,}):", message)
    return match.group(1) if match else message[:80]


class UsageLog:
    def __init__(self, path: Path) -> None:
        self.path = path

    def record(
        self,
        tool: str,
        arguments: dict[str, Any],
        result: Any,
        seconds: float,
        error: str | None = None,
    ) -> None:
        entry: dict[str, Any] = {
            "t": round(time.time(), 3),
            "tool": tool,
            "argBytes": len(json.dumps(arguments, separators=(",", ":"), ensure_ascii=False)),
        }
        if result is not None:
            entry.update(measure(result))
            if getattr(result, "is_error", False):
                text = "".join(
                    b.text for b in result.content if getattr(b, "type", None) == "text"
                )
                error = error or text
        if error:
            entry["error"] = error_code(error)
        entry["ms"] = round(seconds * 1000)

        # Accounting must never be the reason a tool call fails.
        try:
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
        except OSError as exc:
            log.warning("Could not write usage log %s: %s", self.path, exc)
