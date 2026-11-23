"""The stale-extension check (#16): fingerprints, and what the bridge does with them."""

from __future__ import annotations

import asyncio
import json
import shutil
from dataclasses import replace
from pathlib import Path

import pytest

from aseprite_mcp.bridge.protocol import BridgeError, ErrorCode
from aseprite_mcp.config import Config
from aseprite_mcp.extension_check import ExtensionCopy, content_hash
from aseprite_mcp.server import build_server
from tests.conftest import FakeAseprite, json_of

REPO_EXTENSION = Path(__file__).resolve().parents[1] / "extension" / "aseprite-mcp"

# Pinned in tests/lua/run_tests.lua too: both sides must hash alike.
HELLO_WORLD = 2731407353


def test_content_hash_ignores_carriage_returns():
    assert content_hash(b"hello\nworld") == HELLO_WORLD
    assert content_hash(b"hello\r\nworld") == HELLO_WORLD
    assert content_hash(b"hello\nworld!") != HELLO_WORLD


def test_fingerprint_covers_lua_and_package_json_only(tmp_path):
    (tmp_path / "commands").mkdir()
    (tmp_path / "main.lua").write_text("a")
    (tmp_path / "commands" / "rig.lua").write_text("b")
    (tmp_path / "package.json").write_text("{}")
    (tmp_path / "__pref.lua").write_text("written by Aseprite")
    (tmp_path / "README.md").write_text("not code")
    copy = ExtensionCopy(tmp_path)
    assert sorted(copy.fingerprint()) == ["commands/rig.lua", "main.lua", "package.json"]


def test_an_edit_to_the_copy_is_seen_at_once(tmp_path):
    (tmp_path / "main.lua").write_text("one")
    copy = ExtensionCopy(tmp_path)
    running = copy.fingerprint()
    assert copy.differences(running) == []
    (tmp_path / "main.lua").write_text("two, longer")
    assert copy.differences(running) == ["main.lua"]
    (tmp_path / "ws.lua").write_text("new")
    assert copy.differences(running) == ["main.lua", "ws.lua"]


def test_config_finds_the_checkout_copy_and_can_be_switched_off(monkeypatch, tmp_path):
    monkeypatch.delenv("ASEPRITE_MCP_EXTENSION_DIR", raising=False)
    assert Config.from_env().extension_dir == REPO_EXTENSION
    monkeypatch.setenv("ASEPRITE_MCP_EXTENSION_DIR", "off")
    assert Config.from_env().extension_dir is None
    monkeypatch.setenv("ASEPRITE_MCP_EXTENSION_DIR", str(tmp_path))
    assert Config.from_env().extension_dir == tmp_path.resolve()


# ---------------------------------------------------------------- the bridge


@pytest.fixture
def extension_copy(tmp_path) -> Path:
    copy = tmp_path / "extension"
    shutil.copytree(REPO_EXTENSION, copy, ignore=shutil.ignore_patterns("__*"))
    return copy


@pytest.fixture
async def checked(config, extension_copy, tmp_path, monkeypatch):
    """A server checking windows against `extension_copy`."""
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    mcp, ctx = build_server(replace(config, extension_dir=extension_copy))
    await ctx.bridge.start()
    try:
        yield mcp, ctx
    finally:
        await ctx.bridge.stop()
        ctx.cleanup()


async def attach(ctx, **hello) -> FakeAseprite:
    fake = FakeAseprite(instance="aaaaaa")
    fake.hello.update(hello)
    fake.reply("app.status", {"documentOpen": True, "document": "hero.aseprite"})
    fake.reply("sprite.info", {"width": 32})
    await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
    for _ in range(200):
        if ctx.bridge.connected:
            break
        await asyncio.sleep(0.01)
    return fake


async def test_a_matching_extension_works(checked, extension_copy):
    mcp, ctx = checked
    fake = await attach(ctx, files=ExtensionCopy(extension_copy).fingerprint())
    try:
        assert (await ctx.bridge.call("sprite.info"))["width"] == 32
        status = json_of(await mcp.call_tool("get_connection_status", {}))
        assert status["extensionUpToDate"] is True
    finally:
        await fake.stop()


async def test_a_differing_extension_is_named_and_refused(checked, extension_copy):
    mcp, ctx = checked
    files = ExtensionCopy(extension_copy).fingerprint()
    files["commands/rig.lua"] ^= 1
    del files["rigstore.lua"]
    fake = await attach(ctx, files=files)
    try:
        with pytest.raises(BridgeError) as excinfo:
            await ctx.bridge.call("sprite.info")
        error = excinfo.value
        assert error.code is ErrorCode.EXTENSION_OUTDATED
        assert "commands/rig.lua" in error.message and "rigstore.lua" in error.message
        assert "Cmd+Q" in error.message
        assert [r["command"] for r in fake.requests] == [], "nothing reaches a stale extension"

        status = json_of(await mcp.call_tool("get_connection_status", {}))
        assert status["extensionUpToDate"] is False
        assert status["staleFiles"] == ["commands/rig.lua", "rigstore.lua"]
        assert "outdated" in status["hint"]
        assert status["document"] == "hero.aseprite", "diagnostics still answer"
    finally:
        await fake.stop()


async def test_an_extension_from_before_the_check_is_outdated(checked):
    _mcp, ctx = checked
    fake = await attach(ctx)
    try:
        with pytest.raises(BridgeError, match="predates the version check"):
            await ctx.bridge.call("sprite.info")
    finally:
        await fake.stop()


async def test_an_extension_that_could_not_read_itself_is_not_blocked(checked):
    mcp, ctx = checked
    fake = await attach(ctx, filesError="no file access")
    try:
        assert (await ctx.bridge.call("sprite.info"))["width"] == 32
        status = json_of(await mcp.call_tool("get_connection_status", {}))
        assert "extensionUpToDate" not in status
        assert status["extensionCheck"] == "not checked: no file access"
    finally:
        await fake.stop()


async def test_editing_the_copy_mid_session_makes_aseprite_stale(checked, extension_copy):
    _mcp, ctx = checked
    fake = await attach(ctx, files=ExtensionCopy(extension_copy).fingerprint())
    try:
        assert await ctx.bridge.call("sprite.info")
        with (extension_copy / "ws.lua").open("a") as handle:
            handle.write("\n-- edited while Aseprite was running\n")
        with pytest.raises(BridgeError, match="ws.lua"):
            await ctx.bridge.call("sprite.info")
    finally:
        await fake.stop()


async def test_no_copy_means_no_check(server, aseprite):
    """The default test config, like a server installed without a checkout."""
    _mcp, ctx = server
    assert await ctx.bridge.call("sprite.info") is not None
