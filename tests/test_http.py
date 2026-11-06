"""Two real HTTP MCP clients share one bridge, with separate tool memory."""
import asyncio
import socket
from contextlib import asynccontextmanager

import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from aseprite_mcp.__main__ import main
from aseprite_mcp.server import build_server
from tests.conftest import FakeAseprite


@asynccontextmanager
async def client(url):
    async with streamable_http_client(url) as streams:
        async with ClientSession(streams[0], streams[1]) as session:
            await session.initialize()
            yield session


@pytest.mark.asyncio
async def test_shared_http(config, tmp_path, monkeypatch):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    mcp, ctx = build_server(config, shared=True)
    operations = []

    @mcp.tool()
    async def two_steps(label: str) -> str:
        operations.append(label)
        await asyncio.sleep(0.03)
        operations.append(label)
        return label
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    http = uvicorn.Server(uvicorn.Config(mcp.streamable_http_app(), log_level="error"))
    task = asyncio.create_task(http.serve(sockets=[listener]))
    fake = FakeAseprite()
    try:
        async def wait_started():
            while not http.started:
                if task.done():
                    await task
                await asyncio.sleep(0.01)
        await asyncio.wait_for(wait_started(), 10)
        await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
        async with client(f"http://127.0.0.1:{port}/mcp") as a:
            async with client(f"http://127.0.0.1:{port}/mcp") as b:
                assert (await a.list_tools()).tools
                assert (await b.list_tools()).tools
                await asyncio.gather(a.call_tool("two_steps", {"label": "a"}),
                                     b.call_tool("two_steps", {"label": "b"}))
                assert operations in (["a", "a", "b", "b"], ["b", "b", "a", "a"])
                args = {"x": 0, "y": 0, "rows": ["r"]}
                assert not (await a.call_tool("draw_rows", {**args, "legend": {"r": "#ff0000"}})).is_error
                assert (await b.call_tool("draw_rows", args)).is_error
                assert not (await b.call_tool("draw_rows", {**args, "legend": {"r": "#0000ff"}})).is_error
                assert not (await a.call_tool("draw_rows", args)).is_error
                assert fake.last("draw.pixels")["params"]["pixels"][0]["color"] == "#ff0000ff"
                # Batch recursively calls tools: it must retain A's memory and not deadlock.
                result = await asyncio.wait_for(a.call_tool("batch", {"ops": [{"tool": "draw_rows", "args": args}]}), 5)
                assert not result.is_error
                for session in (a, b):
                    result = await session.call_tool("get_canvas_preview", {})
                    assert any(block.type == "image" for block in result.content)
            # Closing B must not stop the shared Aseprite connection.
            assert ctx.bridge.connected
            assert not (await a.call_tool("draw_rows", args)).is_error
    finally:
        await fake.stop()
        http.should_exit = True
        await asyncio.wait_for(task, 10)
        listener.close()
    assert not ctx.bridge.connected


@pytest.mark.parametrize("port", ["0", "65536", "-1", "abc"])
def test_invalid_http_port(port):
    with pytest.raises(SystemExit) as error:
        main(["--http", port])
    assert error.value.code == 2


def test_http_port_cannot_equal_bridge(monkeypatch):
    monkeypatch.setenv("ASEPRITE_MCP_PORT", "32145")
    with pytest.raises(SystemExit) as error:
        main(["--http", "32145"])
    assert error.value.code == 2


@pytest.mark.asyncio
async def test_shared_startup_rejects_occupied_bridge(config, tmp_path, monkeypatch):
    from dataclasses import replace

    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    mcp, ctx = build_server(replace(config, port=listener.getsockname()[1]), shared=True)
    try:
        with pytest.raises(RuntimeError, match="Stop the old stdio server"):
            async with mcp.settings.lifespan(mcp):
                pytest.fail("shared server started without its bridge")
        assert ctx.bridge._acquire_task is None
    finally:
        listener.close()
