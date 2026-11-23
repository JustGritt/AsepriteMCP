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


class TestContestedPort:
    """Two server processes, one port.

    Binding used to be fatal, so the second copy died with Errno 10048 before it
    could answer tools/list. Any MCP client that spawns more than one instance --
    Codex CLI spawns two -- therefore showed a server that had connected and had
    no tools at all, with the real cause visible only in a stderr traceback the
    client discarded.
    """

    async def _bridge_on(self, port: int, sandbox: Path):
        from aseprite_mcp.bridge.ws_server import AsepriteBridge
        from aseprite_mcp.config import Config

        return AsepriteBridge(Config(
            host="127.0.0.1", port=port, allowed_dirs=(sandbox,),
            default_timeout=2.0, render_timeout=2.0,
        ))

    async def test_losing_the_port_is_not_fatal(self, config, sandbox, tmp_path, monkeypatch):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        first = await self._bridge_on(0, sandbox)
        await first.start()
        port = first.bound_port
        assert first.bind_error is None, "the first bridge should own the port"

        second = await self._bridge_on(port, sandbox)
        try:
            await second.start()          # must not raise
            assert second.bind_error is not None, "the loser should say why it has no bridge"
            assert str(port) in second.bind_error
            assert not second.connected
        finally:
            await second.stop()
            await first.stop()

    async def test_the_next_call_takes_the_port_once_the_holder_exits(
        self, config, sandbox, tmp_path, monkeypatch
    ):
        """No background retry: the session that wants Aseprite is the one that gets it."""
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        first = await self._bridge_on(0, sandbox)
        await first.start()
        second = await self._bridge_on(first.bound_port, sandbox)
        try:
            with pytest.raises(BridgeError) as caught:
                await second.call("sprite.info")
            assert caught.value.code is ErrorCode.ASEPRITE_NOT_CONNECTED
            # Not the generic "start Aseprite" advice: the extension is fine, it
            # is simply attached to the other process. Lead with the simple fix.
            assert "already listening" in str(caught.value)
            assert "/mcp" in str(caught.value)
            assert not second.listening

            await first.stop()
            call = asyncio.create_task(second.call("sprite.info"))
            assert await wait_for(lambda: second.listening)
            fake = FakeAseprite()
            fake.reply("sprite.info", {"from": "second"})
            await fake.start(second.bound_port, second.token)
            try:
                assert (await call)["from"] == "second"
            finally:
                await fake.stop()
        finally:
            await second.stop()
            await first.stop()


class TestInstances:
    """Several Aseprite windows on one bridge, each chosen by id."""

    @staticmethod
    async def attach(ctx, instance=None, name=None) -> FakeAseprite:
        fake = FakeAseprite(instance=instance, name=name)
        before = len(ctx.bridge.instances)
        await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
        key = instance or "aseprite"
        assert await wait_for(lambda: any(i.id == key for i in ctx.bridge.instances))
        assert len(ctx.bridge.instances) >= before
        return fake

    async def test_windows_with_their_own_ids_coexist(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "aaaaaa", "knight")
        b = await self.attach(ctx, "bbbbbb")
        try:
            assert [i.id for i in ctx.bridge.instances] == ["aaaaaa", "bbbbbb"]
            assert ctx.bridge.instances[0].label == "knight (aaaaaa)"
            a.reply("sprite.info", {"from": "a"})
            b.reply("sprite.info", {"from": "b"})
            assert (await ctx.bridge.call("sprite.info", instance="aaaaaa"))["from"] == "a"
            assert (await ctx.bridge.call("sprite.info", instance="bbbbbb"))["from"] == "b"
        finally:
            await a.stop()
            await b.stop()

    async def test_several_windows_and_no_choice_is_refused(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "aaaaaa")
        b = await self.attach(ctx, "bbbbbb", "dragon")
        try:
            with pytest.raises(BridgeError) as excinfo:
                await ctx.bridge.call("sprite.info")
            assert excinfo.value.code is ErrorCode.INSTANCE_REQUIRED
            assert "aaaaaa" in excinfo.value.message and "dragon (bbbbbb)" in excinfo.value.message
            assert not a.requests and not b.requests, "nothing may be sent on a guess"
        finally:
            await a.stop()
            await b.stop()

    async def test_the_only_window_needs_no_choice(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "aaaaaa")
        try:
            a.reply("sprite.info", {"from": "a"})
            assert (await ctx.bridge.call("sprite.info"))["from"] == "a"
        finally:
            await a.stop()

    async def test_a_chosen_window_that_left_is_named(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "aaaaaa")
        try:
            with pytest.raises(BridgeError) as excinfo:
                await ctx.bridge.call("sprite.info", instance="cccccc")
            assert excinfo.value.code is ErrorCode.ASEPRITE_NOT_CONNECTED
            assert "cccccc" in excinfo.value.message and "aaaaaa" in excinfo.value.message
        finally:
            await a.stop()

    async def test_the_same_window_reconnecting_replaces_its_socket(self, server):
        _mcp, ctx = server
        old = await self.attach(ctx, "aaaaaa")
        new = FakeAseprite(instance="aaaaaa")
        await new.start(ctx.bridge.bound_port, ctx.bridge.token)
        try:
            assert await wait_for(
                lambda: len(ctx.bridge.instances) == 1
                and ctx.bridge.instances[0].websocket is not None
                and not old.requests
            )
            new.reply("sprite.info", {"from": "new"})
            assert (await ctx.bridge.call("sprite.info"))["from"] == "new"
            assert len(ctx.bridge.instances) == 1
        finally:
            await old.stop()
            await new.stop()

    async def test_a_window_leaving_fails_only_its_own_calls(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "aaaaaa")
        b = await self.attach(ctx, "bbbbbb")

        async def close_on_request():
            async for raw in a._socket:
                a.requests.append(json.loads(raw))
                await a._socket.close()

        a._task.cancel()
        a._task = asyncio.create_task(close_on_request())
        try:
            b.reply("sprite.info", {"from": "b"})
            lost, kept = await asyncio.gather(
                ctx.bridge.call("sprite.info", instance="aaaaaa", timeout=3.0),
                ctx.bridge.call("sprite.info", instance="bbbbbb", timeout=3.0),
                return_exceptions=True,
            )
            assert isinstance(lost, BridgeError) and lost.code is ErrorCode.ASEPRITE_NOT_CONNECTED
            assert kept["from"] == "b"
            assert await wait_for(lambda: [i.id for i in ctx.bridge.instances] == ["bbbbbb"])
        finally:
            await a.stop()
            await b.stop()

    async def test_match_by_id_name_and_prefix(self, server):
        _mcp, ctx = server
        a = await self.attach(ctx, "a1b2c3", "knight")
        b = await self.attach(ctx, "a1ffff")
        try:
            assert ctx.bridge.match("a1b2c3").id == "a1b2c3"
            assert ctx.bridge.match("knight").id == "a1b2c3"
            assert ctx.bridge.match("a1f").id == "a1ffff"
            assert ctx.bridge.match("zzz") is None
            with pytest.raises(BridgeError, match="more than one"):
                ctx.bridge.match("a1")
        finally:
            await a.stop()
            await b.stop()


class TestHeartbeat:
    """The server proves it is alive to extensions that ask (#18).

    The extension cannot always see its socket die: with the server
    force-killed, Aseprite on Windows sat "connected" for minutes. A heartbeat
    gives it something to miss.
    """

    HELLO = {"type": "hello", "instance": "aaaaaa"}

    @pytest.fixture(autouse=True)
    def fast_heartbeat(self, monkeypatch):
        from aseprite_mcp.bridge import ws_server

        monkeypatch.setattr(ws_server, "HEARTBEAT_SECONDS", 0.05)

    async def test_an_extension_that_asks_is_told_the_interval_and_gets_heartbeats(
        self, server
    ):
        _mcp, ctx = server
        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send(json.dumps({**self.HELLO, "capabilities": ["heartbeat"]}))
            welcome = json.loads(await socket.recv())
            assert welcome["ok"] is True
            assert welcome["heartbeat"] == 0.05
            for _ in range(3):
                beat = json.loads(await asyncio.wait_for(socket.recv(), 1.0))
                assert beat == {"type": "heartbeat"}, "no id, so it is never a request"

    async def test_an_extension_that_does_not_ask_gets_none(self, server):
        """An older extension would queue each heartbeat and answer it with an error."""
        _mcp, ctx = server
        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send(json.dumps({**self.HELLO, "capabilities": ["layer.uuid"]}))
            welcome = json.loads(await socket.recv())
            assert welcome["ok"] is True
            assert "heartbeat" not in welcome, "nothing for the extension to time out on"
            with pytest.raises(asyncio.TimeoutError):
                await asyncio.wait_for(socket.recv(), 0.3)

    async def test_heartbeats_interleave_with_calls(self, server):
        _mcp, ctx = server
        fake = FakeAseprite(instance="aaaaaa")
        fake.hello["capabilities"] = ["layer.uuid", "heartbeat"]
        await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
        try:
            assert await wait_for(lambda: ctx.bridge.connected)
            for frame in range(1, 6):
                fake.reply("frame.select", {"frame": frame})
                assert (await ctx.bridge.call("frame.select", {"frame": frame}))["frame"] == frame
                await asyncio.sleep(0.03)
            assert await wait_for(lambda: len(fake.notices) >= 3)
            assert all(n == {"type": "heartbeat"} for n in fake.notices)
            assert [r["command"] for r in fake.requests] == ["frame.select"] * 5
        finally:
            await fake.stop()

    async def test_heartbeats_stop_with_the_socket(self, server):
        _mcp, ctx = server

        def beating() -> list[asyncio.Task]:
            return [t for t in asyncio.all_tasks() if t.get_name().startswith("heartbeat ")]

        async with connect(f"ws://127.0.0.1:{ctx.bridge.bound_port}/") as socket:
            await socket.send(json.dumps({**self.HELLO, "capabilities": ["heartbeat"]}))
            await socket.recv()
            assert await wait_for(lambda: len(beating()) == 1)
        assert await wait_for(lambda: not ctx.bridge.connected)
        assert await wait_for(lambda: not beating()), "the heartbeat task outlived its socket"

    async def test_a_superseded_socket_stops_beating(self, server):
        _mcp, ctx = server
        url = f"ws://127.0.0.1:{ctx.bridge.bound_port}/"
        hello = json.dumps({**self.HELLO, "capabilities": ["heartbeat"]})
        async with connect(url) as old, connect(url) as new:
            await old.send(hello)
            await old.recv()
            await new.send(hello)
            await new.recv()
            assert await wait_for(
                lambda: len([t for t in asyncio.all_tasks()
                             if t.get_name().startswith("heartbeat ")]) == 1
            ), "one window, one heartbeat"
            assert json.loads(await asyncio.wait_for(new.recv(), 1.0)) == {"type": "heartbeat"}


class TestOnDemandBinding:
    """A stdio server binds on its first command, not at startup (#19)."""

    @pytest.fixture
    def bridge(self, config, tmp_path, monkeypatch):
        from aseprite_mcp.bridge.ws_server import AsepriteBridge

        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        return AsepriteBridge(config)

    async def test_a_session_that_makes_no_call_holds_no_port(self, config, tmp_path, monkeypatch):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
        from aseprite_mcp.server import build_server

        mcp, ctx = build_server(config)
        async with mcp.settings.lifespan(mcp):
            assert not ctx.bridge.listening
            status = json.loads((await mcp.call_tool("get_connection_status", {})).content[0].text)
            assert status["listening"] is False and status["connected"] is False
            assert not ctx.bridge.listening, "the diagnostic must not bind"

    async def test_the_first_call_binds_and_waits_for_aseprite(self, bridge):
        call = asyncio.create_task(bridge.call("sprite.info"))
        assert await wait_for(lambda: bridge.listening)
        fake = FakeAseprite()
        fake.reply("sprite.info", {"width": 8})
        await fake.start(bridge.bound_port, bridge.token)
        try:
            assert (await call)["width"] == 8
        finally:
            await fake.stop()
            await bridge.stop()

    async def test_the_wait_ends_when_nothing_attaches(self, bridge, monkeypatch):
        from aseprite_mcp.bridge import ws_server

        monkeypatch.setattr(ws_server, "CONNECT_WAIT_SECONDS", 0.1)
        try:
            with pytest.raises(BridgeError) as caught:
                await bridge.call("sprite.info")
            assert caught.value.code is ErrorCode.ASEPRITE_NOT_CONNECTED
            assert bridge.listening, "it keeps listening for Aseprite"
        finally:
            await bridge.stop()

    async def test_an_idle_port_is_released_and_taken_again(self, bridge, monkeypatch):
        from aseprite_mcp.bridge import ws_server

        monkeypatch.setattr(ws_server, "CONNECT_WAIT_SECONDS", 0.1)
        monkeypatch.setattr(ws_server, "IDLE_RELEASE_SECONDS", 0.5)
        try:
            with pytest.raises(BridgeError):
                await bridge.call("sprite.info")
            assert bridge.listening
            await asyncio.sleep(0.3)
            with pytest.raises(BridgeError):
                await bridge.call("sprite.info")
            await asyncio.sleep(0.3)
            assert bridge.listening, "each command restarts the idle count"
            assert await wait_for(lambda: not bridge.listening)
            assert not session_file_path().exists()
            with pytest.raises(BridgeError):
                await bridge.call("sprite.info")
            assert bridge.listening, "the next command binds again"
        finally:
            await bridge.stop()

    async def test_a_port_opened_by_start_is_never_released(self, server, aseprite, monkeypatch):
        from aseprite_mcp.bridge import ws_server

        _mcp, ctx = server
        monkeypatch.setattr(ws_server, "IDLE_RELEASE_SECONDS", 0.05)
        await ctx.bridge.call("sprite.info")
        await asyncio.sleep(0.2)
        assert ctx.bridge.listening and ctx.bridge.connected
