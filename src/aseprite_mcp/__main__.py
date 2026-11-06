"""Console entry point: ``aseprite-mcp``."""

from __future__ import annotations

import argparse
import logging
import sys

from .config import Config
from .server import build_server


def _port(value: str) -> int:
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Control a live Aseprite session.")
    parser.add_argument("--http", type=_port, metavar="PORT",
                        help="serve shared MCP HTTP on 127.0.0.1:PORT/mcp instead of stdio")
    args = parser.parse_args(argv)
    try:
        config = Config.from_env()
        if args.http == config.port:
            parser.error("HTTP and Aseprite bridge ports must be different")
    except ValueError as exc:
        print(f"aseprite-mcp: {exc}", file=sys.stderr)
        return 2

    # stdout carries the MCP stream, so every log line must go to stderr.
    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    mcp, _ctx = build_server(config, shared=args.http is not None)
    if args.http is not None:
        mcp.run("streamable-http", host="127.0.0.1", port=args.http)
    else:
        mcp.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
