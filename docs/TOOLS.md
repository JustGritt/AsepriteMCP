# Tool reference

33 tools. Sizing follows spec section 2.3 (~20–40) and the rule that a tool earns
its place only if it helps the agent understand, modify, inspect or safely
preserve the sprite.

Every tool returns JSON as text. Preview tools additionally return a PNG image
block. Failures come back as `CODE: message`, e.g.
`INVALID_FRAME: Frame 12 does not exist. This sprite has 6 frame(s), numbered 1-6.`

Conventions:

- **Frames are 1-based**, matching the Aseprite timeline.
- **Durations are milliseconds** everywhere. Aseprite stores seconds; the Lua
  side converts.
- **Layers** are addressed by the `uuid` from `list_layers` (stable across
  renames and reordering) or by exact name (rejected when ambiguous).
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
Size, colour mode, frame/layer/tag counts, palette size, active frame and layer.
Call before editing rather than assuming the document structure.

### `open_sprite(path)`
Opens a file and makes it active. Accepts `.aseprite`, `.ase`, `.png`. Relative
paths resolve against the first allowed directory. Outside the sandbox →
`PATH_NOT_ALLOWED`.

### `save_sprite(path=None)`
Saves over the source file, or to `path`. Only `.aseprite` / `.ase` may be
written, so a layered source can never be flattened to PNG by accident.

---

## Layers

### `list_layers`
Every layer with `uuid`, `name`, `type` (`image`/`group`/`tilemap`), `visible`,
`opacity`, `depth`, `parent`, and which one is active.

### `select_layer(layer)` · `create_layer(name)` · `delete_layer(layer)`
`create_layer` adds a normal image layer above the active one and selects it.
`delete_layer` refuses to remove the last top-level layer.

### `set_layer_visibility(layer, visible)`
For isolating a component before a preview. Restore it afterwards.

---

## Frames

### `list_frames`
Index, `durationMs` and covering tags for every frame.

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
canvas are dropped and reported in `skippedOffCanvas`.

### `draw_pixels(pixels, color=None, layer=None, frame=None)`
`pixels` is a list of `{x, y}` with an optional per-pixel `color` or `index`;
anything without one falls back to the batch-level `color`.

```json
{"pixels": [{"x": 24, "y": 18}, {"x": 25, "y": 18}], "color": "#E6A15C"}
```

Send as many pixels as the edit needs in one call — the spec is explicit that the
agent must never be forced into one call per pixel. The cap is 20 000 by default
(`TOO_MANY_PIXELS`). For a solid run prefer `draw_line`; for a region prefer
`fill`.

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

## Inspection

Spec section 2.2 makes visual verification mandatory: a command returning `ok` is
not evidence that the result looks right.

Previews are scaled **nearest-neighbour** so pixel edges stay hard, and drawn over
a checkerboard so a light or dark sprite is never invisible. The response text
says so; the checkerboard is not artwork.

### `get_canvas_preview(scale=8, frame=None)`
The composited sprite as a PNG. Defaults to the active frame. Call after every
substantial edit and actually look at it.

There is no separate `get_frame_preview`; this is it, with `frame`.

### `get_layer_preview(layer, scale=8, frame=None)`
One layer alone, without touching layer visibility.

### `get_region(x, y, width, height, frame=None, layer=None)`
Exact pixels as a character map plus a legend — far more compact than one object
per pixel, and readable positionally:

```json
{
  "rows": ["..aa..", ".aaaa."],
  "legend": {".": "#00000000", "a": "#e6a15cff"},
  "distinctColors": 1
}
```

`.` is transparent, a space is outside the canvas. Capped at 4096 pixels.

### `get_palette`
Index and hex for every palette entry. Read it before drawing so you reuse
existing colours instead of introducing near-duplicates.

---

## Animation

### `get_animation_info(tag=None)`
Frame range, direction, repeats and per-frame durations for a tag, or the whole
sprite.

### `get_animation_contact_sheet(scale=4, tag=None, columns=None)`
Every frame side by side in one image, each cell labelled with its frame number,
plus per-cell durations and tags as text. This is how a whole animation is judged:
silhouette readability, volume consistency, motion arcs, spacing, pixel jitter.

### `get_onion_skin_preview(frame=None, scale=8)`
Previous, current and next frame superimposed — previous tinted red and faint,
current fully opaque, next tinted blue and faint. For motion arcs, spacing and
unintended jitter.

### `list_animation_tags` · `create_animation_tag` · `update_animation_tag` · `delete_animation_tag`
`create_animation_tag(name, from_frame, to_frame, direction="forward", repeats=0)`;
direction is `forward`, `reverse`, `pingpong` or `pingpong_reverse`, and
`repeats=0` loops indefinitely. `update_animation_tag` changes only the fields
you pass.

---

## History

### `undo` · `redo`
Native document history. Because every mutating command is exactly one
`app.transaction`, **one `undo` reverses exactly one tool call**. Aseprite does
not report whether anything was actually on the stack, so preview afterwards to
confirm.

---

## Suggested workflow

```
get_sprite_info -> list_layers -> list_frames -> get_palette   (before editing)
        |
        v
duplicate_frame -> draw_pixels -> get_canvas_preview -> judge -> correct
        |
        v
get_animation_contact_sheet + get_onion_skin_preview           (after several frames)
        |
        v
save_sprite
```

## Not implemented

`compare_frames`, `shift_cel`, `copy_cel`, `flip_cel`, `get_used_palette`,
`get_animation_bounds`, `get_history_info`, and the `begin_edit` /
`commit_edit` / `rollback_edit` transaction tools — all spec section 19 and 16
material, deferred to a later phase. See the end of
[ARCHITECTURE.md](ARCHITECTURE.md) for why edit transactions in particular are
not simply a matter of counting undos.
