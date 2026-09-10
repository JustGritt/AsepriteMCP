# aseprite-mcp

An MCP server that lets an AI agent drive a **live** Aseprite session in an
`edit -> preview -> analyze -> correct` loop for pixel-art animation.

Edits land in the document you already have open, so you watch them happen.

- Design goals and scope: [`docs/ASEPRITE_MCP.md`](docs/ASEPRITE_MCP.md)
- Setup: [`docs/SETUP.md`](docs/SETUP.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Wire protocol: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- Tool reference: [`docs/TOOLS.md`](docs/TOOLS.md)

## Requirements

- Aseprite 1.3 or newer (needs the `WebSocket`, `json` and `Timer` script APIs)
- Python 3.10+

## Quick start

```sh
uv sync
uv run pytest
powershell -ExecutionPolicy Bypass -File scripts/install-extension.ps1
```

Restart Aseprite, then register the server with your MCP client:

```sh
claude mcp add aseprite -- uv run --directory /path/to/AsepriteMCP aseprite-mcp
```

See [`docs/SETUP.md`](docs/SETUP.md) for the file-access trust prompt Aseprite
shows on first run, which previews depend on.
