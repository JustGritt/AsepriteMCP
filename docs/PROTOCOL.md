# Wire protocol

Between `src/aseprite_mcp/bridge/` (Python) and `extension/aseprite-mcp/` (Lua).
One JSON object per WebSocket **text** message. Binary frames are not used.

The server binds `ws://127.0.0.1:32145`; the extension dials out. See
[ARCHITECTURE.md](ARCHITECTURE.md#1-the-websocket-points-the-other-way) for why
round that way.

## Handshake

The extension speaks first. A connection that sends anything else, or nothing
within 10 seconds, is closed.

```json
{
  "type": "hello",
  "token": "",
  "protocolVersion": 1,
  "asepriteVersion": "1.3.18.3",
  "apiVersion": 41,
  "capabilities": ["layer.uuid"]
}
```

`capabilities` lets the server degrade gracefully on older 1.3.x builds rather
than erroring. It is derived from `app.apiVersion`, never by poking at a
document — see the note on callback safety in ARCHITECTURE.md.

The server answers:

```json
{"type": "welcome", "ok": true, "protocolVersion": 1}
```

or, when `require_token` is on and the token does not match:

```json
{"type": "welcome", "ok": false,
 "error": {"code": "UNAUTHORIZED", "message": "Bad or missing token."}}
```

Only one extension may be attached. A second connection wins and the previous one
is closed, which is what you want when Aseprite restarts and the stale socket has
not timed out yet.

## Requests and responses

```json
{"id": 42, "command": "frame.duplicate", "params": {"frame": 3}}
```

```json
{"id": 42, "ok": true, "result": {"frame": 4, "copiedFrom": 3, "frameCount": 7}}
```

```json
{"id": 42, "ok": false,
 "error": {"code": "INVALID_FRAME", "message": "Frame 12 does not exist. This sprite has 6 frame(s), numbered 1-6."}}
```

Rules:

- `id` is a positive integer assigned by the server, monotonically increasing.
- **Every request gets exactly one response**, carrying the same `id`.
- Responses arriving for an unknown or expired `id` are logged and dropped; that
  is almost always a reply that arrived after its call timed out.
- Requests have a timeout (5 s by default, 30 s for renders). On expiry the
  server raises `TIMEOUT` and forgets the request.
- A message without a numeric `id` is a notification, not a reply. `{"type":
  "log", "message": "..."}` is logged by the server; anything else is ignored.

## Error codes

Shared between `ErrorCode` in `bridge/protocol.py` and `M.ERROR` in
`protocol.lua`. A test asserts the two do not drift apart.

| Code | Raised by | Meaning |
|---|---|---|
| `ASEPRITE_NOT_CONNECTED` | server | No extension attached, or it dropped mid-request. |
| `TIMEOUT` | server | No answer in time. Often a modal dialog waiting for a click. |
| `UNAUTHORIZED` | server | Token mismatch during the handshake. |
| `PATH_NOT_ALLOWED` | server | Path outside the sandbox, or a disallowed extension. |
| `NO_ACTIVE_SPRITE` | Lua | No document is open. |
| `INVALID_FRAME` | Lua | Frame number out of range or not a whole number. |
| `INVALID_LAYER` | Lua | No such layer, an ambiguous name, or a group/tilemap where pixels were needed. |
| `INVALID_PARAMS` | both | Structurally bad arguments. |
| `DOCUMENT_LOCKED` | Lua | Aseprite was busy with another operation. Retry. |
| `UNSUPPORTED_COLOR_MODE` | Lua | e.g. a palette index given for an RGB sprite. |
| `TOO_MANY_PIXELS` | both | Batch or region over the configured cap. |
| `UNKNOWN_COMMAND` | Lua | Not in the dispatch table. |
| `PROTOCOL_ERROR` | both | Undecodable or malformed message. |
| `LUA_ERROR` | Lua | Anything unanticipated; carries the Lua message. |

`DOCUMENT_LOCKED` is not raised directly. `queue.lua` recognises the lock-failure
text coming out of `app.transaction` and reclassifies it from `LUA_ERROR`, so the
agent gets "retry this" rather than an opaque string.

## Commands

35 commands back 35 MCP tools. The mapping is not 1:1: `fs.probe` has no tool of
its own and is called by `get_connection_status`; `draw_rows` and `draw_rect` are
decoded on the server into `draw.pixels`; and `get_canvas_preview` sends
`render.layer` when it is given a `layer`.

| Command | Tool |
|---|---|
| `app.status`, `fs.probe` | `get_connection_status` |
| `sprite.info`, `sprite.open`, `sprite.save` | sprite tools |
| `layer.select`, `layer.create`, `layer.delete`, `layer.setVisibility` | layer tools |
| `frame.select`, `frame.create`, `frame.duplicate`, `frame.delete`, `frame.setDuration` | frame tools |
| `draw.pixels`, `draw.erase`, `draw.clearCel`, `draw.fill`, `draw.line` | drawing tools |
| `cel.shift`, `cel.flip`, `cel.copy`, `cel.replaceColor` | cel tools |
| `render.canvas`, `render.layer`, `inspect.region`, `inspect.palette` | inspection tools |
| `anim.info`, `render.contactSheet`, `render.onionSkin` | animation inspection |
| `tag.create`, `tag.update`, `tag.delete` | tag tools |
| `history.undo`, `history.redo` | `undo`, `redo` |

The dispatch table is fixed at load. An unrecognised `command` is an
`UNKNOWN_COMMAND` error and is never `load()`ed or evaluated.

## Renders

Render commands take an extra `outPath` that the **server** generates inside its
own temp directory:

```json
{"id": 7, "command": "render.canvas",
 "params": {"scale": 8, "frame": 2, "maxEdge": 768,
            "region": {"x": 4, "y": 4, "width": 16, "height": 16},
            "outPath": "C:\\...\\Temp\\aseprite-mcp-ab12\\9f3e.png"}}
```

`maxEdge` caps the longest side of the output image. Lua uses the largest whole
scale at or below `scale` that fits, and reports `scaleReduced` when it had to go
lower. The server sends the cap with every render (`ASEPRITE_MCP_PREVIEW_MAX_EDGE`,
or `ASEPRITE_MCP_SHEET_MAX_EDGE` for contact sheets), because image size is the
main cost of a preview. `region` is optional and is clamped to the canvas.

Lua writes the PNG there and replies with metadata only; the server reads the
bytes, returns them as MCP image content, and deletes the file. `outPath` is
never model-supplied, so it cannot be aimed anywhere else.

If the reply says `ok` but no file appeared, the server raises `LUA_ERROR`
pointing at the file-access grant in [SETUP.md](SETUP.md) — the usual cause.

## Drawing points

`draw.pixels` points are `{x, y, color}` or `{x, y, index}`, or `{x, y, erase: true}`.
An erase point writes transparent in the same transaction as the painted points,
which is how `draw_rows(blank="erase")` stays one undo step. Erase points outside
the existing cel are dropped, so they never grow it. Drawing replies carry
`changed: [x, y, width, height]`, the box of pixels that call wrote, ready to pass
as a preview `region`.

## Empty arrays

Aseprite's `json.encode` cannot distinguish an empty array from an empty object,
so an empty list of tags would decode as `{}` on the Python side. `protocol.lua`
encodes a placeholder and rewrites it to `[]` before sending. Use
`proto.array(t)` when returning any list.
