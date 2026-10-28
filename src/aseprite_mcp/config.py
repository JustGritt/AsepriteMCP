"""Runtime configuration, all of it from the environment."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PORT = 32145
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def _repo_root() -> Path:
    """Walk up from this file looking for the project marker.

    Falls back to the current working directory when installed as a wheel, where
    there is no pyproject.toml to find.
    """
    for parent in Path(__file__).resolve().parents:
        if (parent / "pyproject.toml").is_file():
            return parent
    return Path.cwd()


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc
    if value <= 0:
        raise ValueError(f"{name} must be positive, got {value}")
    return value


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    allowed_dirs: tuple = field(default_factory=tuple)

    # Per docs/ASEPRITE_MCP.md section 23.
    default_timeout: float = 5.0
    # Rendering a scaled contact sheet is per-pixel work in Lua and can outrun 5s.
    render_timeout: float = 30.0

    # Caps that stop a single call from stalling Aseprite or flooding the agent.
    max_pixels_per_call: int = 20000
    max_region_pixels: int = 4096

    # Longest edge of a rendered image, in pixels. An image costs the model about
    # width*height/750 tokens and stays in its context for the rest of the
    # session, so these caps are the real price of a preview. Scales stay whole
    # numbers, so a capped render is smaller rather than blurred.
    preview_max_edge: int = 768
    sheet_max_edge: int = 1280

    # Opt-in JSONL log of what every tool call cost; see aseprite_mcp.usage.
    usage_log: Path | None = None

    # Off by default. Token auth means the extension has to learn a secret, and
    # the only channel for that is a file -- which Aseprite gates behind a
    # per-script Security modal that fails closed. Requiring it out of the box
    # made the bridge unable to connect at all on a fresh install. Loopback-only
    # binding is what spec section 21 actually asks for; the token is available
    # as opt-in hardening by setting ASEPRITE_MCP_TOKEN in both environments.
    require_token: bool = False
    token: str = ""
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> "Config":
        host = os.environ.get("ASEPRITE_MCP_HOST", "127.0.0.1").strip() or "127.0.0.1"
        if host not in LOOPBACK_HOSTS and os.environ.get("ASEPRITE_MCP_ALLOW_NON_LOOPBACK") != "1":
            raise ValueError(
                f"Refusing to bind the Aseprite bridge to non-loopback host {host!r}. "
                "Set ASEPRITE_MCP_ALLOW_NON_LOOPBACK=1 only if you understand that "
                "this exposes control of your Aseprite session to the network."
            )

        raw_dirs = os.environ.get("ASEPRITE_MCP_ALLOWED_DIRS", "").strip()
        if raw_dirs:
            # Always ';' on Windows: os.pathsep there is ';' too, but splitting on
            # ':' would tear 'C:\...' in half on any platform that used it.
            separator = ";" if os.name == "nt" else os.pathsep
            parts = [p.strip() for p in raw_dirs.split(separator)]
            dirs = tuple(Path(os.path.expanduser(p)).resolve() for p in parts if p)
        else:
            dirs = (_repo_root() / "sprites",)

        token = os.environ.get("ASEPRITE_MCP_TOKEN", "").strip()
        usage_log = os.environ.get("ASEPRITE_MCP_USAGE_LOG", "").strip()

        return cls(
            host=host,
            port=_env_int("ASEPRITE_MCP_PORT", DEFAULT_PORT),
            allowed_dirs=dirs,
            default_timeout=_env_float("ASEPRITE_MCP_TIMEOUT", 5.0),
            render_timeout=_env_float("ASEPRITE_MCP_RENDER_TIMEOUT", 30.0),
            max_pixels_per_call=_env_int("ASEPRITE_MCP_MAX_PIXELS", 20000),
            max_region_pixels=_env_int("ASEPRITE_MCP_MAX_REGION_PIXELS", 4096),
            preview_max_edge=_env_int("ASEPRITE_MCP_PREVIEW_MAX_EDGE", 768),
            sheet_max_edge=_env_int("ASEPRITE_MCP_SHEET_MAX_EDGE", 1280),
            usage_log=Path(os.path.expanduser(usage_log)).resolve() if usage_log else None,
            require_token=bool(token) or os.environ.get("ASEPRITE_MCP_REQUIRE_TOKEN") == "1",
            token=token,
            log_level=os.environ.get("ASEPRITE_MCP_LOG_LEVEL", "INFO").upper(),
        )
