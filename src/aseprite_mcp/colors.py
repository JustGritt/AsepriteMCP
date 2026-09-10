"""Color parsing shared by the drawing tools.

Format is validated here so a typo produces a clear message without a round trip
to Aseprite. Mapping a color onto an actual pixel value is the job of the Lua
side, which is the only place that knows the color mode of the document and, for
indexed sprites, the palette.
"""

from __future__ import annotations

import re

from .bridge.protocol import BridgeError, ErrorCode

_HEX = re.compile(r"^#?([0-9a-fA-F]{3,8})$")


def normalize_color(value: str) -> str:
    """Return a canonical ``#RRGGBBAA`` string.

    Accepts ``#RGB``, ``#RGBA``, ``#RRGGBB`` and ``#RRGGBBAA``, with or without
    the leading ``#``. Anything else raises INVALID_PARAMS.
    """
    if not isinstance(value, str):
        raise BridgeError(
            ErrorCode.INVALID_PARAMS, f"Color must be a hex string, got {type(value).__name__}."
        )

    match = _HEX.match(value.strip())
    if not match:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"Could not parse color {value!r}. Use #RGB, #RGBA, #RRGGBB or #RRGGBBAA.",
        )

    digits = match.group(1).lower()
    if len(digits) in (3, 4):
        digits = "".join(ch * 2 for ch in digits)
    if len(digits) == 6:
        digits += "ff"
    if len(digits) != 8:
        raise BridgeError(
            ErrorCode.INVALID_PARAMS,
            f"Color {value!r} has {len(match.group(1))} hex digits; expected 3, 4, 6 or 8.",
        )
    return f"#{digits}"


TRANSPARENT = "#00000000"
