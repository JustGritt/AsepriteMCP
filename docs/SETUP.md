# Setup

## Requirements

- **Aseprite 1.3 or newer.** The bridge needs the `WebSocket`, `json` and `Timer`
  script APIs, none of which exist in 1.2. Developed and tested against 1.3.18.3
  (API version 41).
- **Python 3.10+**, and ideally [uv](https://docs.astral.sh/uv/).

## 1. Install the Python server

```sh
uv sync
uv run pytest          # 205 tests, no Aseprite needed
```

## 2. Install the Aseprite extension

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-extension.ps1
```

Pass `-Link` to install a junction instead of a copy, so edits in the repo take
effect on the next Aseprite restart. Pass `-Uninstall` to remove it.

To install by hand instead: zip the contents of `extension/aseprite-mcp` as
`aseprite-mcp.aseprite-extension` and use **Edit > Preferences > Extensions >
Add Extension**.

**Restart Aseprite.** Extensions are only loaded at startup.

Check it loaded: **File > Scripts > MCP Bridge: Status**.

## 3. Grant file-system access (one time, and it matters)

The first time the agent renders a preview, opens or saves a sprite, Aseprite
shows a **Security** dialog like this:

```
The following script:
    ...\extensions\aseprite-mcp\fsio.lua
wants to access this file:
    ...\Temp\aseprite-mcp-xxxx\preview.png

[ ] Don't show this specific alert again for this script
[x] Give full trust to this script          <- tick this one

   [ Allow Write Access ]   [ Stop Script ]
```

**Tick "Give full trust to this script", then allow.**

Why it matters:

- Previews are PNGs written to a temp file, so **nothing visual works** without
  it. `get_connection_status` reports `"canWriteFiles": false` when it is missing.
- The dialog is *modal inside Aseprite*, and it blocks the bridge while it waits.
  A tool call that lands on an unanswered dialog returns `TIMEOUT` saying exactly
  that.
- Aseprite scopes the grant to **one script file and one target path**. Ticking
  "Give full trust" instead grants the script blanket access, so you answer this
  once rather than on every new sprite you open.

Every filesystem operation in the extension is deliberately funnelled through
`fsio.lua` for this reason: one script file to trust, one dialog, ever. If you
only click "Allow" without ticking full trust, you will be asked again for the
next file.

## 4. Point your MCP client at the server

```sh
claude mcp add aseprite -- uv run --directory /path/to/AsepriteMCP aseprite-mcp
```

Order does not matter: the extension retries until the server appears, and
reconnects on its own if the server restarts.

## Configuration

All optional. The defaults work.

| Variable | Default | Meaning |
|---|---|---|
| `ASEPRITE_MCP_ALLOWED_DIRS` | `<repo>/sprites` | Directories `open_sprite` and `save_sprite` may touch, `;`-separated. Everything else is refused. |
| `ASEPRITE_MCP_PORT` | `32145` | Bridge port. Set it for **both** the server and Aseprite if you change it. |
| `ASEPRITE_MCP_HOST` | `127.0.0.1` | Loopback only unless `ASEPRITE_MCP_ALLOW_NON_LOOPBACK=1`. |
| `ASEPRITE_MCP_TOKEN` | unset | Opt-in shared secret; set the same value in both environments. |
| `ASEPRITE_MCP_TIMEOUT` | `5` | Seconds to wait for a normal command. |
| `ASEPRITE_MCP_RENDER_TIMEOUT` | `30` | Seconds to wait for a render. |
| `ASEPRITE_MCP_MAX_PIXELS` | `20000` | Cap on one `draw_pixels` batch. |
| `ASEPRITE_MCP_LOG_LEVEL` | `INFO` | Server log level, written to stderr. |
| `ASEPRITE_MCP_DEBUG` | unset | Set to `1` in Aseprite's environment to write `%TEMP%/aseprite-mcp-debug.log`. |

### About the token

Token auth is **off by default**, which is a deliberate reversal of the original
design. The extension would have to learn the secret from a file, and Aseprite
gates script file reads behind the Security dialog above — which fails *closed*
and, for `app.fs.isFile`, without even prompting. Requiring a token out of the
box therefore made the bridge unable to connect at all on a fresh install, with
no visible symptom.

The bridge binds to `127.0.0.1` only, which is what the project spec asks for. If
you want the extra hardening, set the same `ASEPRITE_MCP_TOKEN` in both
environments and grant `fsio.lua` full trust so the extension can read it.

## Verifying

```sh
uv run pytest                 # server + tool surface, no Aseprite
uv run pytest -m lua          # Lua handlers against a real Aseprite, headless
```

The Lua tests find Aseprite automatically in the usual install locations; set
`ASEPRITE_PATH` if yours lives elsewhere.

Then, with Aseprite open, ask the agent for `get_connection_status`. A healthy
answer looks like:

```json
{
  "connected": true,
  "asepriteVersion": "1.3.18.3",
  "apiVersion": 41,
  "capabilities": ["layer.uuid"],
  "canWriteFiles": true,
  "documentOpen": true
}
```

## Troubleshooting

**`ASEPRITE_NOT_CONNECTED`**
Aseprite is not running, the extension is not installed, or it was stopped from
**File > Scripts > MCP Bridge: Start/Stop**. Check **MCP Bridge: Status**; it
reports the port it is dialling and the last error.

**`TIMEOUT` on the first preview or open**
Almost always the Security dialog waiting for a click. Switch to Aseprite and
answer it, ticking "Give full trust to this script".

**`"canWriteFiles": false`**
The grant above is missing or was denied. Aseprite remembers a denial, so you may
need **Edit > Preferences**, or remove the `[script_access]` entry from
`%APPDATA%/Aseprite/aseprite.ini` to be asked again.

**`DOCUMENT_LOCKED`**
A command landed while Aseprite was busy with another operation, typically a
brush stroke in progress. Retry it.

**Nothing at all happens**
Set `ASEPRITE_MCP_DEBUG=1` in the environment you launch Aseprite from and read
`%TEMP%/aseprite-mcp-debug.log`. It records extension load, pump start, dial
attempts and socket events. The bridge is otherwise deliberately silent, because
`print` from a script pops Aseprite's Console window on every launch.
