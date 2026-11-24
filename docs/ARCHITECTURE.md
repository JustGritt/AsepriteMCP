# Architecture

How the pieces fit, and — more usefully — the places where the design in
[`ASEPRITE_MCP.md`](ASEPRITE_MCP.md) had to change because Aseprite does not work
the way the spec assumed. Every claim here was verified against Aseprite 1.3.18.3
rather than taken from documentation.

## Shape

The default transport is stdio. `aseprite-mcp --http PORT` instead serves
Streamable HTTP on `127.0.0.1:PORT/mcp`: multiple clients share one process and
one WebSocket bridge. The HTTP application lifespan owns the bridge, so closing
one MCP session does not stop it. Shared mode refuses startup if the bridge port
is occupied, rather than serving tools that cannot reach Aseprite.

Whole tool calls on one Aseprite window are serialized; calls on different
windows run side by side. Nested batch validation reuses the outer lock.
HTTP session IDs key a bounded cache of drawing legends and preview history.
Stateless requests get fresh memory. The active document, undo history and file
allowlist remain shared; this is not isolation between independent projects.

```
MCP client (Claude Code / Codex)
      |  stdio JSON-RPC
      v
Python MCP server  ---- binds ws://127.0.0.1:32145
      ^
      |  the extension dials out and reconnects on its own
      |
Aseprite extension (Lua)
      |  onreceive -> queue        (never touches app.*)
      |  Timer 1/60 -> drain -> app.transaction(...) -> app.refresh()
      v
active .aseprite document
```

`src/aseprite_mcp/` is the server; `extension/aseprite-mcp/` is the Lua side.
Neither trusts the other to have validated anything.

## Several windows, several sessions

`aseprite-mcp --http PORT` (see Shape) lets several MCP clients share one server
and one bridge. On its own, that still gives them one Aseprite window, and so
one active document. Several windows can attach to the same bridge as well:

```
MCP client A ─┐                                      ┌─ Aseprite window a1b2c3
MCP client B ─┼─ HTTP /mcp ── Python server ── ws ───┼─ Aseprite window d4e5f6
MCP client C ─┘   (one process, one bridge, 32145)   └─ ...
```

The design follows unity-mcp's HTTP mode:

- **Windows register.** The hello carries an `instance` id per Aseprite process
  (PROTOCOL.md). The bridge keeps a table of live sockets keyed by it, so a
  window is listed exactly as long as its socket is open, and a window that
  reconnects replaces its own entry and nobody else's. A window that leaves
  fails only the calls waiting on it.
- **Sessions choose.** A call goes to the window named on the call
  (`aseprite_instance`), else the one the session picked with
  `select_instance`, else the only window connected. With several connected and
  no choice, the call fails with `INSTANCE_REQUIRED` and the list of windows.
  It never guesses: a guess is an edit landing in another agent's sprite.
- **The choice is session memory.** `SessionMemory.instance` lives with the
  legends and preview history, set per call through a ContextVar and keyed on
  the transport-validated `mcp-session-id`. Not on a client-supplied id, which
  two clients can share (unity-mcp issue 1023), and not on the SDK's
  per-request session proxy, which is rebuilt for every call.
- **Sessionless clients name the window per call.** On the 2026-07-28 protocol
  each call is a self-contained POST with no session id, so it gets fresh
  memory and nothing chosen carries over. `aseprite_instance` covers that. The
  server strips it before validation, so no tool schema pays for it. Claude
  Code 2.1 speaks this protocol over HTTP: no call carries a session id.
- **Agents sharing a window name their sprite per call** (#34).
  `aseprite_sprite` (a `spriteId` or file name) rides on each request, and the
  extension makes that sprite active before running the command. Undo,
  `app.transaction` and the active layer and frame all follow the active
  sprite in Aseprite, so nothing else needs to know. `sprite.id` rather than a
  stored property: it is stable while Aseprite runs, needs no write to the
  file, and unsaved sprites made by a script all share one file name. It is a
  per-call argument rather than session memory because the sessionless
  protocol keeps none. The window's tab follows whoever ran last.
- **One lock per window** (#33). A call first resolves its window as above,
  then takes that window's lock for the whole call, so two calls never
  interleave inside one Aseprite, while an agent on another window does not wait
  for them. A call that resolves to no window (none attached yet, or several and
  no choice) takes a lock of its own, and window calls wait out any such call
  in flight: one waiting for Aseprite to attach may then use the window.

## The six corrections

### 1. The WebSocket points the other way

The spec (section 2.1) draws `MCP server --WebSocket--> extension`. Aseprite's
`WebSocket` class is a **client only**: it can dial out, it cannot listen. So the
server binds the socket and the extension connects to it. Data flow is unchanged;
only who listens flips.

This turned out to be a gift. The client has `minreconnectwait` /
`maxreconnectwait`, so reconnection is free and the two processes can start in
either order.

Free only when the client notices the drop, though. A force-killed server once
left Aseprite on Windows holding a socket that never reported closing, so the
reconnect never started (#18). The server therefore sends a heartbeat, and
`ws.poll()` rebuilds a socket that has gone quiet. PROTOCOL.md, "Liveness",
has the rules.

### 2. `onreceive` must never touch `app.*`

Socket callbacks run on the UI thread, but they can still land while another
command holds the document lock. Upstream
([aseprite/aseprite#2980](https://github.com/aseprite/aseprite/pull/2980))
reports this as either *"another operation is happening"* or an outright crash.
The same thread notes Aseprite **stops processing socket callbacks when the mouse
leaves the window**, because nothing is waking the message loop.

So `onreceive` does exactly one thing: append the raw string to a Lua table
(`ws.lua`). A `Timer{interval = 1/60}` drains that queue and performs every
`app.*` operation (`queue.lua`). One pattern, both problems solved — edits only
run from a safe point in the message loop, and the timer itself keeps that loop
awake so commands still arrive while Aseprite sits unfocused.

This rule is easy to violate by accident. An early version probed `layer.uuid`
inside the connect callback by creating a throwaway `Sprite` and closing it. In
batch mode that was fine; in the GUI the matching `sprite:close()` can raise a
modal save prompt, which wedged the bridge before it ever finished connecting.
Capabilities are now derived from `app.apiVersion`, with no document work at all.

### 3. `image:resize` cannot do nearest-neighbour

The only documented methods are `bilinear` and `rotsprite`. Both blur pixel art,
which would wreck the visual analysis the whole project exists to support. So
`render.lua` scales by hand.

It builds one scaled row and blits it once per output row, rather than calling
`drawPixel` per output pixel. Measured on a 64x64 sprite at 8x: **24 ms the naive
way, 4 ms this way**, byte-identical output.

### 4. `frame.duration` is in seconds

The spec's `set_frame_duration` takes milliseconds; Aseprite stores a float in
**seconds**. Miss it and every timing value is wrong by 1000x.

The conversion lives in exactly one place, `doc.msFromSeconds` /
`doc.secondsFromMs`, and a Lua test asserts that setting 80 ms stores 0.08 and
reads back as 80.

### 5. `layer.uuid` already answers "stable layer ID"

Section 9 asks for stable layer IDs without saying where one comes from. Aseprite
exposes a read-only `layer.uuid`. That beats both alternatives: no writing custom
properties into the user's file, and no fragile session-indexed map. Names remain
accepted as a fallback and are rejected when ambiguous.

### 6. Script file access is gated, and it fails closed

This one only shows up in the GUI, and it cost the most to find.

Aseprite gates script filesystem access behind a **Security dialog that names the
calling `.lua` file and the specific path it wants**. Two consequences:

- **It fails closed, sometimes silently.** `app.fs.isFile` returns `false` for a
  path that has not been granted — no prompt, no error. The original design had
  the server publish its port to a JSON file for the extension to read; on a
  fresh install that read simply failed, so the bridge could never connect and
  the only symptom was silence. Connecting now needs no file access at all: host
  and port come from the environment with a fixed default.
- **The grant is per script file.** Five modules touching the filesystem would
  mean five separate dialogs. Every filesystem operation therefore goes through
  **`fsio.lua`** and nothing else, so the user answers one dialog and ticks
  "Give full trust to this script" once. See [SETUP.md](SETUP.md).

## Request lifecycle

1. A tool in `src/aseprite_mcp/tools/` validates its arguments — colours, scales,
   batch sizes, and above all paths — and fails locally if they are wrong. A bad
   path never reaches Aseprite.
2. `AsepriteBridge.call()` assigns a monotonic id, stores a future, and sends
   `{"id", "command", "params"}`.
3. `onreceive` enqueues the raw text. The Timer picks it up on the next tick.
4. `queue.lua` looks the command up in a **fixed dispatch table** — an unknown
   command is an error, never something `load()`ed — and runs the handler under
   `pcall` inside `app.transaction("mcp: ...")`.
5. The reply carries the same id. The server resolves the future, or raises
   `BridgeError` on `ok: false`, timeout or disconnect.

Because each command is exactly one transaction, **one `undo` reverses exactly
one tool call**. That is what makes it safe for an agent to experiment.

`batch` keeps the rule. The server runs each op's own tool with a context
variable set (`tools/base.py` `_recording`), so arguments are validated and
encoded exactly as in a direct call, but `ctx.call` records the command instead
of sending it. The recorded commands go to Lua as one `batch.run`, which
dispatches them inside a single `app.transaction`. Aseprite merges nested
transactions into the outer one, so a whole batch is one undo step. An error
inside the transaction rolls every op back, so a batch is all or nothing.
Verified against 1.3.18 in `tests/lua/run_tests.lua`.

`BridgeError` subclasses the SDK's `ToolError` deliberately: the SDK only
forwards a `ToolError`'s message to the model and reports everything else as a
bare "Error executing tool", which would hide the error code and the remedy from
the one reader who needs them.

## Images

Renders travel as **files, not payloads**. Lua composites into an RGB image,
upscales, and writes a PNG to a path the *server* generated in its own temp
directory; the server reads the bytes, returns them as MCP image content, and
unlinks the file.

- The Lua side has no in-memory PNG encoder, so it must write a file regardless.
- The path is never model-supplied, so it cannot be used to write anywhere else.
- Compositing into RGB sidesteps `image:saveAs` demanding an explicit palette for
  indexed sprites — and the spec's own example sprite is indexed.

Previews are drawn over a checkerboard rather than left transparent. The spec
suggests transparency, but a transparent PNG is composited by whatever views it,
which can make a light sprite invisible on white or a dark one invisible on
black. The response text always states that the checkerboard is not artwork.

An image the agent already has is not sent again. Aseprite writes byte-identical
PNGs for identical pixels (a Lua test pins this), so the server compares the
bytes of each render with the images it has sent. Issue #3 proposed a document
revision bumped by `sprite.events` instead. Comparing bytes needs no Lua state,
can't miss a change that fires no event, and counts manual edits and undo
without hooking anything. The cost is that Aseprite still renders the
image, which it did before anyway. See `ToolContext.image_or_note`.

## Safety

- Loopback binding only, unless explicitly overridden.
- Paths are canonicalised with `realpath` (which resolves `..`, symlinks **and
  Windows junctions**) and `normcase`, then matched against the allowlist on path
  *components*, so `sprites-evil` cannot pass as `sprites`. See `paths.py`.
- A save with no path goes through the same check, using the document's own file,
  and Lua refuses if the active tab changed after that check.
- `export_spritesheet` is the only way to write a PNG. It writes a flattened copy
  and leaves the document alone, and it won't replace an existing PNG unless `onto`
  names that same file.
- No `run_lua`, no shell, no arbitrary deletion. Deleting layers, frames and cels
  is fine: it is contained in the document and undoable.
- Batch and region caps stop one call from stalling the editor or flooding the
  agent's context.

## Deliberate omissions

`get_frame_preview` from the spec is absent: it is exactly
`get_canvas_preview(frame=N)`, and section 2.3 asks for reusable primitives over
specialised commands. `get_palette` was added instead, because indexed sprites
are unusable without it.

Edit transactions (`begin_edit` / `commit_edit` / `rollback_edit`, section 16)
are **not implemented**. The obvious approach — count transactions since
`begin_edit`, then call `app.undo()` that many times — silently destroys the
user's manual edits if they touch Aseprite mid-transaction. Doing it safely needs
a `sprite.events:on('change')` watcher to invalidate the checkpoint, and
[aseprite/aseprite#4997](https://github.com/aseprite/aseprite/issues/4997)
reports crashes when calling `undo` inside a `change` handler. Per-call
transactions already give clean single-step undo, which covers most of the need.
