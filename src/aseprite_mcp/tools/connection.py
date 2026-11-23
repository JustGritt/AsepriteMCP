"""Connection status and window selection (spec section 24).

One server can hold several Aseprite windows, and over HTTP several MCP
sessions share it. Each session drives one window: the only one connected, or
the one it chose with select_instance. Choosing is never guessed for it.
"""

from __future__ import annotations

import asyncio
from typing import Any

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError, ErrorCode
from ..bridge.ws_server import INSTALL_HINT, Instance
from .base import ToolContext, as_json


async def _status_of(ctx: ToolContext, instance: Instance) -> dict[str, Any]:
    """What one window has open, or the error that stopped us finding out."""
    try:
        return await ctx.bridge.call("app.status", instance=instance.id)
    except BridgeError as exc:
        return {"error": exc.code.value}


async def _describe_all(ctx: ToolContext) -> list[dict[str, Any]]:
    instances = ctx.bridge.instances
    statuses = await asyncio.gather(*(_status_of(ctx, i) for i in instances))
    selected = ctx.selected_instance()
    out = []
    for instance, status in zip(instances, statuses):
        out.append({
            "id": instance.id,
            "name": instance.name,
            "document": status.get("document"),
            "documents": status.get("documents"),
            "error": status.get("error"),
            "selected": True if instance.id == selected else None,
            "outdated": True if ctx.bridge.extension_status(instance).get(
                "extensionUpToDate") is False else None,
        })
    return out


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get connection status",
        description=(
            "Whether Aseprite is connected, which document is open and whether previews can "
            "be written. Call it first when a tool reports ASEPRITE_NOT_CONNECTED or "
            "INSTANCE_REQUIRED."
        ),
    )
    async def get_connection_status() -> str:
        status: dict[str, Any] = {
            "connected": ctx.bridge.connected,
            "bridge": {"host": ctx.config.host, "port": ctx.bridge.bound_port},
            "allowedDirectories": [str(d) for d in ctx.config.allowed_dirs],
        }

        if not ctx.bridge.connected:
            # Never raise here: this is the tool the agent uses to diagnose, so it
            # has to answer even when nothing is attached.
            if ctx.bridge.bind_error:
                # This process lost the race for the port, so Aseprite is talking
                # to a different one. Say so rather than sending the user off to
                # check an extension that is working perfectly well.
                status["bridgePortOwnedElsewhere"] = True
                status["hint"] = (
                    f"{ctx.bridge.bind_error} Aseprite is connected to that process, "
                    "not this one, so no command can reach it from here. This happens "
                    "when another MCP session already runs its own copy of the server. "
                    "To use Aseprite from several sessions at once, run one shared "
                    "server with `aseprite-mcp --http PORT` and point every client at "
                    "its /mcp URL (docs/SETUP.md, 'Multiple sessions')."
                )
            else:
                # Not "start Aseprite": it may well be running, attached to a
                # server that died, and the user needs to know what to press (#18).
                status["hint"] = (
                    "No Aseprite window is attached to this server. If Aseprite is not "
                    "running, start it with the aseprite-mcp extension installed; it "
                    "connects within a few seconds. If it is already running, its "
                    "extension redials on its own within about 30 seconds of losing a "
                    "server. If it still has not attached after that, ask the user to "
                    "press File > MCP Bridge... > Reconnect in Aseprite, and to check "
                    "the extension is enabled under Edit > Preferences > Extensions."
                )
            return as_json(status)

        selected = ctx.selected_instance()
        if len(ctx.bridge.instances) > 1 or selected is not None:
            status["instances"] = await _describe_all(ctx)
        try:
            target = ctx.bridge.resolve(selected)
        except BridgeError as exc:
            status["error"] = exc.to_dict()
            status["hint"] = (
                "Several Aseprite windows are connected. Call select_instance with the id, "
                "name or an open document of the one this session should drive."
            )
            return as_json(status)

        status["instance"] = target.id
        status.update(target.info)
        check = ctx.bridge.extension_status(target)
        status.update(check)
        try:
            status.update(await ctx.call("app.status"))
        except BridgeError as exc:
            status["documentOpen"] = None
            status["error"] = exc.to_dict()

        # Probed here rather than at extension startup: the probe writes a file,
        # and Aseprite raises a Security modal the first time a script does that.
        # Asking on demand keeps the prompt tied to a deliberate action.
        try:
            status.update(await ctx.call("fs.probe"))
        except BridgeError as exc:
            status["canWriteFiles"] = None
            status["probeError"] = exc.to_dict()

        if check.get("extensionUpToDate") is False:
            status["hint"] = (
                "Aseprite is running an outdated copy of the aseprite-mcp extension, so "
                "every other tool refuses with EXTENSION_OUTDATED. "
                + INSTALL_HINT
            )
            return as_json(status)

        if status.get("canWriteFiles") is False:
            status["hint"] = (
                "Aseprite has not granted the extension file-system access, so previews "
                "and saving will fail. Trigger any preview, then in the Security dialog "
                "tick 'Give full trust to this script' and allow it. See docs/SETUP.md."
            )
        return as_json(status)

    @mcp.tool(
        title="Select instance",
        description=(
            "Pick the Aseprite window this session drives when several are connected, by "
            "id, name or the file name of a document it has open."
        ),
    )
    async def select_instance(instance: str) -> str:
        if not ctx.bridge.connected:
            raise BridgeError(
                ErrorCode.ASEPRITE_NOT_CONNECTED, "No Aseprite window is connected."
            )
        chosen = ctx.bridge.match(instance)
        if chosen is None:
            # Not an id or a name: try the documents each window has open.
            described = await _describe_all(ctx)
            holding = [
                d for d in described
                if instance == d.get("document") or instance in (d.get("documents") or [])
            ]
            if len(holding) > 1:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"More than one Aseprite window has {instance!r} open: "
                    f"{', '.join(d['id'] for d in holding)}. Use the id.",
                )
            if not holding:
                raise BridgeError(
                    ErrorCode.INVALID_PARAMS,
                    f"No connected Aseprite window matches {instance!r} by id, name or open "
                    f"document. Connected: {as_json(described)}",
                )
            chosen = ctx.bridge.match(holding[0]["id"])
            assert chosen is not None
        ctx.instance = chosen.id
        status = await _status_of(ctx, chosen)
        return as_json({
            "selected": chosen.id,
            "name": chosen.name,
            "document": status.get("document"),
        })
