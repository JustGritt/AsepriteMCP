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
    async def test_select_by_short_id(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "select_layer", layer="99b35758")
        assert aseprite.last("layer.select")["params"]["layer"] == "99b35758"

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
    async def test_select(self, server, aseprite):
        mcp, _ = server
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


class TestDrawRows:
    async def test_decodes_rows_relative_to_the_origin(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=10, y=20, rows=["a.", " b"], legend={"a": "#f00", "b": "#00ff00"})
        assert aseprite.last("draw.pixels")["params"]["pixels"] == [
            {"x": 10, "y": 20, "color": "#ff0000ff"},
            {"x": 11, "y": 21, "color": "#00ff00ff"},
        ]

    async def test_erase_mode_clears_the_dots(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=0, y=0, rows=["a. "], legend={"a": "#fff"}, blank="erase")
        assert aseprite.last("draw.pixels")["params"]["pixels"] == [
            {"x": 0, "y": 0, "color": "#ffffffff"},
            {"x": 1, "y": 0, "erase": True},
        ]

    async def test_palette_index_legend(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=0, y=0, rows=["k"], legend={"k": 3})
        assert aseprite.last("draw.pixels")["params"]["pixels"] == [{"x": 0, "y": 0, "index": 3}]

    async def test_targets_layer_and_frame(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=0, y=0, rows=["a"], legend={"a": "#fff"}, layer="Arm", frame=2)
        params = aseprite.last("draw.pixels")["params"]
        assert params["layer"] == "Arm" and params["frame"] == 2

    async def test_reuses_the_previous_legend(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=0, y=0, rows=["a"], legend={"a": "#123456"})
        payload = json_of(await ok(mcp, "draw_rows", x=5, y=5, rows=["a"]))
        assert payload["legend"] == "reused"
        assert aseprite.last("draw.pixels")["params"]["pixels"] == [
            {"x": 5, "y": 5, "color": "#123456ff"}
        ]

    async def test_no_legend_to_reuse(self, server, aseprite):
        mcp, _ = server
        assert "legend is required" in await err(mcp, "draw_rows", x=0, y=0, rows=["a"])
        assert not aseprite.requests

    async def test_unknown_character_names_its_position(self, server, aseprite):
        mcp, _ = server
        message = await err(mcp, "draw_rows", x=0, y=0, rows=["aa", "aZ"], legend={"a": "#fff"})
        assert "rows[1][1]" in message and "'Z'" in message
        assert not aseprite.requests

    @pytest.mark.parametrize("key", [".", " ", "ab", ""])
    async def test_reserved_or_long_legend_keys(self, server, aseprite, key):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "draw_rows", x=0, y=0, rows=["a"], legend={key: "#fff"}
        )

    async def test_a_failed_call_does_not_replace_the_remembered_legend(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rows", x=0, y=0, rows=["a"], legend={"a": "#111111"})
        await err(mcp, "draw_rows", x=0, y=0, rows=["b"], legend={"b": "octarine"})
        await ok(mcp, "draw_rows", x=0, y=0, rows=["a"])
        assert aseprite.last("draw.pixels")["params"]["pixels"][0]["color"] == "#111111ff"

    async def test_nothing_to_draw(self, server, aseprite):
        mcp, _ = server
        assert "nothing to draw" in await err(
            mcp, "draw_rows", x=0, y=0, rows=["..", "  "], legend={"a": "#fff"}
        )

    async def test_pixel_cap(self, server, aseprite, config):
        mcp, _ = server
        rows = ["a" * 200] * (config.max_pixels_per_call // 200 + 1)
        assert "TOO_MANY_PIXELS" in await err(
            mcp, "draw_rows", x=0, y=0, rows=rows, legend={"a": "#fff"}
        )
        assert not aseprite.requests


class TestDrawRect:
    async def test_filled(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rect", x=2, y=3, width=3, height=2, color="#fff")
        pixels = aseprite.last("draw.pixels")["params"]["pixels"]
        assert len(pixels) == 6
        assert {(p["x"], p["y"]) for p in pixels} == {(x, y) for x in (2, 3, 4) for y in (3, 4)}

    async def test_outline_skips_the_interior(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "draw_rect", x=0, y=0, width=4, height=3, color="#fff", filled=False)
        points = {(p["x"], p["y"]) for p in aseprite.last("draw.pixels")["params"]["pixels"]}
        assert len(points) == 10
        assert (1, 1) not in points and (2, 1) not in points

    async def test_size_must_be_positive(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "draw_rect", x=0, y=0, width=0, height=3, color="#fff"
        )


# ---------------------------------------------------------------------- cels


class TestCels:
    async def test_shift(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "shift_cel", dy=-1, frame=2)
        assert aseprite.last("cel.shift")["params"] == {"dx": 0, "dy": -1, "frame": 2}

    async def test_shift_by_nothing(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "shift_cel")
        assert not aseprite.requests

    async def test_flip(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "flip_cel", layer="Arm")
        assert aseprite.last("cel.flip")["params"] == {"direction": "horizontal", "layer": "Arm"}

    async def test_copy(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "copy_cel", from_frame=1, to_frame=3, to_layer="Shadow")
        assert aseprite.last("cel.copy")["params"] == {
            "fromFrame": 1, "toFrame": 3, "toLayer": "Shadow",
        }

    async def test_replace_color_everywhere(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "replace_color", from_color="#00f", to_color="#f00", frames="all")
        params = aseprite.last("cel.replaceColor")["params"]
        assert params == {"from": "#0000ffff", "to": "#ff0000ff", "tolerance": 0, "frames": "all"}

    async def test_replace_color_frames_and_region(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "replace_color", from_color="#000", to_color="#111",
                 frames=[1, 3], region=[0, 0, 8, 8])
        params = aseprite.last("cel.replaceColor")["params"]
        assert params["frames"] == [1, 3]
        assert params["region"] == {"x": 0, "y": 0, "width": 8, "height": 8}

    @pytest.mark.parametrize("arguments", [
        {"tolerance": 300}, {"frames": []}, {"to_color": "octarine"}, {"frames": "some"},
    ])
    async def test_replace_color_validation(self, server, aseprite, arguments):
        mcp, _ = server
        call = {"from_color": "#000", "to_color": "#fff", **arguments}
        message = await err(mcp, "replace_color", **call)
        assert "INVALID_PARAMS" in message or "validation" in message.lower()
        assert not aseprite.requests


# ---------------------------------------------------------------------- batch


class TestBatch:
    async def test_sends_one_batch_of_encoded_commands(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 3, "undoSteps": 1, "results": []})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "duplicate_frame", "args": {"frame": 1}},
            {"tool": "shift_cel", "args": {"dy": -1, "frame": 2}},
            {"tool": "draw_rows", "args": {"x": 1, "y": 1, "rows": ["a"], "legend": {"a": "#f00"}, "frame": 2}},
        ]))
        assert payload["applied"] == 3
        sent = [r["command"] for r in aseprite.requests]
        assert sent == ["batch.run"], "nothing may reach Aseprite before the batch itself"
        assert aseprite.last("batch.run")["params"]["ops"] == [
            {"command": "frame.duplicate", "params": {"frame": 1}},
            {"command": "cel.shift", "params": {"dx": 0, "dy": -1, "frame": 2}},
            {"command": "draw.pixels", "params": {
                "pixels": [{"x": 1, "y": 1, "color": "#ff0000ff"}], "frame": 2}},
        ]

    async def test_a_bad_op_stops_the_batch_before_anything_is_sent(self, server, aseprite):
        mcp, _ = server
        message = await err(mcp, "batch", ops=[
            {"tool": "duplicate_frame", "args": {"frame": 1}},
            {"tool": "draw_rows", "args": {"x": 0, "y": 0, "rows": ["Z"], "legend": {"a": "#fff"}}},
        ])
        assert "ops[1] (draw_rows)" in message and "'Z'" in message
        assert not aseprite.requests

    async def test_missing_arguments_name_the_op(self, server, aseprite):
        mcp, _ = server
        message = await err(mcp, "batch", ops=[{"tool": "shift_cel", "args": {"dz": 3}}])
        assert "ops[0] (shift_cel)" in message
        assert not aseprite.requests

    @pytest.mark.parametrize("tool", ["save_sprite", "get_canvas_preview", "undo", "batch", "nope"])
    async def test_only_editing_tools_are_batchable(self, server, aseprite, tool):
        mcp, _ = server
        assert "cannot run inside a batch" in await err(mcp, "batch", ops=[{"tool": tool}])
        assert not aseprite.requests

    async def test_aseprite_rollback_is_reported(self, server, aseprite):
        mcp, _ = server
        aseprite.fail("batch.run", "INVALID_FRAME", "ops[1] (cel.shift) failed, so the whole batch was rolled back")
        message = await err(mcp, "batch", ops=[
            {"tool": "create_frame"}, {"tool": "shift_cel", "args": {"dx": 1, "frame": 9}},
        ])
        assert "INVALID_FRAME" in message and "rolled back" in message

    async def test_preview_shows_the_last_frame_edited(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"written": 1, "frame": 3}]})
        result = await ok(mcp, "batch", preview=True, ops=[
            {"tool": "draw_rect", "args": {"x": 0, "y": 0, "width": 1, "height": 1, "color": "#fff", "frame": 3}},
        ])
        assert len(images(result)) == 1
        assert aseprite.last("render.canvas")["params"]["frame"] == 3

    async def test_direct_calls_are_unaffected_after_a_batch(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1})
        await ok(mcp, "batch", ops=[{"tool": "create_frame"}])
        await ok(mcp, "create_frame")
        assert aseprite.requests[-1]["command"] == "frame.create"


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
        result = await ok(mcp, "get_canvas_preview", layer="Character")
        assert len(images(result)) == 1
        assert "Character" in text_of(result)
        assert aseprite.last("render.layer")["params"]["layer"] == "Character"

    async def test_every_render_carries_the_size_cap(self, server, aseprite, config):
        mcp, _ = server
        await ok(mcp, "get_canvas_preview")
        assert aseprite.last("render.canvas")["params"]["maxEdge"] == config.preview_max_edge
        await ok(mcp, "get_onion_skin_preview")
        assert aseprite.last("render.onionSkin")["params"]["maxEdge"] == config.preview_max_edge
        await ok(mcp, "get_animation_contact_sheet")
        assert aseprite.last("render.contactSheet")["params"]["maxEdge"] == config.sheet_max_edge

    async def test_region_zoom(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", {"frame": 1, "region": [4, 4, 8, 6], "scale": 16})
        result = await ok(mcp, "get_canvas_preview", region=[4, 4, 8, 6], scale=16)
        assert aseprite.last("render.canvas")["params"]["region"] == {
            "x": 4, "y": 4, "width": 8, "height": 6,
        }
        assert "region 4,4 8x6" in text_of(result)

    @pytest.mark.parametrize("region", [[0, 0, 4], [0, 0, 0, 4], [0, 0, 4, -1]])
    async def test_bad_region(self, server, aseprite, region):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "get_canvas_preview", region=region)

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
        aseprite.reply("inspect.palette", {"colors": ["#000000", "#ffffff"]})
        assert json_of(await ok(mcp, "get_palette"))["colors"] == ["#000000", "#ffffff"]


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

    async def test_compare_frames(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("anim.compare", {"changedPixels": 4, "changed": [1, 1, 2, 2]})
        payload = json_of(await ok(mcp, "compare_frames", a=1, b=2, diff_map=True, layer="Arm"))
        assert payload["changedPixels"] == 4
        params = aseprite.last("anim.compare")["params"]
        assert (params["a"], params["b"], params["diffMap"], params["layer"]) == (1, 2, True, "Arm")

    async def test_animation_bounds(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "get_animation_bounds", tag="idle")
        assert aseprite.last("anim.bounds")["params"] == {"tag": "idle"}

    async def test_onion_skin(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.onionSkin", {"frame": 3})
        result = await ok(mcp, "get_onion_skin_preview", frame=3)
        assert len(images(result)) == 1
        assert "previous frame is tinted" in text_of(result)

    async def test_tag_crud(self, server, aseprite):
        mcp, _ = server
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
    "select_layer": {"layer": "Character"},
    "create_layer": {"name": "New"},
    "delete_layer": {"layer": "Character"},
    "set_layer_visibility": {"layer": "Character", "visible": True},
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
    "draw_rows": {"x": 0, "y": 0, "rows": ["a"], "legend": {"a": "#fff"}},
    "draw_rect": {"x": 0, "y": 0, "width": 2, "height": 2, "color": "#fff"},
    "shift_cel": {"dx": 1},
    "flip_cel": {},
    "copy_cel": {"from_frame": 1, "to_frame": 2},
    "replace_color": {"from_color": "#000", "to_color": "#fff"},
    "batch": {"ops": [{"tool": "create_frame"}]},
    "get_canvas_preview": {},
    "get_region": {"x": 0, "y": 0, "width": 4, "height": 4},
    "get_palette": {},
    "get_animation_info": {},
    "compare_frames": {"a": 1, "b": 2},
    "get_animation_bounds": {},
    "get_animation_contact_sheet": {},
    "get_onion_skin_preview": {},
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
