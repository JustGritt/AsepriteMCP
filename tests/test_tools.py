"""Tool surface tests, driven against the fake extension.

These check the half of each tool that lives on the server: argument validation,
the command name and params put on the wire, and how results come back. What the
Lua handlers do with those commands is covered by tests/lua/run_tests.lua.
"""

from __future__ import annotations

import json

import pytest

from mcp.server.mcpserver.exceptions import ToolError

from tests.conftest import json_of, text_of

pytestmark = pytest.mark.asyncio


# The tool name is positional-only: several tools take an argument called
# "name" themselves, which would otherwise collide with the helper parameter.
async def ok(mcp, tool, /, **arguments):
    result = await mcp.call_tool(tool, arguments)
    assert not result.is_error, f"{tool} failed: {text_of(result)}"
    return result


async def err(mcp, tool, /, **arguments) -> str:
    """Return the message the model would see for a failing call.

    A ToolError raised inside a tool comes back as is_error=True, but the SDK
    raises for schema-validation failures, so both paths have to be handled.
    """
    try:
        result = await mcp.call_tool(tool, arguments)
    except ToolError as exc:
        return str(exc)
    assert result.is_error, f"{tool} unexpectedly succeeded: {text_of(result)}"
    return text_of(result)


def images(result):
    return [b for b in result.content if getattr(b, "type", None) == "image"]


# --------------------------------------------------------------------- connection


class TestConnection:
    async def test_reports_disconnected_without_raising(self, server):
        mcp, ctx = server
        # This is the tool the agent uses to diagnose, so it must answer even
        # when nothing is attached.
        payload = json_of(await ok(mcp, "get_connection_status"))
        assert payload["connected"] is False
        assert "hint" in payload
        assert payload["bridge"]["port"] == ctx.bridge.bound_port

    async def test_reports_connected(self, server, aseprite):
        mcp, _ctx = server
        aseprite.reply("app.status", {"documentOpen": True, "document": "attack.aseprite"})
        payload = json_of(await ok(mcp, "get_connection_status"))
        assert payload["connected"] is True
        assert payload["asepriteVersion"] == "1.3.18.3"
        assert payload["document"] == "attack.aseprite"

    async def test_warns_when_files_are_not_writable(self, server, aseprite):
        mcp, _ctx = server
        aseprite.reply("fs.probe", {"canWriteFiles": False})
        payload = json_of(await ok(mcp, "get_connection_status"))
        assert payload["canWriteFiles"] is False
        assert "file-system access" in payload["hint"]

    async def test_probes_writability_on_demand(self, server, aseprite):
        # The probe writes a file, which raises the Aseprite Security modal, so it
        # must be tied to a deliberate action rather than run at startup.
        mcp, _ctx = server
        await ok(mcp, "get_connection_status")
        assert aseprite.last("fs.probe")


# ------------------------------------------------------------------------- sprite


class TestSprite:
    async def test_get_sprite_info(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("sprite.info", {"width": 64, "colorMode": "indexed"})
        payload = json_of(await ok(mcp, "get_sprite_info"))
        assert payload["colorMode"] == "indexed"

    async def test_open_sends_an_absolute_path(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "hero.aseprite").write_bytes(b"")
        await ok(mcp, "open_sprite", path="hero.aseprite")
        sent = aseprite.last("sprite.open")["params"]["path"]
        assert sent.endswith("hero.aseprite")
        assert json.loads(json.dumps(sent))  # plain string, not a Path

    async def test_open_rejects_paths_outside_the_sandbox(self, server, aseprite, tmp_path):
        mcp, _ = server
        message = await err(mcp, "open_sprite", path=str(tmp_path / "outside.aseprite"))
        assert "PATH_NOT_ALLOWED" in message
        assert not aseprite.requests, "nothing should reach Aseprite"

    async def test_open_requires_the_file_to_exist(self, server, aseprite, sandbox):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "open_sprite", path="ghost.aseprite")

    async def test_save_in_place(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "save_sprite")
        assert aseprite.last("sprite.save")["params"] == {}

    async def test_save_to_a_path_creates_parent_directories(self, server, aseprite, sandbox):
        mcp, _ = server
        await ok(mcp, "save_sprite", path="tamer/attack.aseprite")
        assert (sandbox / "tamer").is_dir()
        assert aseprite.last("sprite.save")["params"]["path"].endswith("attack.aseprite")

    async def test_save_refuses_png(self, server, aseprite):
        mcp, _ = server
        assert "PATH_NOT_ALLOWED" in await err(mcp, "save_sprite", path="flat.png")


# ------------------------------------------------------------------------- layers


class TestLayers:
    async def test_list(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("layer.list", {"count": 3})
        assert json_of(await ok(mcp, "list_layers"))["count"] == 3

    async def test_select_by_uuid(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "select_layer", layer="99b35758-225a-45df-ad92-0c230b7c6507")
        assert aseprite.last("layer.select")["params"]["layer"].startswith("99b35758")

    async def test_create_delete_visibility(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "create_layer", name="Character")
        assert aseprite.last("layer.create")["params"] == {"name": "Character"}

        await ok(mcp, "delete_layer", layer="Character")
        assert aseprite.last("layer.delete")["params"] == {"layer": "Character"}

        await ok(mcp, "set_layer_visibility", layer="Character", visible=False)
        assert aseprite.last("layer.setVisibility")["params"] == {
            "layer": "Character",
            "visible": False,
        }

    async def test_layer_errors_surface_with_their_code(self, server, aseprite):
        mcp, _ = server
        aseprite.fail("layer.select", "INVALID_LAYER", "No layer matches 'ghost'.")
        message = await err(mcp, "select_layer", layer="ghost")
        assert "INVALID_LAYER" in message and "ghost" in message


# ------------------------------------------------------------------------- frames


class TestFrames:
    async def test_list_and_select(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("frame.list", {"count": 6})
        assert json_of(await ok(mcp, "list_frames"))["count"] == 6
        await ok(mcp, "select_frame", frame=3)
        assert aseprite.last("frame.select")["params"] == {"frame": 3}

    async def test_create_with_and_without_after(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "create_frame")
        assert aseprite.last("frame.create")["params"] == {}
        await ok(mcp, "create_frame", after=2)
        assert aseprite.last("frame.create")["params"] == {"after": 2}

    async def test_duplicate_and_delete(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "duplicate_frame", frame=3)
        assert aseprite.last("frame.duplicate")["params"] == {"frame": 3}
        await ok(mcp, "delete_frame", frame=4)
        assert aseprite.last("frame.delete")["params"] == {"frame": 4}

    async def test_duration_is_sent_in_milliseconds(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "set_frame_duration", frame=4, duration_ms=60)
        assert aseprite.last("frame.setDuration")["params"] == {"frame": 4, "durationMs": 60}

    @pytest.mark.parametrize("duration", [0, -1, 999_999])
    async def test_implausible_durations_are_rejected(self, server, aseprite, duration):
        mcp, _ = server
        # Catches the classic mistake of passing seconds where ms are expected.
        message = await err(mcp, "set_frame_duration", frame=1, duration_ms=duration)
        assert "INVALID_PARAMS" in message
        assert "millisecond" in message


# ------------------------------------------------------------------------ drawing


class TestDrawing:
    async def test_colors_are_normalised(self, server, aseprite):
        mcp, _ = server
        await ok(
            mcp,
            "draw_pixels",
            pixels=[{"x": 24, "y": 18, "color": "#E6A15C"}, {"x": 25, "y": 18, "color": "#fff"}],
        )
        sent = aseprite.last("draw.pixels")["params"]["pixels"]
        assert sent[0] == {"x": 24, "y": 18, "color": "#e6a15cff"}
        assert sent[1]["color"] == "#ffffffff"

    async def test_batch_level_color_fills_in(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_pixels", pixels=[{"x": 1, "y": 1}, {"x": 2, "y": 2}], color="#ff0000")
        sent = aseprite.last("draw.pixels")["params"]["pixels"]
        assert all(p["color"] == "#ff0000ff" for p in sent)

    async def test_per_pixel_color_wins_over_the_batch_color(self, server, aseprite):
        mcp, _ = server
        await ok(
            mcp,
            "draw_pixels",
            pixels=[{"x": 1, "y": 1, "color": "#00ff00"}, {"x": 2, "y": 2}],
            color="#ff0000",
        )
        sent = aseprite.last("draw.pixels")["params"]["pixels"]
        assert sent[0]["color"] == "#00ff00ff"
        assert sent[1]["color"] == "#ff0000ff"

    async def test_palette_index_passes_through(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_pixels", pixels=[{"x": 1, "y": 1, "index": 5}])
        assert aseprite.last("draw.pixels")["params"]["pixels"][0] == {"x": 1, "y": 1, "index": 5}

    async def test_missing_color_is_reported_with_its_position(self, server, aseprite):
        mcp, _ = server
        message = await err(mcp, "draw_pixels", pixels=[{"x": 1, "y": 1}])
        assert "pixels[0]" in message

    async def test_bad_color_is_rejected_before_reaching_aseprite(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "draw_pixels", pixels=[{"x": 1, "y": 1, "color": "octarine"}]
        )
        assert not aseprite.requests

    async def test_empty_batch(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "draw_pixels", pixels=[])

    async def test_batch_cap(self, server, aseprite, config):
        mcp, _ = server
        oversized = [{"x": i, "y": 0, "color": "#fff"} for i in range(config.max_pixels_per_call + 1)]
        message = await err(mcp, "draw_pixels", pixels=oversized)
        assert "TOO_MANY_PIXELS" in message
        assert not aseprite.requests

    async def test_erase_sends_points_only(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "erase_pixels", pixels=[{"x": 1, "y": 2}])
        assert aseprite.last("draw.erase")["params"]["pixels"] == [{"x": 1, "y": 2}]

    async def test_clear_cel_targets(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "clear_cel")
        assert aseprite.last("draw.clearCel")["params"] == {}
        await ok(mcp, "clear_cel", layer="Character", frame=2)
        assert aseprite.last("draw.clearCel")["params"] == {"layer": "Character", "frame": 2}

    async def test_fill(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "fill", x=4, y=5, color="#123456")
        params = aseprite.last("draw.fill")["params"]
        assert params["x"] == 4 and params["color"] == "#123456ff" and params["tolerance"] == 0

    @pytest.mark.parametrize("tolerance", [-1, 256])
    async def test_fill_tolerance_bounds(self, server, aseprite, tolerance):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "fill", x=0, y=0, color="#fff", tolerance=tolerance
        )

    async def test_draw_line(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_line", x1=0, y1=0, x2=5, y2=5, color="#fff")
        params = aseprite.last("draw.line")["params"]
        assert (params["x1"], params["y1"], params["x2"], params["y2"]) == (0, 0, 5, 5)


# ---------------------------------------------------------------------- inspection


class TestInspection:
    async def test_canvas_preview_returns_an_image(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", {"frame": 2, "width": 32, "height": 32, "scale": 8})
        result = await ok(mcp, "get_canvas_preview", scale=8, frame=2)
        assert len(images(result)) == 1
        assert images(result)[0].mime_type == "image/png"
        assert "nearest-neighbour" in text_of(result)
        assert "frame 2" in text_of(result)

    async def test_preview_temp_file_is_cleaned_up(self, server, aseprite, tmp_path):
        mcp, ctx = server
        await ok(mcp, "get_canvas_preview")
        out_path = aseprite.last("render.canvas")["params"]["outPath"]
        assert not __import__("pathlib").Path(out_path).exists()

    async def test_preview_reports_a_reduced_scale(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", {"scale": 4, "requestedScale": 32, "scaleReduced": True})
        assert "scale reduced from 32" in text_of(await ok(mcp, "get_canvas_preview", scale=32))

    async def test_preview_warns_about_an_empty_canvas(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", {"empty": True})
        assert "entirely transparent" in text_of(await ok(mcp, "get_canvas_preview"))

    @pytest.mark.parametrize("scale", [0, -1, 33])
    async def test_scale_bounds(self, server, aseprite, scale):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "get_canvas_preview", scale=scale)

    async def test_missing_png_is_reported_clearly(self, server, aseprite):
        mcp, _ = server

        # Simulate the file-access trust prompt not having been granted.
        def swallow(params):
            path = __import__("pathlib").Path(params["outPath"])
            if path.exists():
                path.unlink()
            return {}

        aseprite.reply("render.canvas", swallow)
        message = await err(mcp, "get_canvas_preview")
        assert "SETUP.md" in message

    async def test_layer_preview(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.layer", {"layer": "Character", "frame": 1})
        result = await ok(mcp, "get_layer_preview", layer="Character")
        assert len(images(result)) == 1
        assert "Character" in text_of(result)

    async def test_get_region(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("inspect.region", {"rows": ["..a.", "aaaa"], "legend": {"a": "#ff0000ff"}})
        payload = json_of(await ok(mcp, "get_region", x=0, y=0, width=4, height=2))
        assert payload["rows"] == ["..a.", "aaaa"]

    async def test_region_cap(self, server, aseprite, config):
        mcp, _ = server
        message = await err(mcp, "get_region", x=0, y=0, width=200, height=200)
        assert "TOO_MANY_PIXELS" in message
        assert not aseprite.requests

    @pytest.mark.parametrize(("w", "h"), [(0, 4), (4, 0), (-1, 4)])
    async def test_region_dimensions(self, server, aseprite, w, h):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "get_region", x=0, y=0, width=w, height=h)

    async def test_get_palette(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("inspect.palette", {"size": 16})
        assert json_of(await ok(mcp, "get_palette"))["size"] == 16


# ---------------------------------------------------------------------- animation


class TestAnimation:
    async def test_animation_info(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("anim.info", {"tag": "attack", "durationsMs": [80, 80, 50]})
        payload = json_of(await ok(mcp, "get_animation_info", tag="attack"))
        assert payload["durationsMs"] == [80, 80, 50]

    async def test_contact_sheet_summarises_its_cells(self, server, aseprite):
        mcp, _ = server
        aseprite.reply(
            "render.contactSheet",
            {
                "frameCount": 3,
                "scale": 4,
                "cells": [
                    {"frame": 1, "durationMs": 80, "tags": ["idle", "attack"]},
                    {"frame": 2, "durationMs": 80, "tags": ["attack"]},
                    {"frame": 3, "durationMs": 120, "tags": []},
                ],
            },
        )
        result = await ok(mcp, "get_animation_contact_sheet", scale=4)
        assert len(images(result)) == 1
        summary = text_of(result)
        # Overlapping tags must all be reported, not just the first.
        assert "F1 80ms [idle, attack]" in summary
        assert "F2 80ms [attack]" in summary
        assert "F3 120ms;" in summary or summary.endswith("F3 120ms")

    async def test_contact_sheet_columns_validation(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "get_animation_contact_sheet", columns=0)

    async def test_onion_skin(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.onionSkin", {"frame": 3})
        result = await ok(mcp, "get_onion_skin_preview", frame=3)
        assert len(images(result)) == 1
        assert "previous frame is tinted" in text_of(result)

    async def test_tag_crud(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "list_animation_tags")

        await ok(mcp, "create_animation_tag", name="attack", from_frame=1, to_frame=6)
        params = aseprite.last("tag.create")["params"]
        assert params == {
            "name": "attack",
            "from": 1,
            "to": 6,
            "direction": "forward",
            "repeats": 0,
        }

        await ok(mcp, "update_animation_tag", name="attack", new_name="slash")
        assert aseprite.last("tag.update")["params"] == {"name": "attack", "newName": "slash"}

        await ok(mcp, "delete_animation_tag", name="slash")
        assert aseprite.last("tag.delete")["params"] == {"name": "slash"}

    async def test_update_with_nothing_to_change(self, server, aseprite):
        mcp, _ = server
        assert "Nothing to update" in await err(mcp, "update_animation_tag", name="attack")

    async def test_direction_is_constrained(self, server, aseprite):
        mcp, _ = server
        assert await err(
            mcp, "create_animation_tag", name="a", from_frame=1, to_frame=2, direction="sideways"
        )


# ------------------------------------------------------------------------ history


class TestHistory:
    async def test_undo_redo(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "undo")
        assert aseprite.last("history.undo")["command"] == "history.undo"
        await ok(mcp, "redo")
        assert aseprite.last("history.redo")["command"] == "history.redo"


# ---------------------------------------------------------------------- completeness


MINIMAL_ARGUMENTS = {
    "get_connection_status": {},
    "get_sprite_info": {},
    "open_sprite": {"path": "fixture.aseprite"},
    "save_sprite": {},
    "list_layers": {},
    "select_layer": {"layer": "Character"},
    "create_layer": {"name": "New"},
    "delete_layer": {"layer": "Character"},
    "set_layer_visibility": {"layer": "Character", "visible": True},
    "list_frames": {},
    "select_frame": {"frame": 1},
    "create_frame": {},
    "duplicate_frame": {"frame": 1},
    "delete_frame": {"frame": 1},
    "set_frame_duration": {"frame": 1, "duration_ms": 80},
    "draw_pixels": {"pixels": [{"x": 0, "y": 0, "color": "#fff"}]},
    "erase_pixels": {"pixels": [{"x": 0, "y": 0}]},
    "clear_cel": {},
    "fill": {"x": 0, "y": 0, "color": "#fff"},
    "draw_line": {"x1": 0, "y1": 0, "x2": 1, "y2": 1, "color": "#fff"},
    "get_canvas_preview": {},
    "get_layer_preview": {"layer": "Character"},
    "get_region": {"x": 0, "y": 0, "width": 4, "height": 4},
    "get_palette": {},
    "get_animation_info": {},
    "get_animation_contact_sheet": {},
    "get_onion_skin_preview": {},
    "list_animation_tags": {},
    "create_animation_tag": {"name": "idle", "from_frame": 1, "to_frame": 2},
    "update_animation_tag": {"name": "idle", "new_name": "walk"},
    "delete_animation_tag": {"name": "idle"},
    "undo": {},
    "redo": {},
}


async def test_every_registered_tool_is_covered(server):
    """Guards against a tool being added without a smoke test."""
    mcp, _ = server
    registered = {tool.name for tool in await mcp.list_tools()}
    assert registered == set(MINIMAL_ARGUMENTS), (
        f"missing: {registered - set(MINIMAL_ARGUMENTS)}, "
        f"stale: {set(MINIMAL_ARGUMENTS) - registered}"
    )


@pytest.mark.parametrize("name", sorted(MINIMAL_ARGUMENTS))
async def test_tool_smoke(server, aseprite, sandbox, name):
    """Every tool completes against a cooperative extension."""
    mcp, _ = server
    (sandbox / "fixture.aseprite").write_bytes(b"")
    await ok(mcp, name, **MINIMAL_ARGUMENTS[name])


@pytest.mark.parametrize("name", sorted(MINIMAL_ARGUMENTS))
async def test_tools_report_disconnection(server, sandbox, name):
    """With no extension attached, every tool fails with a usable message.

    get_connection_status is the exception by design: it must still answer.
    """
    mcp, _ = server
    (sandbox / "fixture.aseprite").write_bytes(b"")
    if name == "get_connection_status":
        result = await mcp.call_tool(name, MINIMAL_ARGUMENTS[name])
        assert not result.is_error
        return
    assert "ASEPRITE_NOT_CONNECTED" in await err(mcp, name, **MINIMAL_ARGUMENTS[name])


async def test_tools_have_descriptions(server):
    """The descriptions carry the workflow guidance, so none may be blank."""
    mcp, _ = server
    for tool in await mcp.list_tools():
        assert tool.description and len(tool.description) > 40, tool.name
