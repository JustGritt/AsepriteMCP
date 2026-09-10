"""Color parsing."""

from __future__ import annotations

import pytest

from aseprite_mcp.bridge.protocol import BridgeError, ErrorCode
from aseprite_mcp.colors import normalize_color


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("#E6A15C", "#e6a15cff"),
        ("e6a15c", "#e6a15cff"),
        ("#E6A15C80", "#e6a15c80"),
        ("#fff", "#ffffffff"),
        ("#f00a", "#ff0000aa"),
        ("  #FF0000  ", "#ff0000ff"),
        ("#00000000", "#00000000"),
    ],
)
def test_accepted_forms(raw, expected):
    assert normalize_color(raw) == expected


@pytest.mark.parametrize(
    "raw",
    ["", "#", "#12", "#12345", "#1234567", "#123456789", "red", "#gggggg", "0x00ff00"],
)
def test_rejected_forms(raw):
    with pytest.raises(BridgeError) as excinfo:
        normalize_color(raw)
    assert excinfo.value.code is ErrorCode.INVALID_PARAMS


def test_rejects_non_strings():
    with pytest.raises(BridgeError):
        normalize_color(0xFF0000)  # type: ignore[arg-type]


def test_normalisation_is_idempotent():
    assert normalize_color(normalize_color("#abc")) == normalize_color("#abc")
