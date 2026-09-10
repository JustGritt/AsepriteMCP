"""Bridge lifecycle, authentication and failure modes."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from aseprite_mcp.bridge.protocol import BridgeError, ErrorCode
from aseprite_mcp.bridge.session import session_file_path
from tests.conftest import FakeAseprite


async def wait_for(predicate, timeout=2.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.01)
    return False


class TestDiscovery:
    async def test_session_file_is_written_and_removed(self, config, tmp_path, monkeypatch):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        from aseprite_mcp.server import build_server

        _mcp, ctx = build_server(config)
        await ctx.bridge.start()
        path = session_file_path()
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            assert payload["port"] == ctx.bridge.bound_port
            assert payload["token"] == ctx.bridge.token
            assert payload["host"] == "127.0.0.1"
        finally:
            await ctx.bridge.stop()
            ctx.cleanup()
        assert not path.exists(), "the session file must not outlive the server"


class TestAuthentication:
    async def test_no_token_is_required_by_default(self, server):
        """The default must be connectable with no shared secret.

        Token auth needs the extension to read a file, and Aseprite gates script
        file access behind a Security modal that fails closed -- so requiring a
        token by default made the bridge unable to connect at all.
        """
        _mcp, ctx = server
        assert ctx.bridge._config.require_token is False
        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send(json.dumps({"type": "hello", "asepriteVersion": "1.3.18.3"}))
            welcome = json.loads(await socket.recv())
            assert welcome["ok"] is True
            assert await wait_for(lambda: ctx.bridge.connected)

    async def test_bad_token_is_rejected_when_enabled(self, config, tmp_path, monkeypatch):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        from dataclasses import replace

        from aseprite_mcp.server import build_server

        _mcp, ctx = build_server(replace(config, require_token=True, token="s3cret"))
        await ctx.bridge.start()
        try:
            async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
                await socket.send(json.dumps({"type": "hello", "token": "wrong"}))
                welcome = json.loads(await socket.recv())
                assert welcome["ok"] is False
                assert welcome["error"]["code"] == "UNAUTHORIZED"
            assert not ctx.bridge.connected

            async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
                await socket.send(json.dumps({"type": "hello", "token": "s3cret"}))
                assert json.loads(await socket.recv())["ok"] is True
                assert await wait_for(lambda: ctx.bridge.connected)
        finally:
            await ctx.bridge.stop()
            ctx.cleanup()

    async def test_first_message_must_be_a_hello(self, server):
        _mcp, ctx = server
        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send(json.dumps({"id": 1, "ok": True}))
            welcome = json.loads(await socket.recv())
            assert welcome["ok"] is False
        assert not ctx.bridge.connected

    async def test_malformed_hello_is_rejected(self, server):
        _mcp, ctx = server
        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send("this is not json")
            welcome = json.loads(await socket.recv())
            assert welcome["ok"] is False
        assert not ctx.bridge.connected

    async def test_client_info_is_recorded(self, server, aseprite):
        _mcp, ctx = server
        assert ctx.bridge.client_info["asepriteVersion"] == "1.3.18.3"
        assert "layer.uuid" in ctx.bridge.client_info["capabilities"]


class TestCalls:
    async def test_round_trip(self, server, aseprite):
        _mcp, ctx = server
        aseprite.reply("sprite.info", {"width": 64, "height": 64})
        result = await ctx.bridge.call("sprite.info")
        assert result["width"] == 64
        assert aseprite.last("sprite.info")["params"] == {}

    async def test_params_are_forwarded(self, server, aseprite):
        _mcp, ctx = server
        await ctx.bridge.call("frame.duplicate", {"frame": 3})
        assert aseprite.last()["params"] == {"frame": 3}

    async def test_ids_are_unique_and_increasing(self, server, aseprite):
        _mcp, ctx = server
        await ctx.bridge.call("a")
        await ctx.bridge.call("b")
        ids = [request["id"] for request in aseprite.requests]
        assert ids == sorted(set(ids))

    async def test_concurrent_calls_are_correlated(self, server, aseprite):
        """Two in-flight requests must not receive each other's results."""
        _mcp, ctx = server
        aseprite.reply("a", {"which": "a"})
        aseprite.reply("b", {"which": "b"})
        first, second = await asyncio.gather(ctx.bridge.call("a"), ctx.bridge.call("b"))
        assert first["which"] == "a"
        assert second["which"] == "b"

    async def test_error_response_is_raised(self, server, aseprite):
        _mcp, ctx = server
        aseprite.fail("frame.select", "INVALID_FRAME", "Frame 12 does not exist.")
        with pytest.raises(BridgeError) as excinfo:
            await ctx.bridge.call("frame.select", {"frame": 12})
        assert excinfo.value.code is ErrorCode.INVALID_FRAME


class TestFailureModes:
    async def test_call_without_a_client(self, server):
        _mcp, ctx = server
        with pytest.raises(BridgeError) as excinfo:
            await ctx.bridge.call("sprite.info")
        assert excinfo.value.code is ErrorCode.ASEPRITE_NOT_CONNECTED

    async def test_timeout(self, server, aseprite):
        _mcp, ctx = server

        async def never_answer(_params):
            await asyncio.sleep(10)

        # Swallow the request without replying.
        aseprite._respond = lambda request: None  # type: ignore[assignment]

        async def loop():
            async for raw in aseprite._socket:
                aseprite.requests.append(json.loads(raw))

        aseprite._task.cancel()
        aseprite._task = asyncio.create_task(loop())

        with pytest.raises(BridgeError) as excinfo:
            await ctx.bridge.call("sprite.info", timeout=0.2)
        assert excinfo.value.code is ErrorCode.TIMEOUT
        assert "0.2s" in excinfo.value.message

    async def test_disconnect_fails_pending_calls(self, server, aseprite):
        _mcp, ctx = server

        async def loop():
            async for raw in aseprite._socket:
                aseprite.requests.append(json.loads(raw))
                await aseprite._socket.close()

        aseprite._task.cancel()
        aseprite._task = asyncio.create_task(loop())

        with pytest.raises(BridgeError) as excinfo:
            await ctx.bridge.call("sprite.info", timeout=3.0)
        assert excinfo.value.code is ErrorCode.ASEPRITE_NOT_CONNECTED

    async def test_malformed_reply_does_not_kill_the_connection(self, server, aseprite):
        _mcp, ctx = server
        await aseprite._socket.send("<not json>")
        await asyncio.sleep(0.05)
        assert ctx.bridge.connected
        # And the bridge still works afterwards.
        aseprite.reply("sprite.info", {"ok": 1})
        assert await ctx.bridge.call("sprite.info")

    async def test_reply_with_unknown_id_is_ignored(self, server, aseprite):
        _mcp, ctx = server
        await aseprite._socket.send(json.dumps({"id": 9999, "ok": True, "result": {}}))
        await asyncio.sleep(0.05)
        assert ctx.bridge.connected

    async def test_second_client_supersedes_the_first(self, server, aseprite):
        """Restarting Aseprite must not leave the bridge wedged on a dead socket."""
        _mcp, ctx = server
        second = FakeAseprite()
        await second.start(ctx.bridge.bound_port, ctx.bridge.token)
        assert await wait_for(lambda: ctx.bridge.connected)

        second.reply("sprite.info", {"from": "second"})
        result = await ctx.bridge.call("sprite.info")
        assert result["from"] == "second"
        await second.stop()

    async def test_stop_disconnects(self, config, tmp_path, monkeypatch):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        from aseprite_mcp.server import build_server

        _mcp, ctx = build_server(config)
        await ctx.bridge.start()
        fake = FakeAseprite()
        await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
        assert await wait_for(lambda: ctx.bridge.connected)

        await ctx.bridge.stop()
        assert not ctx.bridge.connected
        await fake.stop()
        ctx.cleanup()
