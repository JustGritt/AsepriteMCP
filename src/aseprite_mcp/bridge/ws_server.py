"""WebSocket bridge to the Aseprite extension.

Note the direction: the Lua WebSocket class in Aseprite is a *client only* -- it
can dial out but cannot listen. So this process binds the socket and the
extension connects to us, which is the reverse of the diagram in
docs/ASEPRITE_MCP.md section 2.1. See docs/ARCHITECTURE.md.

Several Aseprite windows can be attached at once, each named by the instance id
its extension sends in the hello (one per Aseprite process, stable across
reconnects). Each MCP session picks the window it drives; see ToolContext and
the select_instance tool. A window that reconnects under the same id replaces
its old socket, which is what you want when the old one has not timed out yet.
An extension too old to send an id is filed under one shared id, so among those
the newest connection wins, as it always did.
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from ..config import Config
from ..extension_check import ExtensionCopy, describe
from .protocol import BridgeError, ErrorCode, decode_message, encode_request, error_from_response
from .session import SessionFile, new_token

log = logging.getLogger(__name__)

PROTOCOL_VERSION = 1

# Frames stay small because previews travel as files rather than payloads; this
# ceiling only needs to cover a large draw_pixels batch or a get_region reply.
MAX_FRAME_BYTES = 8 * 1024 * 1024

# How long a freshly connected client has to identify itself before we drop it.
HELLO_TIMEOUT = 10.0

# How long the command that opens the port waits for Aseprite to attach. A
# running extension redials at least every 5 s (maxreconnectwait in ws.lua).
CONNECT_WAIT_SECONDS = 10.0

# A port opened on demand is let go after this long without a command, so a
# session used this morning does not hold Aseprite against one this afternoon.
IDLE_RELEASE_SECONDS = 600.0

# What to do when another server holds the port, which is almost always another
# MCP session with this server configured.
PORT_HELD_REMEDY = (
    "Aseprite is attached to that process, usually another MCP client session with "
    "this server configured. Close that session, or disable the aseprite server in it "
    "(/mcp in Claude Code), then call again: this server takes the port on its next "
    "command. To share one Aseprite between sessions, run one shared server with "
    "`aseprite-mcp --http PORT` and point every client at its /mcp URL (docs/SETUP.md, "
    "'Multiple sessions'). To run two copies of Aseprite on purpose, give one a different "
    "ASEPRITE_MCP_PORT and enter that port in its File > MCP Bridge... dialog."
)


# The id an extension without instance support is filed under.
LEGACY_INSTANCE = "aseprite"

# Commands an outdated extension may still answer: what get_connection_status
# needs to say what is wrong. Everything else is refused (#16).
DIAGNOSTIC_COMMANDS = frozenset({"app.status", "fs.probe"})

INSTALL_HINT = (
    "Reinstall it (scripts/install-extension.sh, or scripts/install-extension.ps1 on "
    "Windows; an install made with --link needs no reinstall), then quit Aseprite "
    "completely and reopen it. On macOS closing the window leaves Aseprite running: "
    "use Cmd+Q."
)


@dataclass(eq=False)
class Instance:
    """One connected Aseprite window."""

    id: str
    name: str | None
    websocket: ServerConnection = field(repr=False)
    info: dict[str, Any] = field(default_factory=dict)
    # The extension's own files as it reported them at load (path -> content
    # hash), or why it could not read them. Neither: an extension from before
    # the check, which is older than this server by definition.
    files: dict[str, int] | None = field(default=None, repr=False)
    files_error: str | None = None

    @property
    def label(self) -> str:
        return f"{self.name} ({self.id})" if self.name else self.id


class AsepriteBridge:
    """Owns the WebSocket server, the connected windows, and the request table."""

    def __init__(self, config: Config):
        self._config = config
        self._server = None
        self._instances: dict[str, Instance] = {}
        # request id -> (future, the socket the request went out on), so a
        # window that disconnects fails its own calls and nobody else's.
        self._pending: dict[int, tuple[asyncio.Future, ServerConnection]] = {}
        self._next_id = 0
        self._token = config.token or new_token()
        self._session: SessionFile | None = None
        self._bind_error: str | None = None
        self._bind_lock = asyncio.Lock()
        # Set while the port was opened by a command rather than by start().
        self._idle_task: asyncio.Task | None = None
        directory = config.extension_dir
        self._extension = (
            ExtensionCopy(directory) if directory is not None and directory.is_dir() else None
        )

    # ------------------------------------------------------------------ lifecycle

    async def _bind(self) -> bool:
        """Try to take the port. Returns whether we now own it."""
        try:
            self._server = await serve(
                self._handle_client,
                self._config.host,
                self._config.port,
                max_size=MAX_FRAME_BYTES,
            )
        except OSError as exc:
            self._server = None
            self._bind_error = (
                f"Another process is already listening on "
                f"{self._config.host}:{self._config.port} ({exc.strerror or exc})."
            )
            return False

        self._bind_error = None
        port = self.bound_port
        self._session = SessionFile(self._config.host, port, self._token)
        self._session.write()
        log.info("Aseprite bridge listening on ws://%s:%s", self._config.host, port)
        return True

    async def start(self) -> None:
        """Listen now, or carry on without the port if it is taken.

        The shared HTTP server calls this, since it exists to own the port. A
        stdio server does not: it binds on its first command (see call()), so a
        session that never touches Aseprite never holds the port against one
        that does (#19).

        Binding used to be fatal, which made the whole server unusable under any
        MCP client that spawns more than one instance: the second process died
        with Errno 10048 before it could answer tools/list. The loser still
        serves the tool list and says clearly why calls fail.
        """
        if not await self._bind():
            log.warning("%s Serving tools without a bridge.", self._bind_error)

    async def _bind_on_demand(self) -> None:
        """Open the port for a command, then give Aseprite a moment to attach."""
        async with self._bind_lock:
            if self._server is not None or not await self._bind():
                return
        loop = asyncio.get_running_loop()
        deadline = loop.time() + CONNECT_WAIT_SECONDS
        while not self._instances and loop.time() < deadline:
            await asyncio.sleep(0.05)

    async def _release_after_idle(self) -> None:
        await asyncio.sleep(IDLE_RELEASE_SECONDS)
        self._idle_task = None
        log.info("No command in %gs; releasing the bridge port.", IDLE_RELEASE_SECONDS)
        await self._release()

    @property
    def listening(self) -> bool:
        return self._server is not None

    @property
    def bind_error(self) -> str | None:
        """Why this process does not own the bridge port, if it does not."""
        return self._bind_error

    async def stop(self) -> None:
        if self._idle_task is not None:
            self._idle_task.cancel()
            self._idle_task = None
        await self._release()

    async def _release(self) -> None:
        if self._session:
            self._session.remove()
            self._session = None
        self._fail_pending(
            BridgeError(ErrorCode.ASEPRITE_NOT_CONNECTED, "The MCP server is shutting down.")
        )
        instances, self._instances = list(self._instances.values()), {}
        for instance in instances:
            try:
                await instance.websocket.close()
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
        return bool(self._instances)

    @property
    def instances(self) -> list[Instance]:
        """Connected windows, oldest connection first."""
        return list(self._instances.values())

    @property
    def client_info(self) -> dict[str, Any]:
        """Version details of the most recently connected window, or {}."""
        return self.instances[-1].info if self._instances else {}

    def _labels(self) -> str:
        return ", ".join(instance.label for instance in self._instances.values())

    def _not_connected(self) -> BridgeError:
        if self._bind_error:
            # Sending the user to check their extension would waste their time:
            # it is almost certainly connected, just to a different copy of this
            # server.
            return BridgeError(
                ErrorCode.ASEPRITE_NOT_CONNECTED, f"{self._bind_error} {PORT_HELD_REMEDY}"
            )
        return BridgeError(
            ErrorCode.ASEPRITE_NOT_CONNECTED,
            "No Aseprite extension is currently connected. Start Aseprite with the "
            "aseprite-mcp extension installed and enabled, then try again. If it is "
            "running, File > MCP Bridge... shows the address it dials and why it fails.",
        )

    def resolve(self, selected: str | None) -> Instance:
        """The window a call goes to.

        The session's choice if it made one; otherwise the only window
        connected. With several connected and no choice, refuse rather than
        guess: a guess is an edit landing in another agent's sprite.
        """
        if not self._instances:
            raise self._not_connected()
        if selected is not None:
            instance = self._instances.get(selected)
            if instance is None:
                raise BridgeError(
                    ErrorCode.ASEPRITE_NOT_CONNECTED,
                    f"The Aseprite window this session selected ({selected}) is not "
                    f"connected. Connected now: {self._labels()}. Call select_instance "
                    "to choose one.",
                )
            return instance
        if len(self._instances) == 1:
            return next(iter(self._instances.values()))
        raise BridgeError(
            ErrorCode.INSTANCE_REQUIRED,
            f"{len(self._instances)} Aseprite windows are connected and this session has "
            f"not chosen one: {self._labels()}. Call select_instance with one of them "
            "(or pass aseprite_instance on each call if your client keeps no MCP "
            "session); get_connection_status shows what each has open.",
        )

    def extension_status(self, instance: Instance) -> dict[str, Any]:
        """How the window's extension compares with this server's copy.

        {} when there is nothing to compare with. Otherwise extensionUpToDate is
        True, or False with staleFiles or extensionPredatesCheck. An extension
        that could not read its own files gets only extensionCheck, saying why:
        that is not counted against it.
        """
        if self._extension is None:
            return {}
        if instance.files is None:
            if instance.files_error is not None:
                return {"extensionCheck": f"not checked: {instance.files_error}"}
            return {"extensionUpToDate": False, "extensionPredatesCheck": True}
        stale = self._extension.differences(instance.files)
        if stale:
            return {"extensionUpToDate": False, "staleFiles": stale}
        return {"extensionUpToDate": True}

    def _outdated(self, instance: Instance) -> BridgeError | None:
        status = self.extension_status(instance)
        if status.get("extensionUpToDate") is not False:
            return None
        if status.get("extensionPredatesCheck"):
            what = "predates the version check, so it is older than this server"
        else:
            what = (
                "differs from this server's copy in "
                f"{describe(status['staleFiles'])}"
            )
        return BridgeError(
            ErrorCode.EXTENSION_OUTDATED,
            f"The Aseprite extension in window {instance.label} {what}. Its replies "
            f"cannot be trusted to mean what these tools expect. {INSTALL_HINT}",
        )

    def match(self, selector: str) -> Instance | None:
        """A connected window by id, name, or unique id prefix; None if none match."""
        if selector in self._instances:
            return self._instances[selector]
        by_name = [i for i in self._instances.values() if i.name == selector]
        if len(by_name) == 1:
            return by_name[0]
        by_prefix = [i for i in self._instances.values() if i.id.startswith(selector)]
        if len(by_name) > 1 or len(by_prefix) > 1:
            raise BridgeError(
                ErrorCode.INVALID_PARAMS,
                f"{selector!r} matches more than one Aseprite window: {self._labels()}. "
                "Use the id.",
            )
        return by_prefix[0] if by_prefix else None

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

        instance_id = hello.get("instance")
        if not isinstance(instance_id, str) or not instance_id:
            instance_id = LEGACY_INSTANCE
        name = hello.get("instanceName")
        files = hello.get("files")
        files_error = hello.get("filesError")
        instance = Instance(
            id=instance_id,
            name=name if isinstance(name, str) and name else None,
            files={str(k): v for k, v in files.items()} if isinstance(files, dict) else None,
            files_error=str(files_error) if files_error else None,
            websocket=websocket,
            info={
                "asepriteVersion": hello.get("asepriteVersion"),
                "apiVersion": hello.get("apiVersion"),
                "capabilities": hello.get("capabilities") or [],
            },
        )

        previous = self._instances.pop(instance_id, None)
        if previous is not None:
            log.info("Aseprite %s reconnected; dropping its previous socket.", instance.label)
            self._fail_pending(
                BridgeError(
                    ErrorCode.ASEPRITE_NOT_CONNECTED,
                    "Aseprite reconnected before the command completed.",
                ),
                previous.websocket,
            )
            try:
                await previous.websocket.close(code=1000, reason="superseded")
            except (ConnectionClosed, OSError):
                pass

        self._instances[instance_id] = instance
        await websocket.send(
            json.dumps(
                {"type": "welcome", "ok": True, "protocolVersion": PROTOCOL_VERSION},
                separators=(",", ":"),
            )
        )
        log.info(
            "Aseprite %s connected: version=%s apiVersion=%s capabilities=%s",
            instance.label,
            instance.info.get("asepriteVersion"),
            instance.info.get("apiVersion"),
            instance.info.get("capabilities"),
        )

        try:
            async for message in websocket:
                self._on_message(message)
        except ConnectionClosed:
            pass
        finally:
            if self._instances.get(instance_id) is instance:
                del self._instances[instance_id]
                log.info("Aseprite %s disconnected.", instance.label)
            self._fail_pending(
                BridgeError(
                    ErrorCode.ASEPRITE_NOT_CONNECTED,
                    "Aseprite disconnected before the command completed.",
                ),
                websocket,
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

        entry = self._pending.pop(message_id, None)
        future = entry[0] if entry else None
        if future is None:
            # Nearly always a response that arrived after its call timed out.
            log.debug("Response for unknown or expired request id %s.", message_id)
            return
        if not future.done():
            future.set_result(message)

    def _fail_pending(self, error: BridgeError, websocket: ServerConnection | None = None) -> None:
        """Fail the calls waiting on one socket, or on every socket."""
        for request_id, (future, sent_on) in list(self._pending.items()):
            if websocket is None or sent_on is websocket:
                del self._pending[request_id]
                if not future.done():
                    future.set_exception(error)

    # ------------------------------------------------------------------ requests

    async def call(
        self,
        command: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
        instance: str | None = None,
    ) -> dict[str, Any]:
        """Send a command to a window and await its response.

        `instance` is the session's chosen window, if any; see resolve(). Returns
        the result object. Raises BridgeError for every failure mode, including
        disconnection and timeout, so no caller has to tell transport errors
        apart from Aseprite errors.
        """
        # A port start() opened is never released; one a command opened is.
        on_demand = self._server is None or self._idle_task is not None
        if self._server is None:
            await self._bind_on_demand()
        if on_demand and self._server is not None:
            if self._idle_task is not None:
                self._idle_task.cancel()
            self._idle_task = asyncio.create_task(self._release_after_idle())

        target = self.resolve(instance)
        if command not in DIAGNOSTIC_COMMANDS:
            outdated = self._outdated(target)
            if outdated is not None:
                raise outdated
        client = target.websocket

        self._next_id += 1
        request_id = self._next_id
        loop = asyncio.get_running_loop()
        future: asyncio.Future = loop.create_future()
        self._pending[request_id] = (future, client)

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
