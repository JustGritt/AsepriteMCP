"""Shared fixtures, including the fake Aseprite extension.

The fake speaks the real wire protocol over a real loopback WebSocket, so the
whole tool surface can be exercised without Aseprite running. That is what keeps
this suite fast and runnable in CI.
"""

from __future__ import annotations

import asyncio
import json
import struct
import zlib
from pathlib import Path
from typing import Any, Callable

import pytest
import pytest_asyncio
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from aseprite_mcp.config import Config
from aseprite_mcp.server import build_server


def tiny_png(rgba: bytes = b"\x00\x00\x00\x00") -> bytes:
    """A valid 1x1 PNG of one color, transparent by default.

    Built rather than pasted so it cannot rot.
    """

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    pixels = zlib.compress(b"\x00" + rgba)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


class FakeAseprite:
    """Minimal stand-in for the Lua extension."""

    def __init__(self, instance: str | None = None, name: str | None = None) -> None:
        self.requests: list[dict[str, Any]] = []
        # Messages without an id, such as heartbeats: the extension never answers
        # those, and neither does the fake.
        self.notices: list[dict[str, Any]] = []
        self.responses: dict[str, Any] = {"fs.probe": {"canWriteFiles": True}}
        # What every render writes. Aseprite's PNGs are byte-identical for
        # identical pixels, so changing this stands in for editing the sprite.
        self.png = tiny_png()
        self.hello: dict[str, Any] = {
            "type": "hello",
            "asepriteVersion": "1.3.18.3",
            "apiVersion": 41,
            "capabilities": ["layer.uuid"],
        }
        # Without an instance the hello is an older extension's, as before.
        if instance is not None:
            self.hello["instance"] = instance
        if name is not None:
            self.hello["instanceName"] = name
        self._task: asyncio.Task | None = None
        self._socket = None
        self.connected = asyncio.Event()

    def reply(self, command: str, result: dict[str, Any] | Callable[[dict], dict]) -> None:
        """Queue a canned result for a command."""
        self.responses[command] = result

    def fail(self, command: str, code: str, message: str = "nope") -> None:
        self.responses[command] = {"__error": {"code": code, "message": message}}

    def last(self, command: str | None = None) -> dict[str, Any]:
        if command is None:
            return self.requests[-1]
        for request in reversed(self.requests):
            if request["command"] == command:
                return request
        raise AssertionError(f"{command} was never called. Saw: {[r['command'] for r in self.requests]}")

    async def start(self, port: int, token: str) -> None:
        self._socket = await connect(f"ws://127.0.0.1:{port}/")
        await self._socket.send(json.dumps({**self.hello, "token": token}))
        await self._socket.recv()  # welcome
        self._task = asyncio.create_task(self._loop())
        self.connected.set()

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, ConnectionClosed):
                pass
        if self._socket:
            await self._socket.close()

    async def _loop(self) -> None:
        assert self._socket is not None
        async for raw in self._socket:
            request = json.loads(raw)
            if "id" not in request:
                self.notices.append(request)
                continue
            self.requests.append(request)
            await self._socket.send(json.dumps(self._respond(request)))

    def _respond(self, request: dict[str, Any]) -> dict[str, Any]:
        command = request["command"]
        params = request.get("params") or {}

        # Render commands must actually produce the file the server will read.
        # This happens before the canned callback runs, so a callback can delete
        # the file to simulate Aseprite reporting success without writing one.
        if "outPath" in params:
            Path(params["outPath"]).write_bytes(self.png)

        canned = self.responses.get(command)
        if callable(canned):
            canned = canned(params)
        if isinstance(canned, dict) and "__error" in canned:
            return {"id": request["id"], "ok": False, "error": canned["__error"]}

        result = canned if isinstance(canned, dict) else {}
        return {"id": request["id"], "ok": True, "result": {"echo": params, **result}}


@pytest.fixture
def sandbox(tmp_path: Path) -> Path:
    root = tmp_path / "sprites"
    root.mkdir()
    return root


@pytest.fixture
def config(sandbox: Path) -> Config:
    return Config(
        host="127.0.0.1",
        port=0,  # let the OS pick, so tests never collide on a fixed port
        allowed_dirs=(sandbox,),
        default_timeout=2.0,
        render_timeout=2.0,
    )


@pytest_asyncio.fixture
async def server(config: Config, tmp_path: Path, monkeypatch):
    """A running server with its bridge listening, but nothing attached yet."""
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "localappdata"))
    mcp, ctx = build_server(config)
    await ctx.bridge.start()
    try:
        yield mcp, ctx
    finally:
        await ctx.bridge.stop()
        ctx.cleanup()


@pytest_asyncio.fixture
async def aseprite(server):
    """A fake extension already attached to the bridge."""
    _mcp, ctx = server
    fake = FakeAseprite()
    await fake.start(ctx.bridge.bound_port, ctx.bridge.token)
    for _ in range(100):
        if ctx.bridge.connected:
            break
        await asyncio.sleep(0.01)
    assert ctx.bridge.connected, "fake extension failed to attach"
    try:
        yield fake
    finally:
        await fake.stop()


async def call_tool(mcp, name: str, **arguments) -> Any:
    """Invoke a tool and return its content blocks."""
    result = await mcp.call_tool(name, arguments)
    return result


def text_of(result) -> str:
    """Concatenate the text blocks of a tool result."""
    return "\n".join(
        block.text for block in result.content if getattr(block, "type", None) == "text"
    )


def json_of(result) -> Any:
    return json.loads(text_of(result))
