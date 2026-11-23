# Tool reference

49 tools. Sizing follows spec section 2.3 (~20–40) and the rule that a tool earns
its place only if it helps the agent understand, modify, inspect or safely
preserve the sprite. The sheet tools take it one past that range, because nothing
else gets a game's sprite sheet in as frames or back out as a PNG.

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
- **Windows.** Every call goes to one Aseprite window: the session's choice from
  `select_instance`, or the only one connected. Any call also accepts
  `aseprite_instance` (an id, name or id prefix) to name the window for that
  call alone, for clients that keep no MCP session. It is in no schema: the
  server strips it before validation.

---

## Connection

### `get_connection_status`
Whether the extension is attached, which document is open, and whether Aseprite
has granted file access. Answers even when nothing is connected — it is the tool
you use to diagnose. Calling it triggers the file-access probe, so the Security
dialog may appear here.

`extensionUpToDate` says whether that window runs the same extension as the
server's copy; when it is `false`, `staleFiles` names the files that differ (or
`extensionPredatesCheck` says the extension is older than the check), every
other tool fails with `EXTENSION_OUTDATED`, and `hint` says how to fix it.
`extensionCheck` explains a window whose extension could not be checked.

`instance` is the window this session's calls go to. With several windows
connected, `instances` lists each with its `id`, `name`, active `document`,
open `documents` and `selected` flag; until the session chooses, the reply
carries the `INSTANCE_REQUIRED` error instead of a document.

### `select_instance(instance)`
Chooses the Aseprite window this session drives, by its id, its name
(`ASEPRITE_MCP_INSTANCE`), a unique id prefix, or the file name of a document it
has open. The choice lasts for the session, as its legends and preview history
do, and survives the window reconnecting. Ambiguous matches are refused with the
candidates listed. See SETUP.md, "Multiple sessions".

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

If the file is already open, this switches to its tab rather than opening a second
one, and the reply adds `"alreadyOpen": true`, plus `"unsaved": true` if the tab has
edits. The tab wins over the file on disk, because it may hold the user's work.
This is also how to get back to a tab, if its file is in an allowed directory.

A PNG always opens as one frame, even with numbered neighbours like `sheet2.png`.

### `save_sprite(path=None)`
Saves over the document's own file, or to `path`. Either way the target must be a
`.aseprite` / `.ase` file inside an allowed directory, so a layered source can
never be flattened to PNG by accident. The active document can be anything the
user opened by hand, so its own file gets the same check as a path the agent
names: a document from a `.png` or from outside the sandbox is refused until a
`path` gives it a new home. A sprite that was never saved needs a `path` too.

### `import_spritesheet(path, frame_width, frame_height, x=0, y=0, columns=None, rows=None)`
Slices a `.png` inside an allowed directory into a new RGB sprite, one frame per
cell, left to right then top to bottom. The PNG is not changed, and it doesn't
matter whether it is also open in a tab: the file on disk is what gets read.

- **Positions never shift.** A cell with nothing in it stays as an empty frame and
  is listed in `sheet.emptyFrames`. Frames count from 1, so frame N is cell N-1 in
  a game that counts from 0.
- **`x`, `y`, `columns` and `rows` pick one area.** Without `columns` or `rows` it
  runs to the sheet's edge, and the reply has a `warning` if that left pixels
  over, which usually means the frame size is wrong or the sheet is not one grid.
- **The new sprite has no file,** so its first save needs a `path`, and that can't
  be the PNG. It is one undo step. An indexed PNG becomes RGB. The limit is 1024
  frames.

Replies with the same overview as `get_sprite_info`, plus
`"sheet": {"columns": 4, "rows": 11, "emptyFrames": [39, 43]}`.

### `export_spritesheet(path, columns=None, onto=None, x=0, y=0, tag=None)`
Writes the visible layers of every frame, or of one `tag`, as a grid to a `.png`
inside an allowed directory. A hidden layer stays out, so a reference layer can
live in the project. The sprite, its layers and its own file do not change.

- **Without `onto`** it makes a new sheet, one row unless `columns` is set. `path`
  must not exist yet. Each side is limited to 8192 pixels.
- **With `onto`,** an existing PNG, it starts from a copy of that sheet and replaces
  the cells at `x`, `y`. Pixels are replaced rather than blended, so erasing works
  and partial alpha lands exactly. Everything outside the frames written keeps what
  it had, including cells past the last frame. The block must fit inside the sheet.
- **`changedPixels`** in the reply counts what `onto` changed. A round trip with no
  edits reports 0.
- **Replacing an existing PNG takes `onto` with the same path.** A PNG has no layers
  to go back to, so this is never done by accident.

A sheet with mixed frame sizes takes one import and one export per area, each
pasted onto the result of the last:

```python
import_spritesheet("hero.png", 16, 32, columns=4, rows=4)          # walk rows
# ...edit, save_sprite("hero_walk.aseprite")...
export_spritesheet("hero_new.png", columns=4, onto="hero.png")

import_spritesheet("hero.png", 32, 48, y=192, columns=2, rows=3)   # tall frames
# ...edit, save_sprite("hero_tall.aseprite")...
export_spritesheet("hero_new.png", columns=2, onto="hero_new.png", y=192)
```

### `import_image(path, width=None, height=None, layer="Reference", frame=None, palette=None, transparent=None)`
Puts an image file (PNG, JPEG, BMP, GIF, TGA or WebP, inside an allowed
directory) on a layer of the active sprite, as one undo step: a master design or
a photo to work from. The layer is created at the bottom of the stack if it does
not exist, and importing again replaces its cel on that frame.

- **Size and place.** By default the image is scaled to fit the canvas keeping
  its aspect ratio, and centered; `width` or `height` sets the size, and one
  alone sets the other by the aspect ratio. `shift_cel` moves it afterwards.
- **Scaling.** Shrinking averages every source pixel a target pixel covers
  (`method: "area average"`), since Aseprite's own resize samples a few pixels
  and aliases badly from 1024 to 32. Growing repeats pixels (`"nearest"`).
- **`transparent`** removes a flat background before scaling: a hex color, or
  `"corner"` for the top-left pixel's color, matched within a small tolerance.
  Image generators usually output one; left in, it fills the canvas.
- **`palette`** snaps every pixel to the nearest of the given hex colors, or of
  the sprite's palette with `"sprite"`, and makes alpha all or nothing. Then
  `get_region(layer="Reference")` reads it as a grid to trace or copy into
  `draw_rows`. Without it the guide keeps its averaged colors, often thousands.

The file is read by Aseprite (through `fsio.lua`, so no new Security prompt once
the extension is trusted) from a private copy, never from a tab that may hold
it. The reply gives the `box` it landed in, the `method`, `distinctColors`, and
`keyedOut` / `snappedTo` when used. Hide the layer with `set_layer_visibility`
before judging the art on its own.

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
  (`skippedOffCanvas`), or when rows differ in length and the block should be
  solid: with `blank="erase"`, or with `blank="skip"` when no row uses `.` or a
  space. That is almost always a miscounted row, which otherwise only shows up as
  a shape one column off in the next preview. Rows using `.` or a space may stop
  short on purpose in skip mode, so they stay quiet. A solid shape that really is
  uneven, like a stepped edge, gets the warning anyway and can ignore it.
- Inside a `batch`, these warnings reach the reply's `warnings` with the op's index.

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

`by_layer=true` labels each pixel with the visible layer that shows there
instead of its colour: the anatomy view of a rigged character, where the model
cannot tell the arm from the torso by colour. Letters go to the bottom of the
stack first, and names sharing an initial use their last word (`leg_far` f,
`leg_near` n). It takes no `layer`.

```json
{"frame": 1, "source": "layers", "rows": [".HH.", ".hh.", "tttt", "f.n."],
 "legend": {"H": "hat", "h": "head", "t": "torso", "f": "leg_far", "n": "leg_near"}}
```

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

## Rig

A rig animates a character as part layers posed from a rest frame, instead of
editing the previous frame. [ANIMATION.md](ANIMATION.md#3-the-rig-implemented)
has the design and a worked walk. The first four are batchable; the pose
template tools read and write files and are called directly.

### `split_layer(layer, x, y, rows, parts, frame=None)`
Moves pixels out of a flat drawing into part layers. `rows` is a label grid in
the `draw_rows` format and `parts` maps each character to a layer name
(created directly above the source, in the order given, when missing). `.`
leaves a pixel where it is. The reply counts the pixels `moved` per layer, the
opaque pixels `left` on the source, and any `labelledTransparent` labels with
their first positions in `labelledTransparentAt`: a label on a transparent pixel
almost always means a row is off by one.

### `define_rig(parts, rest_frame=1, follows=None, outline=None)`
`parts` are top-level image layers, bottom to top; missing ones are created and
all are stacked together in that order. `follows={"hat": "head"}` makes a part
move with its leader. `outline={"color", "parts", "floor"}` keeps an `outline`
layer, under the parts, redrawn on every pose around the union of `parts`
(default all) and never below row `floor`. Saved in the file, and reported by
`get_sprite_info` as `rig`.

### `pose_frame(frame, parts=None)`
Builds one frame from the rest frame. `parts` maps a part to `[dx, dy]` or to
`{dx, dy, frame, layer, recolor, hide}`: the drawing comes from `frame`
(default the rest frame) on `layer` (default the part itself), moved, with
`recolor={from: to}` exact swaps, or hidden. A follower's offset is relative to
its leader.

- Unlisted parts keep their pose. On a fresh frame, or a plain copy of the rest
  frame, they take the rest pose.
- A cel edited by hand since the rig wrote it is kept and listed in `kept`.
  Drawing over a hidden part is how a new drawing is made: later poses can use
  it as their source.
- The reply has the parts `posed`, the outline pixel count (or `"kept"`), the
  figure's `box`, and `detached`: parts that no longer touch any other part.

### `refresh_rig(frames=None, force=False)`
Rebuilds every posed cel from its saved recipe, sources first, then the
outlines. Use it after changing the rest drawing or a drawing other frames
reuse, and after drawing a part by hand: the outline follows a new silhouette
on the next pose or refresh of that frame. Hand-edited cels are kept and
listed unless `force`.

### `export_poses(path, tags=None)`
Saves the rigged sprite's tags (default all) as a `.json` pose template in an
allowed directory: the frame layout, durations, tag ranges and directions, each
frame's pose per part, and the pixels of parts drawn by hand, plus a fingerprint
of each part's rest drawing. It replaces an earlier template at the same path,
never another file. A pose that takes its drawing from a frame outside the
chosen tags is refused: export that tag too. The reply is a summary
(`frames`, `tags`, `drawn`), not the template.

### `import_poses(path, tags=None, drawings="auto")`
Rebuilds a template's tags (default all) on the active rigged sprite, as one
undo step. Frames are appended in template order; when the template's rest
frame starts a tag and this sprite's rest frame is its last, untagged frame,
it is reused, so a fresh sprite ends up laid out like the template. Every frame
is posed from this sprite's own rest drawing, with follower offsets recomputed
for this rig, and the outline redrawn.

Parts drawn by hand in the template are copied only onto parts whose rest
drawing matches the template's (`auto`: shared legs, not another role's torso),
always (`copy`) or never (`skip`). Parts not copied are left hidden, and listed
in `toDraw` as `part@frame`: draw over them, then `refresh_rig` so the frames
that reuse them follow. The reply also lists the new `frames` and `tags`,
`copied` drawings, template parts this rig lacks (`ignoredParts`) and rig parts
the template lacks, which stay at rest (`restPoseParts`). A tag name the sprite
already has is refused.

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
- **The reply is a summary, not one entry per op.** Most of a per-op reply repeats
  what was just sent, and it stays in context for the rest of the session, so its
  size doesn't grow with the op count unless something notable happened:

  ```json
  {"applied": 94, "undoSteps": 1, "changed": [0, 57, 91, 71], "written": 528,
   "filled": 3463, "created": [{"id": "fffb0d4f", "name": "Cliff"}]}
  ```

  - `changed` is the union of every draw, fill and recolor box, across layers and
    frames. It makes a ready-made preview region, but erases and cel moves report
    no box, so it doesn't cover those.
  - `written`, `filled`, `erased`, `replaced` and `skippedOffCanvas` are totals,
    left out when zero. Comparing `written` with the expected count catches a
    miscounted row.
  - `created` lists new layers and `newFrames` lists new frame numbers, both in op
    order. A frame number is the one it got when created, so a later op that inserts
    or deletes a frame can shift it. `frameCount` is the count after the last op
    that changed it.
  - `warnings` is `[{"ops": [12, 15], "warning": "..."}]`: each message once, with
    the index of every op that raised it. It also carries notes saying an op did
    nothing, like `No pixel matched that color.`
  - `paletteNotes` lists each palette note once, at most five.
- `preview=true` appends a canvas preview of the last frame an op reported.
- Batchable tools: the drawing, cel, frame and rig tools, `select_layer`,
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

For a character, the middle step is a rig rather than duplicated frames:

```
split_layer (flat art) or draw_rows per part layer, then define_rig    (once)
        |
        v
batch([create_frame, pose_frame ..., draw_rows on a hidden part], preview=true)
        |                                           (a new drawing only where
        v                                            a move cannot express it)
get_region(by_layer=true) for structure; refresh_rig after a rest change
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
