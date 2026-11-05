"""Tool surface tests, driven against the fake extension.

These check the half of each tool that lives on the server: argument validation,
the command name and params put on the wire, and how results come back. What the
Lua handlers do with those commands is covered by tests/lua/run_tests.lua.
"""

from __future__ import annotations

import json

import pytest

from mcp.server.mcpserver import Image
from mcp.server.mcpserver.exceptions import ToolError

from aseprite_mcp.tools.base import MAX_REMEMBERED_IMAGES
from tests.conftest import json_of, text_of, tiny_png

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

    async def test_new_sprite(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "new_sprite", width=32, height=16)
        assert aseprite.last("sprite.new")["params"] == {"width": 32, "height": 16, "colorMode": "rgb"}

    async def test_new_sprite_saved_into_the_sandbox(self, server, aseprite, sandbox):
        mcp, _ = server
        await ok(mcp, "new_sprite", width=16, height=16, color_mode="indexed", path="icons/potion.aseprite")
        params = aseprite.last("sprite.new")["params"]
        assert params["path"] == str(sandbox / "icons" / "potion.aseprite")
        assert params["colorMode"] == "indexed"
        assert (sandbox / "icons").is_dir(), "parent directory is created for Aseprite to write into"

    async def test_new_sprite_never_overwrites(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "hero.aseprite").write_bytes(b"work")
        message = await err(mcp, "new_sprite", width=8, height=8, path="hero.aseprite")
        assert "already exists" in message
        assert not aseprite.requests

    @pytest.mark.parametrize(("w", "h"), [(0, 8), (8, 0), (1025, 8)])
    async def test_new_sprite_size_limits(self, server, aseprite, w, h):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "new_sprite", width=w, height=h)
        assert not aseprite.requests

    async def test_new_sprite_rejects_png(self, server, aseprite):
        mcp, _ = server
        assert "PATH_NOT_ALLOWED" in await err(mcp, "new_sprite", width=8, height=8, path="flat.png")

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

    async def test_save_in_place(self, server, aseprite, sandbox):
        mcp, _ = server
        own_file = str(sandbox / "hero.aseprite")
        aseprite.reply("sprite.info", {"path": own_file})
        await ok(mcp, "save_sprite")
        # Lua checks this against the active document, so switching tabs after
        # the sandbox check cannot redirect the save.
        assert aseprite.last("sprite.save")["params"] == {"expectedPath": own_file}

    async def test_save_in_place_refuses_a_file_outside_the_sandbox(
        self, server, aseprite, tmp_path
    ):
        mcp, _ = server
        aseprite.reply("sprite.info", {"path": str(tmp_path / "outside.aseprite")})
        message = await err(mcp, "save_sprite")
        assert "PATH_NOT_ALLOWED" in message
        assert "Pass a path" in message
        assert not [r for r in aseprite.requests if r["command"] == "sprite.save"]

    async def test_save_in_place_refuses_a_png(self, server, aseprite, sandbox):
        mcp, _ = server
        aseprite.reply("sprite.info", {"path": str(sandbox / "flat.png")})
        message = await err(mcp, "save_sprite")
        assert "PATH_NOT_ALLOWED" in message
        # The sandbox's own message ends without a stop, and this one follows it.
        assert ".aseprite. Pass a path" in message
        assert not [r for r in aseprite.requests if r["command"] == "sprite.save"]

    @pytest.mark.parametrize("name", ["", "Sprite", "hero.aseprite"])
    async def test_save_in_place_needs_a_real_file(self, server, aseprite, name):
        # A sprite created by script reports "Sprite", and one named like a file
        # must not be resolved against the sandbox root and pass.
        mcp, _ = server
        aseprite.reply("sprite.info", {"path": name})
        message = await err(mcp, "save_sprite")
        assert "never been saved" in message
        assert not [r for r in aseprite.requests if r["command"] == "sprite.save"]

    async def test_save_to_a_path_creates_parent_directories(self, server, aseprite, sandbox):
        mcp, _ = server
        await ok(mcp, "save_sprite", path="tamer/attack.aseprite")
        assert (sandbox / "tamer").is_dir()
        assert aseprite.last("sprite.save")["params"]["path"].endswith("attack.aseprite")

    async def test_save_refuses_png(self, server, aseprite):
        mcp, _ = server
        assert "PATH_NOT_ALLOWED" in await err(mcp, "save_sprite", path="flat.png")


# ------------------------------------------------------------------- sprite sheets


class TestImportSpritesheet:
    async def test_sends_only_what_was_chosen(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"")
        await ok(mcp, "import_spritesheet", path="sheet.png", frame_width=16, frame_height=32)
        assert aseprite.last("sprite.importSheet")["params"] == {
            "path": str(sandbox / "sheet.png"),
            "frameWidth": 16,
            "frameHeight": 32,
            "x": 0,
            "y": 0,
        }

    async def test_sends_an_area(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"")
        await ok(
            mcp, "import_spritesheet", path="sheet.png", frame_width=32, frame_height=48,
            x=0, y=192, columns=2, rows=3,
        )
        params = aseprite.last("sprite.importSheet")["params"]
        assert (params["y"], params["columns"], params["rows"]) == (192, 2, 3)

    @pytest.mark.parametrize(
        "bad",
        [
            {"frame_width": 0}, {"frame_height": 0}, {"frame_width": 1025},
            {"x": -1}, {"y": -1}, {"columns": 0}, {"rows": 0},
        ],
    )
    async def test_rejects_bad_numbers(self, server, aseprite, sandbox, bad):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"")
        arguments = {"path": "sheet.png", "frame_width": 16, "frame_height": 32, **bad}
        assert "INVALID_PARAMS" in await err(mcp, "import_spritesheet", **arguments)
        assert not aseprite.requests

    async def test_stays_in_the_sandbox(self, server, aseprite, tmp_path):
        mcp, _ = server
        (tmp_path / "outside.png").write_bytes(b"")
        message = await err(
            mcp, "import_spritesheet", path=str(tmp_path / "outside.png"),
            frame_width=16, frame_height=32,
        )
        assert "PATH_NOT_ALLOWED" in message
        assert not aseprite.requests

    async def test_only_reads_png(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "hero.aseprite").write_bytes(b"")
        assert "PATH_NOT_ALLOWED" in await err(
            mcp, "import_spritesheet", path="hero.aseprite", frame_width=16, frame_height=32
        )

    async def test_needs_the_file(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "import_spritesheet", path="ghost.png", frame_width=16, frame_height=32
        )


class TestExportSpritesheet:
    async def test_writes_a_new_png(self, server, aseprite, sandbox):
        mcp, _ = server
        await ok(mcp, "export_spritesheet", path="out/sheet.png", columns=4)
        assert (sandbox / "out").is_dir(), "parent directory is created for Aseprite to write into"
        assert aseprite.last("sprite.exportSheet")["params"] == {
            "path": str(sandbox / "out" / "sheet.png"),
            "columns": 4,
        }

    async def test_sends_a_tag(self, server, aseprite):
        mcp, _ = server
        await ok(mcp, "export_spritesheet", path="walk.png", tag="walk")
        assert aseprite.last("sprite.exportSheet")["params"]["tag"] == "walk"

    async def test_never_replaces_a_file_by_accident(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"work")
        message = await err(mcp, "export_spritesheet", path="sheet.png")
        assert "already exists" in message
        assert "onto" in message
        assert not aseprite.requests

    async def test_onto_a_different_file_still_needs_a_new_path(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"work")
        (sandbox / "other.png").write_bytes(b"work")
        assert "already exists" in await err(
            mcp, "export_spritesheet", path="other.png", onto="sheet.png"
        )
        assert not aseprite.requests

    async def test_onto_the_same_file_updates_it(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"work")
        # Spelled differently on purpose: it is the same file once resolved.
        await ok(mcp, "export_spritesheet", path="sub/../sheet.png", onto="sheet.png", x=16, y=32)
        params = aseprite.last("sprite.exportSheet")["params"]
        assert (params["x"], params["y"]) == (16, 32)
        assert params["path"] == params["onto"] == str(sandbox / "sheet.png")

    async def test_onto_writes_to_a_new_path(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"work")
        await ok(mcp, "export_spritesheet", path="new.png", onto="sheet.png")
        params = aseprite.last("sprite.exportSheet")["params"]
        assert params["path"] == str(sandbox / "new.png")
        assert params["onto"] == str(sandbox / "sheet.png")

    async def test_only_writes_png(self, server, aseprite):
        mcp, _ = server
        assert "PATH_NOT_ALLOWED" in await err(mcp, "export_spritesheet", path="flat.aseprite")
        assert not aseprite.requests

    async def test_stays_in_the_sandbox(self, server, aseprite, sandbox, tmp_path):
        mcp, _ = server
        (tmp_path / "outside.png").write_bytes(b"")
        assert "PATH_NOT_ALLOWED" in await err(
            mcp, "export_spritesheet", path=str(tmp_path / "new.png")
        )
        assert "PATH_NOT_ALLOWED" in await err(
            mcp, "export_spritesheet", path="new.png", onto=str(tmp_path / "outside.png")
        )
        assert not aseprite.requests

    async def test_onto_must_exist(self, server, aseprite):
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(
            mcp, "export_spritesheet", path="new.png", onto="ghost.png"
        )

    @pytest.mark.parametrize("bad", [{"columns": 0}, {"x": 1}, {"y": 1}])
    async def test_rejects_bad_layout(self, server, aseprite, bad):
        # x and y place a block on an existing sheet, so without onto they mean nothing.
        mcp, _ = server
        assert "INVALID_PARAMS" in await err(mcp, "export_spritesheet", path="new.png", **bad)
        assert not aseprite.requests

    async def test_rejects_a_negative_origin(self, server, aseprite, sandbox):
        mcp, _ = server
        (sandbox / "sheet.png").write_bytes(b"work")
        assert "INVALID_PARAMS" in await err(
            mcp, "export_spritesheet", path="new.png", onto="sheet.png", x=-1
        )
        assert not aseprite.requests


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

    async def test_uneven_rows_in_erase_mode_are_flagged(self, server, aseprite):
        mcp, _ = server
        payload = json_of(await ok(
            mcp, "draw_rows", x=0, y=0, rows=["a..", "a...", "a.."], legend={"a": "#fff"}, blank="erase"
        ))
        assert "4 wide (rows 1)" in payload["warning"]

    async def test_uneven_solid_rows_are_flagged_when_skipping(self, server, aseprite):
        # Seen on a full-width lake: rows ending a pixel or two short, and nothing said so.
        mcp, _ = server
        payload = json_of(await ok(mcp, "draw_rows", x=0, y=0, rows=["aaaa", "aa", "aaaa"], legend={"a": "#fff"}))
        assert "2 wide (rows 1)" in payload["warning"]

    @pytest.mark.parametrize("rows", [["a.", "aaaa"], [" a", "aaaa"], ["..a", "aaaa", "a"]])
    async def test_uneven_shaped_rows_are_fine_when_skipping(self, server, aseprite, rows):
        # Using transparency means the shape is deliberate, and rows may stop short.
        mcp, _ = server
        payload = json_of(await ok(mcp, "draw_rows", x=0, y=0, rows=rows, legend={"a": "#fff"}))
        assert "warning" not in payload

    async def test_even_solid_rows_are_fine_when_skipping(self, server, aseprite):
        mcp, _ = server
        payload = json_of(await ok(mcp, "draw_rows", x=0, y=0, rows=["aa", "aa"], legend={"a": "#fff"}))
        assert "warning" not in payload

    async def test_row_warning_joins_an_aseprite_warning(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("draw.pixels", {"warning": "1 pixel(s) fell outside the 2x2 canvas."})
        payload = json_of(await ok(
            mcp, "draw_rows", x=0, y=0, rows=["a", "a."], legend={"a": "#fff"}, blank="erase"
        ))
        assert payload["warning"].startswith("1 pixel(s) fell outside")
        assert "Rows differ in length" in payload["warning"]

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

    async def test_reply_keeps_only_what_the_agent_cannot_derive(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 3, "undoSteps": 1, "results": [
            {"id": "aaaa1111", "name": "Cliff", "stackIndex": 2},
            {"written": 4, "changed": [1, 2, 3, 4], "layer": "Cliff", "frame": 1},
            {"filled": 9, "changed": [10, 0, 2, 2], "layer": "Cliff", "frame": 1},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "create_layer", "args": {"name": "Cliff"}},
            {"tool": "draw_line", "args": {"x1": 1, "y1": 2, "x2": 3, "y2": 5, "color": "#fff"}},
            {"tool": "fill", "args": {"x": 10, "y": 0, "color": "#fff"}},
        ]))
        assert payload == {
            "applied": 3,
            "undoSteps": 1,
            "changed": [1, 0, 11, 6],
            "written": 4,
            "filled": 9,
            "created": [{"id": "aaaa1111", "name": "Cliff"}],
        }

    async def test_totals_add_up_across_ops(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 5, "results": [
            {"written": 3, "erased": 1, "frame": 1},
            {"written": 2, "skippedOffCanvas": 4, "frame": 1},
            {"erased": 2, "frame": 1},
            {"replaced": 7, "frames": 1},
            # cel.copy reports a boolean here, and Python would count True as 1.
            {"from": {"frame": 1}, "to": {"frame": 2}, "replaced": True},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[{"tool": "create_frame"}] * 5))
        assert payload["written"] == 5
        assert payload["erased"] == 3
        assert payload["skippedOffCanvas"] == 4
        assert payload["replaced"] == 7

    async def test_empty_totals_are_left_out(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"filled": 0, "frame": 1}]})
        payload = json_of(await ok(mcp, "batch", ops=[{"tool": "fill", "args": {"x": 0, "y": 0, "color": "#fff"}}]))
        assert "filled" not in payload
        assert "changed" not in payload

    async def test_only_new_layers_count_as_created(self, server, aseprite):
        # Selecting or hiding a layer replies with the same id and name.
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 3, "results": [
            {"id": "old11111", "name": "Old"},
            {"id": "old11111", "name": "Old", "visible": False},
            {"id": "new22222", "name": "New", "stackIndex": 3},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "select_layer", "args": {"layer": "Old"}},
            {"tool": "set_layer_visibility", "args": {"layer": "Old", "visible": False}},
            {"tool": "create_layer", "args": {"name": "New"}},
        ]))
        assert payload["created"] == [{"id": "new22222", "name": "New"}]

    async def test_only_new_frames_are_listed(self, server, aseprite):
        # Selecting a frame or setting its duration replies with a frame number too.
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 4, "results": [
            {"frame": 1},
            {"frame": 2, "durationMs": 100, "frameCount": 2},
            {"frame": 3, "copiedFrom": 2, "durationMs": 100, "frameCount": 3},
            {"frame": 3, "durationMs": 80},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "select_frame", "args": {"frame": 1}},
            {"tool": "create_frame"},
            {"tool": "duplicate_frame", "args": {"frame": 2}},
            {"tool": "set_frame_duration", "args": {"frame": 3, "duration_ms": 80}},
        ]))
        assert payload["newFrames"] == [2, 3]
        assert payload["frameCount"] == 3

    async def test_frame_count_follows_the_last_op_that_reports_it(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 2, "results": [
            {"frame": 2, "durationMs": 100, "frameCount": 2},
            {"deleted": 2, "frameCount": 1},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "create_frame"}, {"tool": "delete_frame", "args": {"frame": 2}},
        ]))
        assert payload["frameCount"] == 1

    async def test_warnings_and_notes_name_their_op(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 3, "results": [
            {"written": 1, "frame": 1},
            {"written": 0, "warning": "2 pixel(s) fell outside the 8x8 canvas and were ignored."},
            {"replaced": 0, "note": "No pixel matched that color."},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[{"tool": "create_frame"}] * 3))
        assert payload["warnings"] == [
            {"ops": [1], "warning": "2 pixel(s) fell outside the 8x8 canvas and were ignored."},
            {"ops": [2], "warning": "No pixel matched that color."},
        ]

    async def test_a_repeated_warning_appears_once_with_every_op(self, server, aseprite):
        # Seen on a real reply: 16 fills that did nothing cost over a kilobyte.
        mcp, _ = server
        note = "The origin pixel is already that color; nothing to fill."
        aseprite.reply("batch.run", {"applied": 4, "results": [
            {"filled": 0, "note": note},
            {"written": 1},
            {"filled": 0, "note": note},
            {"filled": 0, "note": note},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[{"tool": "create_frame"}] * 4))
        assert payload["warnings"] == [{"ops": [0, 2, 3], "warning": note}]

    async def test_a_tools_own_warning_reaches_the_agent(self, server, aseprite):
        # The tool works this one out itself, and Lua never sees it.
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 2, "undoSteps": 1, "results": [
            {"frame": 2, "durationMs": 100, "frameCount": 2},
            {"written": 3, "changed": [0, 0, 3, 2], "frame": 2},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "create_frame"},
            {"tool": "draw_rows", "args": {
                "x": 0, "y": 0, "rows": ["aa", "a.a."], "legend": {"a": "#fff"}, "blank": "erase",
            }},
        ]))
        assert [w["ops"] for w in payload["warnings"]] == [[1]]
        assert "Rows differ in length" in payload["warnings"][0]["warning"]

    async def test_uneven_solid_rows_are_flagged_inside_a_batch(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"written": 6, "frame": 1}]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "draw_rows", "args": {"x": 0, "y": 0, "rows": ["aaaa", "aa"], "legend": {"a": "#fff"}}},
        ]))
        assert payload["warnings"][0]["ops"] == [0]
        assert "2 wide (rows 1)" in payload["warnings"][0]["warning"]

    async def test_a_tools_warning_joins_aseprites_on_the_same_op(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [
            {"written": 1, "warning": "1 pixel(s) fell outside the 2x2 canvas and were ignored."},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "draw_rows", "args": {"x": 0, "y": 0, "rows": ["aaaa", "aa"], "legend": {"a": "#fff"}}},
        ]))
        assert len(payload["warnings"]) == 1
        text = payload["warnings"][0]["warning"]
        assert "fell outside" in text and "Rows differ in length" in text

    async def test_a_tools_warning_survives_a_reply_without_results(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "draw_rows", "args": {"x": 0, "y": 0, "rows": ["aaaa", "aa"], "legend": {"a": "#fff"}}},
        ]))
        assert "Rows differ in length" in payload["warnings"][0]["warning"]

    async def test_clean_rows_leave_no_warnings_in_a_batch(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"written": 4, "frame": 1}]})
        payload = json_of(await ok(mcp, "batch", ops=[
            {"tool": "draw_rows", "args": {"x": 0, "y": 0, "rows": ["aa", "aa"], "legend": {"a": "#fff"}}},
        ]))
        assert "warnings" not in payload

    async def test_palette_notes_appear_once(self, server, aseprite):
        mcp, _ = server
        note = "#123456 is not in the palette; used the closest entry."
        aseprite.reply("batch.run", {"applied": 3, "results": [
            {"written": 1, "paletteNotes": [note]},
            {"written": 1, "paletteNote": note},
            {"filled": 1, "paletteNote": "Another note."},
        ]})
        payload = json_of(await ok(mcp, "batch", ops=[{"tool": "create_frame"}] * 3))
        assert payload["paletteNotes"] == [note, "Another note."]

    async def test_per_op_results_stay_out_of_the_reply(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"written": 1, "layer": "Art", "frame": 3}]})
        result = await ok(mcp, "batch", preview=True, ops=[
            {"tool": "draw_rect", "args": {"x": 0, "y": 0, "width": 1, "height": 1, "color": "#fff", "frame": 3}},
        ])
        assert "results" not in text_of(result)
        assert "echo" not in text_of(result)
        assert aseprite.last("render.canvas")["params"]["frame"] == 3, "preview still finds the frame"


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


# ---------------------------------------------------------------- repeated images

RED = tiny_png(b"\xff\x00\x00\xff")
BLUE = tiny_png(b"\x00\x00\xff\xff")


class TestRepeatedImages:
    """An image stays in the agent's context, so resending one pays for it twice."""

    async def test_an_identical_preview_is_not_sent_twice(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", {"frame": 1, "width": 32, "height": 32, "scale": 8})
        assert len(images(await ok(mcp, "get_canvas_preview"))) == 1
        repeat = await ok(mcp, "get_canvas_preview")
        assert not images(repeat)
        assert "Unchanged since this view's last image" in text_of(repeat)
        assert "frame 1, 32x32 source" in text_of(repeat)

    async def test_an_edit_in_between_sends_the_new_image(self, server, aseprite):
        mcp, _ = server
        aseprite.png = RED
        await ok(mcp, "get_canvas_preview")
        # Drawn by the agent or by hand in Aseprite: only the pixels count.
        aseprite.png = BLUE
        assert len(images(await ok(mcp, "get_canvas_preview"))) == 1

    async def test_asking_again_resends_it(self, server, aseprite):
        # The way back for an agent whose copy was compacted away.
        mcp, _ = server
        await ok(mcp, "get_canvas_preview")
        assert not images(await ok(mcp, "get_canvas_preview"))
        assert len(images(await ok(mcp, "get_canvas_preview"))) == 1
        assert not images(await ok(mcp, "get_canvas_preview"))

    async def test_undoing_back_to_an_older_image_resends_it(self, server, aseprite):
        # "Unchanged since the last image" would point at the wrong one.
        mcp, _ = server
        aseprite.png = RED
        await ok(mcp, "get_canvas_preview")
        aseprite.png = BLUE
        await ok(mcp, "get_canvas_preview")
        aseprite.png = RED
        assert len(images(await ok(mcp, "get_canvas_preview"))) == 1

    async def test_an_identical_frame_names_the_earlier_view(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.canvas", lambda params: {"frame": params.get("frame")})
        await ok(mcp, "get_canvas_preview", frame=1)
        text = text_of(await ok(mcp, "get_canvas_preview", frame=2))
        assert "Identical to the last image of frame 1" in text
        assert text.endswith("frame 2")
        # Asking about frame 2 leaves frame 1's image current.
        assert not images(await ok(mcp, "get_canvas_preview", frame=1))

    async def test_a_batch_preview_counts(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("batch.run", {"applied": 1, "results": [{"frame": 1}]})
        aseprite.reply("render.canvas", {"frame": 1})
        result = await ok(mcp, "batch", preview=True, ops=[
            {"tool": "select_frame", "args": {"frame": 1}},
        ])
        assert len(images(result)) == 1
        assert not images(await ok(mcp, "get_canvas_preview", frame=1))

    async def test_contact_sheets_and_onion_skins_keep_their_text(self, server, aseprite):
        mcp, _ = server
        aseprite.reply("render.contactSheet", {"cells": [{"frame": 1, "durationMs": 80}]})
        aseprite.reply("render.onionSkin", {"frame": 2})
        aseprite.png = RED
        await ok(mcp, "get_animation_contact_sheet")
        sheet = await ok(mcp, "get_animation_contact_sheet")
        assert not images(sheet)
        assert "F1 80ms" in text_of(sheet)
        aseprite.png = BLUE
        await ok(mcp, "get_onion_skin_preview")
        onion = await ok(mcp, "get_onion_skin_preview")
        assert not images(onion)
        assert "previous frame is tinted" in text_of(onion)

    async def test_memory_is_bounded(self, server):
        _, ctx = server
        first = Image(data=b"first", format="png")
        ctx.image_or_note(first, "a")
        for i in range(MAX_REMEMBERED_IMAGES):
            ctx.image_or_note(Image(data=b"other %d" % i, format="png"), f"view {i}")
        assert len(ctx._image_labels) == MAX_REMEMBERED_IMAGES
        assert ctx.image_or_note(first, "a") is first


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
    "new_sprite": {"width": 8, "height": 8},
    "open_sprite": {"path": "fixture.aseprite"},
    "save_sprite": {"path": "fixture.aseprite"},
    "import_spritesheet": {"path": "fixture.png", "frame_width": 8, "frame_height": 8},
    "export_spritesheet": {"path": "new_sheet.png"},
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
    (sandbox / "fixture.png").write_bytes(b"")
    await ok(mcp, name, **MINIMAL_ARGUMENTS[name])


@pytest.mark.parametrize("name", sorted(MINIMAL_ARGUMENTS))
async def test_tools_report_disconnection(server, sandbox, name):
    """With no extension attached, every tool fails with a usable message.

    get_connection_status is the exception by design: it must still answer.
    """
    mcp, _ = server
    (sandbox / "fixture.aseprite").write_bytes(b"")
    (sandbox / "fixture.png").write_bytes(b"")
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
