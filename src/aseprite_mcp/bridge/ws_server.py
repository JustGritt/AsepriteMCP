"""WebSocket bridge to the Aseprite extension.

Note the direction: the Lua WebSocket class in Aseprite is a *client only* -- it
can dial out but cannot listen. So this process binds the socket and the
extension connects to us, which is the reverse of the diagram in
docs/ASEPRITE_MCP.md section 2.1. See docs/ARCHITECTURE.md.

Only one Aseprite instance may be attached at a time (spec section 4 rules out
multiple Aseprite processes). A newer connection wins and the previous one is
closed, which is the behaviour you want when Aseprite is restarted and the stale
socket has not timed out yet.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from ..config import Config
from .protocol import BridgeError, ErrorCode, decode_message, encode_request, error_from_response
from .session import SessionFile, new_token

log = logging.getLogger(__name__)

PROTOCOL_VERSION = 1

# Frames stay small because previews travel as files rather than payloads; this
# ceiling only needs to cover a large draw_pixels batch or a get_region reply.
MAX_FRAME_BYTES = 8 * 1024 * 1024

# How long a freshly connected client has to identify itself before we drop it.
HELLO_TIMEOUT = 10.0


class AsepriteBridge:
    """Owns the WebSocket server and the request/response correlation table."""

    def __init__(self, config: Config):
        self._config = config
        self._server = None
        self._client: ServerConnection | None = None
        self._pending: dict[int, asyncio.Future] = {}
        self._next_id = 0
        self._token = config.token or new_token()
        self._session: SessionFile | None = None
        self.client_info: dict[str, Any] = {}

    # ------------------------------------------------------------------ lifecycle

    async def start(self) -> None:
        self._server = await serve(
            self._handle_client,
            self._config.host,
            self._config.port,
            max_size=MAX_FRAME_BYTES,
        )
        port = self.bound_port
        self._session = SessionFile(self._config.host, port, self._token)
        self._session.write()
        log.info("Aseprite bridge listening on ws://%s:%s", self._config.host, port)

    async def stop(self) -> None:
        if self._session:
            self._session.remove()
            self._session = None
        self._fail_pending(
            BridgeError(ErrorCode.ASEPRITE_NOT_CONNECTED, "The MCP server is shutting down.")
        )
        client, self._client = self._client, None
        if client is not None:
            try:
                await client.close()
            except (ConnectionClosed, OSError):
                pass
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    @property
    def bound_port(self) -> int:
        """The real port, which matters when the configured port is 0 (tests)."""
        sockets = getattr(self._server, "sockets", None)
        if sockets:
            try:
                return sockets[0].getsockname()[1]
            except (OSError, IndexError):
                pass
        return self._config.port

    @property
    def token(self) -> str:
        return self._token

    # ------------------------------------------------------------------ connection

    @property
    def connected(self) -> bool:
        return self._client is not None

    async def _reject(self, websocket: ServerConnection, reason: str, message: str) -> None:
        payload = {
            "type": "welcome",
            "ok": False,
            "error": {"code": ErrorCode.UNAUTHORIZED.value, "message": message},
        }
        try:
            await websocket.send(json.dumps(payload, separators=(",", ":")))
            await websocket.close(code=1008, reason=reason)
        except (ConnectionClosed, OSError):
            pass

    async def _handle_client(self, websocket: ServerConnection) -> None:
        try:
            raw = await asyncio.wait_for(websocket.recv(), timeout=HELLO_TIMEOUT)
        except asyncio.TimeoutError:
            log.warning("Client connected but sent no hello in %ss; closing.", HELLO_TIMEOUT)
            await self._reject(websocket, "no hello", "Expected a hello message.")
            return
        except ConnectionClosed:
            return

        try:
            hello = decode_message(raw)
        except BridgeError as exc:
            log.warning("Rejected client: %s", exc)
            await self._reject(websocket, "bad hello", "Malformed hello message.")
            return

        if hello.get("type") != "hello":
            log.warning("Rejected client: first message was %r, not a hello.", hello.get("type"))
            await self._reject(websocket, "bad hello", "Expected a hello message.")
            return

        if self._config.require_token and hello.get("token") != self._token:
            # Usually a stale extension still holding a token from a previous run,
            # but it is also what an unauthorised local process looks like.
            log.warning("Rejected client: bad or missing token.")
            await self._reject(websocket, "unauthorized", "Bad or missing token.")
            return

        if self._client is not None:
            log.warning("A second Aseprite instance connected; dropping the previous one.")
            previous, self._client = self._client, None
            try:
                await previous.close(code=1000, reason="superseded")
            except (ConnectionClosed, OSError):
                pass

        self._client = websocket
        self.client_info = {
            "asepriteVersion": hello.get("asepriteVersion"),
            "apiVersion": hello.get("apiVersion"),
            "capabilities": hello.get("capabilities") or [],
        }
        await websocket.send(
            json.dumps(
                {"type": "welcome", "ok": True, "protocolVersion": PROTOCOL_VERSION},
                separators=(",", ":"),
            )
        )
        log.info(
            "Aseprite connected: version=%s apiVersion=%s capabilities=%s",
            self.client_info.get("asepriteVersion"),
            self.client_info.get("apiVersion"),
            self.client_info.get("capabilities"),
        )

        try:
            async for message in websocket:
                self._on_message(message)
        except ConnectionClosed:
            pass
        finally:
            if self._client is websocket:
                self._client = None
                self.client_info = {}
                log.info("Aseprite disconnected.")
                self._fail_pending(
                    BridgeError(
                        ErrorCode.ASEPRITE_NOT_CONNECTED,
                        "Aseprite disconnected before the command completed.",
                    )
                )

    def _on_message(self, raw: str | bytes) -> None:
        try:
            message = decode_message(raw)
        except BridgeError as exc:
            log.warning("Discarding malformed message from Aseprite: %s", exc)
            return

        message_id = message.get("id")
        if not isinstance(message_id, int) or isinstance(message_id, bool):
            # Unsolicited notification rather than a reply.
            if message.get("type") == "log":
                log.info("[aseprite] %s", message.get("message"))
            else:
                log.debug("Unhandled message from Aseprite: %r", message)
            return

        future = self._pending.pop(message_id, None)
        if future is None:
            # Nearly always a response that arrived after its call timed out.
            log.debug("Response for unknown or expired request id %s.", message_id)
            return
        if not future.done():
            future.set_result(message)

    def _fail_pending(self, error: BridgeError) -> None:
        for future in list(self._pending.values()):
            if not future.done():
                future.set_exception(error)
        self._pending.clear()

    # ------------------------------------------------------------------ requests

    async def call(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        """Send a command and await its response.

        Returns the result object. Raises BridgeError for every failure mode,
        including disconnection and timeout, so no caller has to tell transport
        errors apart from Aseprite errors.
        """
        client = self._client
        if client is None:
            raise BridgeError(
                ErrorCode.ASEPRITE_NOT_CONNECTED,
                "No Aseprite extension is currently connected. Start Aseprite with the "
                "aseprite-mcp extension installed and enabled, then try again.",
            )

        self._next_id += 1
        request_id = self._next_id
        loop = asyncio.get_running_loop()
        future: asyncio.Future = loop.create_future()
        self._pending[request_id] = future

        try:
            await client.send(encode_request(request_id, command, params))
        except (ConnectionClosed, OSError) as exc:
            self._pending.pop(request_id, None)
            raise BridgeError(
                ErrorCode.ASEPRITE_NOT_CONNECTED, f"Lost the connection to Aseprite: {exc}"
            ) from exc

        deadline = timeout or self._config.default_timeout
        try:
            message = await asyncio.wait_for(future, deadline)
        except asyncio.TimeoutError as exc:
            self._pending.pop(request_id, None)
            raise BridgeError(
                ErrorCode.TIMEOUT,
                f"Aseprite did not answer {command} within {deadline:g}s. It may be "
                "showing a modal dialog, or busy with a long operation.",
            ) from exc

        if not message.get("ok"):
            raise error_from_response(message)
        result = message.get("result")
        return result if isinstance(result, dict) else {}
