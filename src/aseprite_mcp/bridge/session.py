"""Port + token record for the bridge, written for the operator and for tooling.

This file is *not* a discovery channel for the extension, and it cannot become
one: Aseprite gates every filesystem read behind a per-script Security modal,
and `app.fs.isFile` returns false for an un-granted path without prompting. An
extension that polled for this file would therefore report "no server" forever,
with no dialog and no error -- which is exactly what happened before the
extension was switched to a fixed default port plus env overrides (see
docs/SETUP.md).

What the file is still good for: it is the only place the randomly generated
token is written down, so when `ASEPRITE_MCP_REQUIRE_TOKEN=1` is set this is
where a human reads the value to put in `ASEPRITE_MCP_TOKEN` on the Aseprite
side. Both processes run as the same user, so ordinary file permissions are the
trust boundary.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
from pathlib import Path

log = logging.getLogger(__name__)

SCHEMA_VERSION = 1


def session_file_path() -> Path:
    """Well-known per-user location, documented in docs/SETUP.md."""
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or (Path.home() / "AppData" / "Local")
    else:
        base = os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")
    return Path(base) / "aseprite-mcp" / "session.json"


def new_token() -> str:
    return secrets.token_hex(16)


class SessionFile:
    """Writes the discovery file on start, removes it on stop."""

    def __init__(self, host: str, port: int, token: str, path: Path | None = None):
        self.host = host
        self.port = port
        self.token = token
        self.path = path or session_file_path()

    def write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": SCHEMA_VERSION,
            "host": self.host,
            "port": self.port,
            "token": self.token,
            "pid": os.getpid(),
        }
        # Write-then-replace so a concurrent reader never sees a partial file.
        temp = self.path.with_suffix(".json.tmp")
        temp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        os.replace(temp, self.path)
        if os.name != "nt":
            os.chmod(self.path, 0o600)
        log.info("Wrote session discovery file: %s (port %s)", self.path, self.port)

    def remove(self) -> None:
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            log.warning("Could not remove session file %s: %s", self.path, exc)
