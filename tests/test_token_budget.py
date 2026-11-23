"""Token budgets: size guards on what the model reads and writes.

Every byte here reaches the model. Tool definitions go with every request,
replies stay in its context for the rest of the session, and tool arguments are
written by the model as output tokens, the most expensive kind. These tests pin
the sizes so a change cannot quietly grow them back. `pytest -s` prints the
numbers to quote in a PR.

Sizes are in bytes. Exact token counts need the API; see
scripts/measure_tokens.py.
"""

from __future__ import annotations

import json
from dataclasses import replace

import pytest

from aseprite_mcp.usage import MAX_IMAGE_TOKENS, estimate_image_tokens, png_size

from tests.conftest import text_of, tiny_png

# Measured on 41 tools (15 160 bytes), plus a little headroom. Raise this only on
# purpose, for a tool that earns its place:
# - new_sprite, ~560 bytes: without it an agent cannot start a sprite at all (#12).
# - import_spritesheet and export_spritesheet, ~1 190 bytes: without them a game's
#   sprite sheet cannot get in as frames or back out as a PNG.
# - the rig (split_layer, define_rig, pose_frame, refresh_rig, get_region
#   by_layer), ~2 480 bytes: without it an agent animated each character through
#   hundreds of lines of throwaway pixel scripts and full-frame draw_rows
#   (docs/ANIMATION.md).
# - select_instance, ~330 bytes: without it, two Aseprite windows on one server
#   cannot be told apart and every call is refused (docs/SETUP.md).
# - export_poses and import_poses, ~870 bytes: without them a character that
#   shares a body is animated again from scratch, pose by pose (#32).
# - import_image, ~615 bytes: without it a reference image needed a throwaway
#   script to shrink it and its own document to hold it (#23).
TOOL_LIST_BUDGET = 19_700


def compact(value) -> int:
    return len(json.dumps(value, separators=(",", ":"), ensure_ascii=False))


@pytest.fixture
def config(config, tmp_path):
    """The shared config, with the usage log switched on."""
    return replace(config, usage_log=tmp_path / "usage.jsonl")


def blob_sprite(size: int = 32) -> list[str]:
    """A deterministic 4-color test sprite: an outlined disc with a highlight."""
    centre, radius = size / 2 - 0.5, size / 2 - 3
    rows = []
    for y in range(size):
        row = ""
        for x in range(size):
            d = ((x - centre) ** 2 + (y - centre) ** 2) ** 0.5
            if d > radius:
                row += "."
            elif d > radius - 1.5:
                row += "o"
            elif (x - centre + 4) ** 2 + (y - centre + 4) ** 2 < 12:
                row += "h"
            elif y > centre + 3:
                row += "s"
            else:
                row += "b"
        rows.append(row)
    return rows


LEGEND = {"o": "#222034", "b": "#5b6ee1", "s": "#3f3f74", "h": "#cbdbfc"}


async def test_tool_list_budget(server):
    mcp, _ = server
    tools = await mcp.list_tools()
    sizes = {
        t.name: compact(t.model_dump(mode="json", by_alias=True, exclude_none=True))
        for t in tools
    }
    total = sum(sizes.values())
    print(f"\ntools/list: {len(tools)} tools, {total} bytes")
    for name, size in sorted(sizes.items(), key=lambda kv: -kv[1])[:5]:
        print(f"  {name}: {size}")
    assert total <= TOOL_LIST_BUDGET, f"tools/list grew to {total} bytes"


async def test_listed_schemas_carry_no_pydantic_boilerplate(server):
    mcp, _ = server
    for tool in await mcp.list_tools():
        text = json.dumps(tool.input_schema)
        assert '"title"' not in text, tool.name
        assert '{"type": "null"}' not in text, tool.name


async def test_slimmed_schemas_still_validate(server, aseprite):
    """The listed schema is slimmer, but arguments are checked against the full one."""
    mcp, _ = server
    with pytest.raises(Exception, match="frame"):
        await mcp.call_tool("select_frame", {"frame": "three"})
    result = await mcp.call_tool("get_canvas_preview", {"frame": None})
    assert not result.is_error, "an explicit null for an optional argument still works"


async def test_no_tool_sends_its_reply_twice(server):
    """structuredContent would repeat every JSON reply as an escaped string."""
    mcp, _ = server
    assert [t.name for t in await mcp.list_tools() if t.output_schema] == []
    result = await mcp.call_tool("get_connection_status", {})
    assert result.structured_content is None


async def test_replies_are_compact_json(server, aseprite):
    mcp, _ = server
    aseprite.reply("sprite.info", {"width": 32, "height": 32, "activeLayer": None})
    text = text_of(await mcp.call_tool("get_sprite_info", {}))
    assert "\n" not in text and ": " not in text
    assert "null" not in text, "None values should be dropped, not sent"


async def test_draw_rows_costs_a_fraction_of_draw_pixels(server, aseprite):
    """The same 32x32 art, written both ways, must reach Aseprite identically."""
    mcp, _ = server
    rows = blob_sprite()
    pixels = [
        {"x": x, "y": y, "color": LEGEND[char]}
        for y, row in enumerate(rows)
        for x, char in enumerate(row)
        if char != "."
    ]
    as_pixels = {"pixels": pixels}
    as_rows = {"x": 0, "y": 0, "rows": rows, "legend": LEGEND}

    await mcp.call_tool("draw_pixels", as_pixels)
    sent_by_pixels = aseprite.last("draw.pixels")["params"]["pixels"]
    await mcp.call_tool("draw_rows", as_rows)
    sent_by_rows = aseprite.last("draw.pixels")["params"]["pixels"]
    assert sent_by_rows == sent_by_pixels

    pixel_bytes, row_bytes = compact(as_pixels), compact(as_rows)
    print(
        f"\n32x32, {len(pixels)} px: draw_pixels args {pixel_bytes} bytes, "
        f"draw_rows args {row_bytes} bytes ({pixel_bytes / row_bytes:.0f}x smaller)"
    )
    assert row_bytes * 10 <= pixel_bytes


async def test_batch_reply_does_not_grow_with_its_ops(server, aseprite):
    """Most of a per-op reply repeats what the agent just sent, and stays in context."""
    mcp, _ = server

    async def reply_size(count: int) -> int:
        aseprite.reply("batch.run", {"applied": count, "undoSteps": 1, "results": [
            {"written": 8, "changed": [i % 90, 57, 8, 1], "layer": "Cliff", "frame": 1}
            for i in range(count)
        ]})
        ops = [
            {"tool": "draw_line", "args": {"x1": 0, "y1": 57, "x2": 7, "y2": 57, "color": "#fff"}}
        ] * count
        return len(text_of(await mcp.call_tool("batch", {"ops": ops})))

    small, large = await reply_size(5), await reply_size(100)
    print(f"\nbatch reply: {small} bytes for 5 ops, {large} bytes for 100 ops")
    assert large <= small + 4, "only the counts themselves may get longer"
    assert large <= 120


async def test_usage_log_records_every_call(server, aseprite, config):
    mcp, _ = server
    await mcp.call_tool("get_sprite_info", {})
    await mcp.call_tool("get_canvas_preview", {})
    with pytest.raises(Exception, match="INVALID_PARAMS"):
        await mcp.call_tool("set_frame_duration", {"frame": 1, "duration_ms": 0})

    entries = [json.loads(line) for line in config.usage_log.read_text().splitlines()]
    assert [e["tool"] for e in entries] == [
        "get_sprite_info", "get_canvas_preview", "set_frame_duration",
    ]
    info, preview, failed = entries
    assert info["argBytes"] == 2 and info["textBytes"] > 0 and "images" not in info
    assert preview["images"] == [[1, 1]] and preview["imageTokens"] == 1
    assert failed["error"] == "INVALID_PARAMS"


def test_png_size_reads_the_header():
    assert png_size(tiny_png()) == (1, 1)
    assert png_size(b"not a png") is None


@pytest.mark.parametrize(
    ("width", "height", "tokens"),
    [
        (256, 256, 88),
        (768, 768, 787),
        (1092, 1092, 1590),
        (2576, 2576, MAX_IMAGE_TOKENS),
        (8000, 200, 222),  # a long strip is shrunk to a 2576 px edge first
    ],
)
def test_image_token_estimate(width, height, tokens):
    assert estimate_image_tokens(width, height) == tokens
