"""Connection status (spec section 24)."""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from ..bridge.protocol import BridgeError
from .base import ToolContext, as_json


def register(mcp: MCPServer, ctx: ToolContext) -> None:
    @mcp.tool(
        title="Get connection status",
        description=(
            "Report whether the Aseprite extension is connected and which document is "
            "open. Call this first when any other tool reports ASEPRITE_NOT_CONNECTED."
        ),
    )
    async def get_connection_status() -> str:
        status = {
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
                    "when an MCP client starts more than one copy of the server, or "
                    "when two clients are configured with the same port. Give one of "
                    "them a different ASEPRITE_MCP_PORT and enter the matching port in "
                    "Aseprite's File > MCP Bridge... dialog."
                )
            else:
                status["hint"] = (
                    "Start Aseprite with the aseprite-mcp extension installed. The extension "
                    "connects on its own within a few seconds and retries automatically. "
                    "If it never connects, check Edit > Preferences > Extensions."
                )
            return as_json(status)

        status.update(ctx.bridge.client_info)
        try:
            status.update(await ctx.bridge.call("app.status"))
        except BridgeError as exc:
            status["documentOpen"] = None
            status["error"] = exc.to_dict()

        # Probed here rather than at extension startup: the probe writes a file,
        # and Aseprite raises a Security modal the first time a script does that.
        # Asking on demand keeps the prompt tied to a deliberate action.
        try:
            status.update(await ctx.bridge.call("fs.probe"))
        except BridgeError as exc:
            status["canWriteFiles"] = None
            status["probeError"] = exc.to_dict()

        if status.get("canWriteFiles") is False:
            status["hint"] = (
                "Aseprite has not granted the extension file-system access, so previews "
                "and saving will fail. Trigger any preview, then in the Security dialog "
                "tick 'Give full trust to this script' and allow it. See docs/SETUP.md."
            )
        return as_json(status)
