"""Console entry point: ``aseprite-mcp``."""

from __future__ import annotations

import logging
import sys

from .config import Config
from .server import build_server


def main() -> int:
    try:
        config = Config.from_env()
    except ValueError as exc:
        print(f"aseprite-mcp: {exc}", file=sys.stderr)
        return 2

    # stdout carries the MCP stream, so every log line must go to stderr.
    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    mcp, _ctx = build_server(config)
    mcp.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
