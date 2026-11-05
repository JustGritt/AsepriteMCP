# Tool reference

39 tools. Sizing follows spec section 2.3 (~20–40) and the rule that a tool earns
its place only if it helps the agent understand, modify, inspect or safely
preserve the sprite.

Every tool returns compact JSON as text: no indentation and no `null` fields,
because the model reads every byte and each reply stays in its context. Preview
tools also return a PNG image block. Failures come back as `CODE: message`, e.g.
`INVALID_FRAME: Frame 12 does not exist. This sprite has 6 frame(s), numbered 1-6.`

Conventions:

- **Frames are 1-based**, matching the Aseprite timeline.
- **Durations are milliseconds** everywhere. Aseprite stores seconds; the Lua
  side converts.
- **Layers** are addressed by the 8-character `id` from `get_sprite_info` (a
  prefix of the layer's uuid, stable across renames and reordering while the
  document stays open; reopening the file assigns new ids, so read
  `get_sprite_info` or the `open_sprite` reply again after opening), by any
  unique uuid prefix of at least 6 characters or the full uuid, or by exact name
  (rejected when ambiguous).
- **Colours** are `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, case-insensitive.
- Tools taking `layer` / `frame` default to the active layer and frame.

---

## Connection

### `get_connection_status`
Whether the extension is attached, which document is open, and whether Aseprite
has granted file access. Answers even when nothing is connected — it is the tool
you use to diagnose. Calling it triggers the file-access probe, so the Security
dialog may appear here.

---

## Sprite

### `get_sprite_info`
The whole document in one call. Call it once before editing rather than assuming
the structure:

```json
{"path": "/sprites/knight.aseprite", "width": 32, "height": 32, "colorMode": "rgb",
 "paletteSize": 16, "activeFrame": 1, "activeLayer": "3f2a9c1e",
 "layers": [{"id": "3f2a9c1e", "name": "Arm"},
            {"id": "b71d0a44", "name": "Body", "hidden": true}],
 "frameMs": [100, 100, 80, 100],
 "tags": [{"name": "idle", "from": 1, "to": 4, "direction": "pingpong"}]}
```

- `layers` runs from the top of the stack down. A layer lists `type`, `hidden`,
  `locked`, `opacity`, `background`, `depth` and `parent` only when they differ
  from a plain, visible, opaque, top-level image layer.
- `frameMs[0]` is frame 1.
- A tag lists `direction` and `repeats` only when they are not `forward` and 0.

This replaces separate layer, frame and tag listings. Each listing was one more
model turn that re-read the whole context.

### `new_sprite(width, height, color_mode="rgb", path=None)`
Creates a blank sprite (one layer, one frame) and makes it active. Each side is
limited to 1–1024 pixels (`Config.max_sprite_size`). With `path` it is also saved
there, so a later `save_sprite()` needs no path. That must be a new `.aseprite`
or `.ase` file inside an allowed directory: an existing file is refused rather
than overwritten. Replies with the same overview as `get_sprite_info`.

### `open_sprite(path)`
Opens a file and makes it active. Accepts `.aseprite`, `.ase`, `.png`. Relative
paths resolve against the first allowed directory. Outside the sandbox →
`PATH_NOT_ALLOWED`. Replies with the same overview as `get_sprite_info`, so no
read has to follow.

### `save_sprite(path=None)`
Saves over the document's own file, or to `path`. Either way the target must be a
`.aseprite` / `.ase` file inside an allowed directory, so a layered source can
never be flattened to PNG by accident. The active document can be anything the
user opened by hand, so its own file gets the same check as a path the agent
names: a document from a `.png` or from outside the sandbox is refused until a
`path` gives it a new home. A sprite that was never saved needs a `path` too.

---

## Layers

### `select_layer(layer)` · `create_layer(name)` · `delete_layer(layer)`
`create_layer` adds a normal image layer above the active one, selects it and
returns its `id`.
`delete_layer` refuses to remove the last top-level layer.

### `set_layer_visibility(layer, visible)`
For isolating a component before a preview. Restore it afterwards.

---

## Frames

### `select_frame(frame)`

### `create_frame(after=None)`
Inserts an **empty** frame after `after`, or appends when omitted.

### `duplicate_frame(frame)`
Copies a frame and its cels on every layer, inserting at `frame + 1`. This is the
main way to build an animation: duplicate the previous pose, then change the copy.
Returns the new index — do not assume it.

### `delete_frame(frame)`
Refuses to delete the only frame.

### `set_frame_duration(frame, duration_ms)`
Milliseconds. Values outside 1–65535 are rejected, which catches the classic
mistake of passing seconds. Timing is part of the animation — do not assume every
frame should be equal.

---

## Drawing

All drawing targets one cel and is one undo step. Pixels outside the current cel
bounds **grow the cel** rather than being silently clipped; pixels outside the
canvas are dropped and reported in `skippedOffCanvas`. Replies include
`changed: [x, y, width, height]`, the box this call wrote, which you can pass
straight to `get_canvas_preview(region=...)`.

The model writes tool arguments as output tokens, the most expensive kind, so
choose the encoding by density. A 32×32 sprite with 540 opaque pixels takes
18 136 bytes as `draw_pixels` and 1 209 as `draw_rows`.

### `draw_rows(x, y, rows, legend=None, blank="skip", layer=None, frame=None)`
Pixels as a character map: the same format `get_region` returns, so you can read a
region, edit the map and write it back. Row 0 lands at `y`, column 0 at `x`.

```json
{"x": 8, "y": 4, "rows": ["..oo..", ".obbo.", ".obbo.", "..oo.."],
 "legend": {"o": "#222034", "b": "#5B6EE1"}}
```

- `legend` maps a character to a hex colour, or to a palette index on an indexed
  sprite. Omit it to reuse the previous `draw_rows` legend. That legend lives in
  server memory only, so it is lost on restart, and the reply says
  `"legend": "reused"`.
- `.` is transparent. `blank="skip"` (default) leaves those pixels untouched, for
  overlays. `blank="erase"` clears them in the same undo step, for an exact
  replacement.
- ` ` (space) is always skipped, matching `get_region`'s off-canvas marker.
- The reply carries a `warning` when characters fall outside the canvas
  (`skippedOffCanvas`), or when rows differ in length with `blank="erase"`. That
  is almost always a miscounted row, which otherwise only shows up as a shape one
  column off in the next preview.

### `draw_rect(x, y, width, height, color, filled=True, layer=None, frame=None)`
A filled rectangle, or a 1px outline with `filled=false`.

### `draw_pixels(pixels, color=None, layer=None, frame=None)`
`pixels` is a list of `{x, y}` with an optional per-pixel `color` or `index`;
anything without one falls back to the batch-level `color`.

```json
{"pixels": [{"x": 24, "y": 18}, {"x": 25, "y": 18}], "color": "#E6A15C"}
```

Best for a few scattered pixels. For anything denser use `draw_rows`; for a solid
run use `draw_line`; for a region use `draw_rect` or `fill`. The cap on any one
drawing call is 20 000 pixels by default (`TOO_MANY_PIXELS`).

On an indexed sprite, an off-palette colour is snapped to the nearest entry and
reported in `paletteNotes`, so drifting off-palette is visible rather than silent.
Use `index` for an exact match.

### `erase_pixels(pixels, layer=None, frame=None)`
Never grows the cel: erasing outside it is a no-op by definition, and says so.

### `clear_cel(layer=None, frame=None)`

### `fill(x, y, color, tolerance=0, layer=None, frame=None)`
4-connected flood fill. `tolerance` 0–255 compares RGBA components.

### `draw_line(x1, y1, x2, y2, color, layer=None, frame=None)`
1px Bresenham line. Much cheaper than enumerating the same pixels.

---

## Cels

Most animation frames are an earlier pose moved, mirrored or copied, and most
palette fixes swap one colour for another. These tools do each in one short call
instead of a redraw. Each one is one undo step.

### `shift_cel(dx=0, dy=0, layer=None, frame=None)`
Moves a cel's pixels; positive is right and down. The background layer cannot
move.

### `flip_cel(direction="horizontal", layer=None, frame=None)`
Mirrors a cel within the canvas, so a sprite facing right faces left in the same
place.

### `copy_cel(from_frame, to_frame, from_layer=None, to_layer=None)`
Copies pixels, position and opacity, replacing whatever was at the destination.
`to_layer` defaults to `from_layer`, which defaults to the active layer.

### `replace_color(from_color, to_color, tolerance=0, layer=None, frames=None, region=None)`
Swaps one colour for another on a layer. `frames` is a list of frame numbers or
`"all"`, defaulting to the active frame. `region=[x, y, width, height]` limits the
swap. The reply counts the pixels and frames changed and gives their `changed`
box, so a deterministic recolor needs no preview to trust.

---

## Inspection

Spec section 2.2 makes visual verification mandatory: a command returning `ok` is
not evidence that the result looks right.

Previews are scaled **nearest-neighbour** so pixel edges stay hard, and drawn over
a checkerboard so a light or dark sprite is never invisible. The response text
says so; the checkerboard is not artwork.

An image costs the model about width × height / 750 tokens, up to ~4 800 on
current models, and it stays in context for the rest of the session. So every
render is capped at `ASEPRITE_MCP_PREVIEW_MAX_EDGE` (768 px) on its long edge,
or `ASEPRITE_MCP_SHEET_MAX_EDGE` (1280 px) for contact sheets. The scale stays a
whole number, so a capped render is smaller rather than blurred. Small sprites
keep the default 8×; a 128×128 sprite drops to 6×. To see detail, zoom with
`region` instead of raising `scale`.

No image is sent twice. When a render (a preview, contact sheet, onion skin or
`batch` preview) is byte-identical to the latest image already sent for that
view, the reply is text instead:

```
Unchanged since this view's last image, so it was not sent again. If you no longer have it, call again.
frame 2, 32x32 source, scaled 8x nearest-neighbour
```

If it matches another view, for example a duplicated frame, the note names it:
`Identical to the last image of frame 1, ...`. Any change to the pixels counts,
including one made by hand in Aseprite. Asking again right after such a reply
sends the image, for an agent whose copy was compacted away.

### `get_canvas_preview(scale=8, frame=None, layer=None, region=None)`
The composited sprite as a PNG. Defaults to the active frame. Call after every
substantial edit and actually look at it.

- `layer` renders that layer alone, without touching layer visibility.
- `region=[x, y, width, height]` renders only that part of the canvas, clamped to
  it. A drawing call's `changed` box is a ready-made region.

There is no separate `get_frame_preview` or `get_layer_preview`; this is both,
with `frame` and `layer`.

### `get_region(x, y, width, height, frame=None, layer=None)`
Exact pixels as a character map plus a legend: far more compact than one object
per pixel, and readable positionally. `draw_rows` writes the same format back.

```json
{"frame": 1, "source": "composite", "rows": ["..aa..", ".aaaa."],
 "legend": {"a": "#e6a15cff"}, "distinctColors": 1}
```

`.` is transparent and a space is outside the canvas; neither is repeated in the
legend. Capped at 4096 pixels.

### `get_palette`
Every palette entry as a positional list, so `colors[i]` is palette index `i`.
Alpha appears only when it is not `ff`:

```json
{"colorMode": "indexed", "transparentIndex": 0, "colors": ["#000000", "#222034", "#5b6ee180"]}
```

Read it before drawing so you reuse existing colours instead of introducing
near-duplicates.

---

## Animation

### `get_animation_info(tag=None)`
Frame range, direction, repeats and per-frame durations for a tag, or the whole
sprite.

### `compare_frames(a, b, layer=None, diff_map=False)`
What differs between two frames, as text: pixels that `appeared`, `vanished` or
were `recolored`, the `changed` box, and each frame's opaque bounds. With
`diff_map`, a map of the changed box (`+` appeared, `-` vanished, `*` recolored,
`.` same) as long as it fits the `get_region` cap. Use it to check a targeted edit
touched nothing else, or that a loop's last frame matches its first, for a few
dozen tokens instead of an onion skin.

### `get_animation_bounds(tag=None, layer=None)`
The opaque bounding box of every frame plus their union. Positional drift, a
character slowly sliding across an idle loop, shows up as numbers.

### `get_animation_contact_sheet(scale=4, tag=None, columns=None)`
Every frame in one near-square grid, each cell labelled with its frame number,
plus per-cell durations and tags as text. The default `columns` keeps the sheet
close to square, because a long strip would be shrunk and blurred to fit the
model's image limit. This is how a whole animation is judged:
silhouette readability, volume consistency, motion arcs, spacing, pixel jitter.

### `get_onion_skin_preview(frame=None, scale=8)`
Previous, current and next frame superimposed — previous tinted red and faint,
current fully opaque, next tinted blue and faint. For motion arcs, spacing and
unintended jitter.

### `create_animation_tag` · `update_animation_tag` · `delete_animation_tag`
`create_animation_tag(name, from_frame, to_frame, direction="forward", repeats=0)`;
direction is `forward`, `reverse`, `pingpong` or `pingpong_reverse`, and
`repeats=0` loops indefinitely. `update_animation_tag` changes only the fields
you pass.

---

## Batch

### `batch(ops, preview=False)`
Runs several editing tools in one call, as one undo step:

```json
{"ops": [
  {"tool": "duplicate_frame", "args": {"frame": 1}},
  {"tool": "shift_cel", "args": {"dy": -1, "frame": 2}},
  {"tool": "draw_rows", "args": {"x": 12, "y": 9, "rows": ["oo"], "frame": 2}}],
 "preview": true}
```

Every tool call is a model turn that re-reads the whole context, so building a
frame used to cost one turn per step; a batch is one turn.

- Ops run in order, so a later op can target the frame an earlier op created.
  `duplicate_frame(n)` always lands at `n + 1`.
- Each op is validated by its own tool before anything is sent. A bad op names
  its index (`ops[1] (draw_rows): ...`) and nothing reaches Aseprite.
- **All or nothing.** If an op fails inside Aseprite, every op is rolled back,
  and the error names the op that failed.
- `preview=true` appends a canvas preview of the last frame an op reported.
- Batchable tools: the drawing, cel and frame tools, `select_layer`,
  `create_layer`, `set_layer_visibility` and the tag tools. Previews, file
  access, `undo`/`redo` and `delete_layer` must be called directly.

---

## History

### `undo` · `redo`
Native document history. Because every mutating command is exactly one
`app.transaction`, **one `undo` reverses exactly one tool call**, and a whole
`batch` counts as one call. Aseprite does
not report whether anything was actually on the stack, so preview afterwards to
confirm.

---

## Suggested workflow

```
get_sprite_info, get_palette                        (once, before editing)
        |
        v
batch([duplicate_frame, shift_cel / flip_cel / copy_cel, draw_rows], preview=true)
        |                                           (one call per step)
        v
judge -> correct: get_region / compare_frames for exact facts,
                  get_canvas_preview(region=changed) for detail
        |
        v
get_animation_bounds + get_animation_contact_sheet  (once per animation pass;
        |                                            onion skin only for a
        v                                            specific motion question)
save_sprite
```

The server sends the same guidance as its `INSTRUCTIONS`. Every call re-reads
the whole conversation and every image stays in it, so fewer, denser calls and
text checks before images are what keep a session cheap.

## Not implemented

`get_used_palette`, `get_history_info`, and the `begin_edit` /
`commit_edit` / `rollback_edit` transaction tools — all spec section 19 and 16
material, deferred to a later phase. See the end of
[ARCHITECTURE.md](ARCHITECTURE.md) for why edit transactions in particular are
not simply a matter of counting undos.
