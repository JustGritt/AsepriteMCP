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

On macOS and Linux:

```sh
scripts/install-extension.sh
```

Pass `-Link` (`--link`) to install a junction or symlink instead of a copy, so
edits in the repo take effect on the next Aseprite restart. Pass `-Uninstall`
(`--uninstall`) to remove it.

To install by hand instead: zip the contents of `extension/aseprite-mcp` as
`aseprite-mcp.aseprite-extension` and use **Edit > Preferences > Extensions >
Add Extension**.

**Restart Aseprite.** Extensions are only loaded at startup.

Check it loaded: **File > MCP Bridge...**, which opens the connect dialog
described in [The connect dialog](#the-connect-dialog).

> Upgrading from an earlier build: this one command replaces the old
> `MCP Bridge: Start/Stop` and `MCP Bridge: Status` entries. Their command ids
> are gone, so any keyboard shortcut bound to them needs rebinding.

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

### Multiple sessions: one shared HTTP server

Start this once in a terminal and leave it running:

```powershell
uv run --directory C:\path\to\AsepriteMCP aseprite-mcp --http 8766
```

Or, on Windows, have it start at logon with no window (run once; no admin
needed; `-Uninstall` removes it):

```powershell
scripts\install-server-task.ps1 -AllowedDirs 'C:\path\to\sprites;D:\other\art'
```

It runs this checkout's `.venv` (`uv sync` first) and saves `-AllowedDirs` as
your user's `ASEPRITE_MCP_ALLOWED_DIRS`. After pulling or switching branches,
`Stop-ScheduledTask aseprite-mcp; Start-ScheduledTask aseprite-mcp`.

Configure every MCP client to
use the same Streamable HTTP URL: `http://127.0.0.1:8766/mcp`. For clients with
JSON MCP configuration, the server entry is typically:

```json
{
  "mcpServers": {
    "aseprite": {
      "type": "http",
      "url": "http://127.0.0.1:8766/mcp"
    }
  }
}
```

Replace the old command/args entry with the URL entry; do not launch a server
per session. Stop existing stdio server processes before starting the shared
server, then reconnect your MCP clients. HTTP mode fails at startup with a
remedy if another process owns the bridge port.

The two ports have different jobs: `8766` is for MCP clients; `32145` remains
the Aseprite WebSocket bridge. Leave **File > MCP Bridge...** on `32145`.
If `8766` is occupied, choose another `--http` port and update the client URLs.
If an unrelated app owns `32145`, change `ASEPRITE_MCP_PORT` and the Aseprite
dialog to the same free port. HTTP always binds to `127.0.0.1`.

Whole tool calls on one Aseprite window are serialized, including batches and
their previews; agents on different windows do not wait for each other. Drawing
legends and preview history are separate for each HTTP session (the most recent
128 sessions are remembered; stateless requests have no remembered history).
Disconnecting a client leaves the server and other clients running.

Clients that share **one Aseprite window** share its active document,
selection, layers and undo history, unless each names its own sprite with
`aseprite_sprite` on every call (the `spriteId` from `get_sprite_info`, or the
file name). Aseprite then switches to that sprite before each command, so each
agent's edits and undo stay on its sprite; the visible tab follows whichever
agent ran last. Serialization prevents tool internals from interleaving.

To give agents separate documents, open **one Aseprite window per agent**. Every
window connects to the same bridge on `32145` and identifies itself with an id,
shown under **Instance** in **File > MCP Bridge...** (set
`ASEPRITE_MCP_INSTANCE` before launching it to give it a name). With one window
connected, every session uses it. With several, each session picks its own once
with `select_instance`, by id, name or an open document such as
`dragon.aseprite`; until it does, its calls fail with `INSTANCE_REQUIRED`
rather than guess. The choice is part of the session's memory, alongside its
legends and preview history. A client without MCP sessions names the window on
every call with `aseprite_instance`.

To open a second window, launch the executable directly; on macOS, `open` would
bring the running copy forward instead:

```sh
ASEPRITE_MCP_INSTANCE=dragon /Applications/Aseprite.app/Contents/MacOS/aseprite &
```

Set `ASEPRITE_MCP_ALLOWED_DIRS` in the shared server's environment before starting
it to include your project asset folders. This allowlist is shared by all
clients, not isolated per project. The server runs until you stop it; this mode
does not install a background service or start automatically at login.

### Single session: stdio

```sh
claude mcp add aseprite -- uv run --directory /path/to/AsepriteMCP aseprite-mcp
```

That registers the server at Claude Code's default **local** scope: only
sessions started in this project get it. Prefer that to `-s user`, which starts
a server in every session on the machine, in every project. Only one server can
hold the bridge port, so with user scope a session in an unrelated project can
end up with Aseprite while the one that wants to draw gets
`ASEPRITE_NOT_CONNECTED`. Two sessions in the same project can still collide;
the shared HTTP server above is the fix when you run several at once.

A stdio server does not bind the bridge port at startup. It binds on its first
Aseprite command, which then waits up to 25 seconds for Aseprite to attach, so a
session that never draws never holds the port. After 10 minutes without a
command it lets the port go again (Aseprite's dialog shows *Connecting...*), and
the next command takes it back. If another session holds the port, the error
says so and names the fix: close that session, or disable the server in it with
`/mcp`, then call again.

Order does not matter: the extension retries until the server appears, and
redials on its own when the server restarts.

A server that is killed outright, rather than stopped, can leave the extension
holding a socket that never reports closing. This was seen on Windows with
`taskkill /F`. So the server also sends a heartbeat every 5 seconds, and the
extension redials after 20 seconds without one. After a forced kill, expect up
to about half a minute before the replacement server has Aseprite back. If it
takes longer, press **Reconnect** in the connect dialog below. An extension
older than the heartbeat has no such fallback. Reinstall it if
`get_connection_status` reports it outdated.

## The connect dialog

**File > MCP Bridge...** — an entry in the File menu beside the Scripts
submenu, not inside it. It is non-modal, so Aseprite stays usable while it is
open, and it refreshes about four times a second.

```text
┌─ Aseprite MCP Bridge ──────────────────────┐
│  Status:   ● Connected                     │
│  Server:   [127.0.0.1] : [32145]           │
│            env: 32200 - overridden         │
│  Files:    ● Trusted                       │
│  Token:    off                             │
│  Handled:  214 commands (0 failed)         │
│                                            │
│  [x] Connect automatically                 │
│                                            │
│  [ Disconnect ]  [ Reconnect ]             │
└────────────────────────────────────────────┘
```

- **Status** is `Connected`, `Connecting...` while it is dialling, or
  `Disconnected` when you have switched it off. If it has been dialling for more
  than a few seconds it also says so in words — most often *"No server at
  127.0.0.1:32145 — is the MCP server running?"*, which is the one failure that
  otherwise produces no error anywhere.
- **Server** is editable. Type a host or port and press **Reconnect**; the value
  is remembered across restarts. It has to match what the server is bound to, so
  change `ASEPRITE_MCP_PORT` on the server side too.
- **Files** mirrors the Security grant from section 3. If it reads
  `Not trusted`, previews and saving will fail until you fix it and restart.
- **Token** is read-only; see [About the token](#about-the-token).
- **Connect automatically** governs the *next* launch only. The buttons govern
  now, which is the difference from the old Start/Stop menu entry.

### Which host and port win

```text
what you typed in the dialog  >  ASEPRITE_MCP_HOST / _PORT  >  the built-in default
```

A value typed into the dialog is the more deliberate act, and an environment
variable is invisible to someone launching Aseprite from Steam. Because that
means a stored value can quietly shadow a variable you set, the dialog says when
it is doing so — `env: 32200 - overridden` under the Server row.

Nothing is stored unless it differs from what the environment and the default
would have produced on their own, so pressing Reconnect without changing anything
does not silently pin the current values. To go back to following the
environment, retype the value the variable holds and press Reconnect.

## Configuration

All optional. The defaults work.

| Variable | Default | Meaning |
|---|---|---|
| `ASEPRITE_MCP_ALLOWED_DIRS` | `<repo>/sprites` | Directories the file tools (`open_sprite`, `save_sprite`, `import_spritesheet`, `export_spritesheet`) may touch, `;`-separated. Everything else is refused, including saving over a document you opened by hand from somewhere else. |
| `ASEPRITE_MCP_PORT` | `32145` | Bridge port. Set it for **both** the server and Aseprite if you change it. On the Aseprite side a port typed into the connect dialog outranks this. |
| `ASEPRITE_MCP_HOST` | `127.0.0.1` | Loopback only unless `ASEPRITE_MCP_ALLOW_NON_LOOPBACK=1`. Outranked by the connect dialog, same as the port. |
| `ASEPRITE_MCP_EXTENSION_DIR` | this checkout's `extension/aseprite-mcp` | Server only: the copy of the extension a running Aseprite is checked against. `off` disables the check, which is also off when no copy is found. |
| `ASEPRITE_MCP_INSTANCE` | unset | Aseprite only: a name for this window, shown in the connect dialog and accepted by `select_instance`. |
| `ASEPRITE_MCP_TOKEN` | unset | Opt-in shared secret; set the same value in both environments. |
| `ASEPRITE_MCP_TIMEOUT` | `5` | Seconds to wait for a normal command. |
| `ASEPRITE_MCP_RENDER_TIMEOUT` | `30` | Seconds to wait for a render. |
| `ASEPRITE_MCP_MAX_PIXELS` | `20000` | Cap on one drawing call (`draw_pixels`, `draw_rows`, `draw_rect`). |
| `ASEPRITE_MCP_PREVIEW_MAX_EDGE` | `768` | Longest side, in pixels, of a canvas, layer or onion-skin preview. An image costs the model about width × height / 750 tokens, so this is the price cap on a preview. |
| `ASEPRITE_MCP_SHEET_MAX_EDGE` | `1280` | The same cap for contact sheets. |
| `ASEPRITE_MCP_USAGE_LOG` | unset | Path to a JSONL file. When set, every tool call appends one line with its argument bytes, reply bytes, image sizes and estimated image tokens; see [BENCHMARKS.md](BENCHMARKS.md). |
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

**`EXTENSION_OUTDATED`**
Aseprite is running a different copy of the extension than the server's
`extension/aseprite-mcp`, so its replies may not mean what the tools expect.
The error and `get_connection_status` (`staleFiles`) name the files that
differ. Reinstall the extension (section 2; an install made with `--link` /
`-Link` needs none), then quit Aseprite completely and reopen it: on macOS,
closing the window leaves Aseprite running, so use Cmd+Q. Editing the
extension's Lua in the checkout while Aseprite runs has the same effect until
the restart. To turn the check off, set `ASEPRITE_MCP_EXTENSION_DIR=off` for
the server.

**`INSTANCE_REQUIRED`**
More than one Aseprite window is connected and this session has not chosen one.
`get_connection_status` lists them with what each has open; `select_instance`
picks one by its id, its name or one of its documents. The id and name are
shown in **File > MCP Bridge...** under Instance.

**`ASEPRITE_NOT_CONNECTED`**
Aseprite is not running, the extension is not installed, or the bridge was
switched off. Open **File > MCP Bridge...**: it reports the address it
is dialling, whether anything is listening there, and the last error.

If the message says another process is already listening, Aseprite is attached
to a different copy of this server, usually another MCP session. Close that
session or disable the server in it with `/mcp`, then call again: this one takes
the port on its next command. `get_connection_status` reports
`bridgePortOwnedElsewhere`. Changing the port only helps when you mean to run
two copies of Aseprite, one per port.

**The dialog flickers between Connected and Connecting**
Two copies of Aseprite are dialling the same port with an extension too old to
identify itself. Such connections replace each other, so the two take turns
forever. Update the extension in both (section 2): current versions send an
instance id, and several windows then stay attached side by side. See
[Multiple sessions](#multiple-sessions-one-shared-http-server).

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
