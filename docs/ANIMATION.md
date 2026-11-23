# Animation: from reference to rigged sprite

How this server turns a character design into editable, animated pixel art,
what is built, and what comes next.

| Part | Status |
| --- | --- |
| Rigging: part layers, rest frame, poses, outline (section 3) | **Implemented**: `split_layer`, `define_rig`, `pose_frame`, `refresh_rig`, `get_region(by_layer=true)` |
| Pose templates: one body's animations reused by another (section 3) | **Implemented**: `export_poses`, `import_poses` (#32) |
| Motion presets beyond templates, landmarks (section 4) | Next |
| Reference-to-sprite pipeline (section 2) | Proposed |
| Directions (section 5) | Later: the art in use today is side-view only |

## Goal

Convert a high-resolution master reference (typically 1024x1024) into editable
32x32 or 64x64 pixel art with consistent animation states (idle, hurt, attack,
walk/run), and later optional 4- or 8-direction support, without depending on
one model.

**Key decision:** build an animation compiler, not a larger pile of drawing
tools. The model decides what should move and how it should feel; the server
keeps identity, geometry, timing, palette and editable Aseprite output
consistent.

### Principles

- **Art direction by the model, consistency by the tooling.** The model picks
  features, poses, motion and corrections. Deterministic operations handle
  geometry, palette, anchors, compositing and export.
- **One canonical character.** Proportions, colors, features and equipment are
  defined once and reused by every state and view.
- **Never redraw every frame.** Transform a stable base pose and redraw only
  what a transform cannot express.
- **Keep edits reversible.** Layers, cels, durations, tags, undo.
- **Scale effort to the game.** A side-view game should never pay for eight
  directions.

## 1. Why: what went wrong on a real project

The server was first used on a side-view game: soldiers 18 px tall on a 32x32
canvas, plus a 64x64 dragon. Stills went well. Animation did not, and how it
went wrong shaped the rig.

**The agent left the MCP to animate.** For every animated unit it wrote a
throwaway script that held the character as separate pieces (head, torso,
legs), placed each with a `(dx, dy)` per frame, kept a small library of named
leg drawings (`plant`, `passing`, `push`, `reach`), recomputed the outline
after putting the pieces together, and pushed the result back with
`draw_rows`. One 18 px soldier took about 1,800 lines of such code, and the
next unit started over. The dragon's "head" was a hard-coded rectangle,
`x >= 39 and y < 38`.

So the agent found the right answer, a rig, but built it outside Aseprite,
once per character, with coordinates as its only idea of a body part. The file
received baked pixels: nobody could adjust the rig in Aseprite, and changing
the base drawing meant regenerating everything from the script.

**The suggested workflow made it worse.** "duplicate_frame, then shift and
redraw what changed" builds frame N from frame N-1. Errors accumulate, and at
every step the model has to re-read a drawing it has already changed.

**At 18-24 px a body part is a handful of pixels.** In a flat image the model
cannot reliably tell the near arm from the torso. It needs the structure handed
to it, not inferred from colors.

## 2. Reference to sprite (proposed)

```text
1024x1024 master reference (optionally several views)
  -> foreground and part segmentation, visual analysis
  -> canonical character: palette and ramps, silhouette and part masks,
     proportions and anchors, feature priorities per resolution
  -> 32x32 / 64x64 base sprite, drawn on part layers
  -> preview, validation, targeted repairs
  -> editable .aseprite source
```

- **Resolution-aware features.** At 32x32 keep the silhouette, dominant color
  blocks, the head and signature accessories; omit or exaggerate the rest. At
  64x64 keep more material and accessory detail. A priority per feature
  (`essential`, `medium`, `omit`) guides the reduction.
- **Palette.** Extract material colors, not thousands of reference colors.
  Build deliberate highlight, midtone and shadow ramps, and reserve colors for
  outlines and focal features. The budget (e.g. 8-16 colors) is configurable.
- **Silhouette first.** Build and inspect a one-color silhouette before color
  and detail: bounds, stray components, holes, proportions. Readability still
  needs a vision model or a person.
- **Deterministic baseline.** Optionally segment, resize, quantize and clean
  the reference into a first candidate, never treated as finished art.

What feeds the rig from here:

- **`trace_reference`**: load a PNG, scale it to the canvas, snap it to the
  sprite's palette and return `draw_rows` text. The model edits a grid instead
  of estimating pixel positions from an image, which is the step it is worst
  at.
- **Part segmentation** (SAM, human-parsing nodes in ComfyUI), downsampled by
  majority vote rather than averaging, gives a first label grid for
  `split_layer`.
- **Pose keypoints** (DWPose, OpenPose) scaled down give joint positions.
  Chibi proportions confuse pose estimators, and at 18 px placing six pivots by
  hand is quick, so this is optional.

**Not planned at 18-24 px: generated animation frames.** They flicker between
frames, downscaling smears 1 px motion, and each frame needs the same cleanup.
At 64 px a generated key pose used as a faint underlay for a large pose change
(a wind-up, a fall) is worth trying, with the in-betweens coming from the rig.

## 3. The rig (implemented)

A rig is three things, all stored in the `.aseprite` file.

1. **Part layers.** One top-level image layer per body part, e.g. `leg_far`,
   `torso`, `leg_near`, `head`, `hat`. Each part is drawn complete, including
   the pixels another part covers, so moving one never leaves a hole. "Which
   pixels are the arm" becomes a layer name.
2. **A rest frame.** The frame whose cels are the reference drawing of every
   part.
3. **A pose per frame.** Each part on a posed frame is a copy of a source cel
   (by default its own rest cel) moved by `(dx, dy)`, optionally recolored, or
   hidden. The recipe is saved on the cel in Aseprite 1.3 user properties, so
   it survives sessions and the rest drawing can change later.

Frames are poses of the rest frame, never edits of the previous one. That
removes drift, and makes overlap ("the head lags the body by a frame") data.

### Drawings, not rotation

At this size rotating a part destroys it: a turned torso becomes vertical
stripes, and a 1 px limb breaks apart. Pixel animators swap drawings instead,
and so does the rig. A new drawing (a passing leg, a raised arm) is drawn by
hand on the frame that first needs it, usually over the part hidden there, and
any other frame uses it as a source: `pose_frame(7, {"leg_near": {"frame": 4,
"dy": -1}})`. A part can also take another part's drawing, recolored, which is
how near and far legs trade places in a walk.

### Followers

`define_rig(follows={"hat": "head", "hair": "head"})` makes the hat ride the
head. A follower's own offset is relative to its leader, so posing the head
brings the hat, and `{"hat": [0, -1]}` still lifts the hat off it.

### Outline

Styles with a 1 px outline around the outer silhouette and none inside the
figure cannot keep the outline in the parts: a leg crossing the torso would
draw a line across it. With `outline={"color": ...}` the parts are drawn
without one, and the rig redraws an `outline` layer around the union of the
silhouette parts on every pose. `parts` limits the silhouette (leave out a hat
that carries its own outline), and `floor` stops the outline below a row so
the feet stay on the ground line. A hand-drawn outline identical to the
generated one, as a split of clean art usually gives, is adopted.

### Hand edits are never overwritten silently

Each cel the rig writes records a hash of its pixels. A cel that no longer
matches was edited by hand: it is kept and reported. Listing the part in
`pose_frame`, or `refresh_rig(force=true)`, is the explicit way to replace
it. Two cases are not edits: an unrecorded plain copy of the rest cel (what
`duplicate_frame` leaves) is treated as the rest pose, and a drawing made over
a hidden part is a new source drawing.

### Frame numbers

Recipes name their source frame by number. The server's `create_frame`,
`duplicate_frame` and `delete_frame` renumber every recipe and the rest frame.
Frames inserted or deleted by hand in Aseprite do not: run `define_rig` again
to point at the rest frame, and re-pose frames whose sources moved.

### The tools

| Tool | Does |
| --- | --- |
| `split_layer` | Cuts a flat drawing into part layers from a label grid in the `draw_rows` format. Reports labels that fell on transparent pixels, with positions, since that means a row is off by one. |
| `define_rig` | Names the part layers bottom to top, the rest frame, followers and the outline. Creates missing layers and stacks them. |
| `pose_frame` | Builds one frame from the rest frame: per part `[dx, dy]` or `{dx, dy, frame, layer, recolor, hide}`. Unlisted parts keep their pose, or take the rest pose on a fresh frame. Replies with the figure's box and any part that no longer touches the others. |
| `refresh_rig` | Re-applies every saved pose after the rest drawing or a source drawing changed, and redraws outlines. |
| `get_region(by_layer=true)` | The pixel grid labelled by the layer showing at each pixel: the anatomy view. |
| `export_poses` | Saves the rig's tags as a JSON pose template. See Templates below. |
| `import_poses` | Rebuilds a template's tags on another rigged sprite from its own rest drawing. |

The first four are batchable: a whole walk is one batch and one undo step.

### A walk, end to end

```text
split_layer("body", x, y, rows, parts={"o":"outline","f":"leg_far","t":"torso",
                                       "n":"leg_near","h":"head"})
define_rig(["leg_far","torso","leg_near","head","hair","hat"],
           follows={"hair":"head","hat":"head"},
           outline={"color":"#20222c","parts":["leg_far","torso","leg_near","head"],"floor":23})
batch([create_frame x5,
       pose_frame(2, {"torso":[0,1], "head":[0,1]}),                     # idle: drop 1 px
       pose_frame(3, {}),                                                # contact = rest
       pose_frame(4, {"torso":[0,-1], "head":[0,-1],
                      "leg_near":{"hide":true}, "leg_far":{"hide":true}}),
       draw_rows(layer="leg_near", frame=4, ...),                        # the passing legs:
       draw_rows(layer="leg_far", frame=4, ...),                         # the only new drawing
       pose_frame(5, {"leg_near":{"layer":"leg_far","recolor":{shade: olive}},
                      "leg_far":{"layer":"leg_near","recolor":{olive: shade}}}),
       pose_frame(6, {"torso":[0,-1], "head":[0,-1],
                      "leg_near":{"frame":4}, "leg_far":{"frame":4}})], preview=true)
get_animation_contact_sheet(tag="walk")
```

Run on a copy of the game's hand-made 18 px soldier, this reproduced its
4-frame walk pixel for pixel, with the generated outline identical to the hand
one. Its idle differed by 7 pixels where the original bends the knees, which is
a new leg drawing to make, not something the rig should guess. A test edit to
the rest torso then reached all six frames with one `refresh_rig`.

### Templates

Characters that share a body share their motion. A soldier and a medic of the
same body differ in torso, hat and colors, not in how their legs walk, so the
second should not be animated again pose by pose.

`export_poses` saves a rigged sprite's tags as a JSON template: the frame
layout and timing, each frame's pose per part (offset, source frame, source
part, recolor, hidden), and the pixels of the parts drawn by hand, such as a
passing leg or a body lying down. `import_poses` rebuilds those tags on another
rigged sprite with the same part names, from that sprite's own rest drawing:

- **Poses are replayed, not pixels.** A part the two bodies share moves the
  same way; a part that differs (the medic's coat) keeps its own drawing and
  moves exactly as the template's did.
- **Hand drawings are copied only where they fit.** Each part's rest drawing is
  fingerprinted. A part whose rest drawing matches gets the template's hand
  drawings; one that differs is left hidden on those frames and listed to draw.
  `drawings="copy"` or `"skip"` overrides the guess.
- **Followers are recomputed.** Offsets are stored where each part ended up and
  made relative to the importing rig's leaders, so the two rigs need not agree
  on which part follows which.
- **The layout carries over.** On a fresh sprite the template's rest frame lands
  on the sprite's own, so the frame numbers and tags come out as in the source.

On a copy of the game's 18 px soldier, a 2 KB template carried its idle and
4-frame walk to a variant with a different torso: the legs were identical on
every frame, including the two hand-drawn passing legs, copied automatically,
and the torso moved exactly as the original's did, with nothing left to draw.

Not covered yet: retargeting between bodies of different proportions, and
parametrised presets (stride length, bob height).

### With a game importer

Part layers are flat, top-level layers, so an importer that draws every
visible layer of a unit, bottom first, shows the rig unchanged. An importer
that expects one `body` layer needs a merge step at export, or the rig kept in
a source file that renders into the game file. Layer groups were avoided on
purpose: importers differ in how they treat them.

## 4. Motion (next)

| State | Method | Notes |
| --- | --- | --- |
| Idle | Mostly poses | Breathing, 1 px bobs, blinks, accessory lag; seamless loop |
| Hurt | Mostly poses | Recoil, stagger, recovery; the flash is usually the engine's |
| Attack | Hybrid | Anticipation, strike, impact, recovery; redraw limbs and weapon arcs |
| Walk/run | Hybrid | Alternating contacts, planted feet, weight shift; no naive interpolation |

- **Key poses and timing.** Animation is motion data, not unrelated images: key
  poses (anticipation, strike, impact, recovery), selective in-betweens,
  uneven durations, holds and deliberate snaps. Whole-pixel moves and cleanup
  beat smooth rotation or scaling at small sizes.
- **Presets.** Templates (section 3) are the first preset system: a library of
  them named by state (`idle/breathing`, `hurt/light_hit`, `attack/melee_slash`,
  `movement/walk`), written against part names, not pixel coordinates. Next:
  parameters such as stride length and bob height, and retargeting between
  bodies of different proportions.
- **Landmarks.** Feet contacts, head, hands and weapon tracked per frame from
  the part layers, so a planted foot that slides is reported rather than
  spotted.
- **Rotation**, with RotSprite, only for large parts at 64 px such as wings or
  weapons.

## 5. Directions (later)

| Mode | Views | Typical use |
| --- | --- | --- |
| Single | One view | Side-view characters, enemies, icons |
| Four | N, E, S, W | Simple top-down characters |
| Eight | N, NE, E, SE, S, SW, W, NW | Detailed directional characters |

Generating a direction is a different job from animating one. Establish a base
pose per view first (front, side and back references help: one side view
cannot reveal unseen sides), then apply shared motion per view. Mirror only
where handedness and asymmetric equipment allow; never assume rotating a flat
sprite reveals hidden geometry. Keep a common ground anchor and the same
semantic attachment points across views, and check for jumps when switching
view or state. Eight directions are one character, not eight designs.

## 6. Checks

Render after meaningful stages, not after every pixel operation.

| Check | How today |
| --- | --- |
| Palette, alpha, bounds | `get_region` legends, `get_animation_bounds` |
| Stray pixels and gaps | `pose_frame`'s `detached` |
| Size and silhouette stability, anchor drift | `get_animation_bounds`, `pose_frame`'s `box` |
| Ground contact | `get_animation_bounds`, the outline's `floor` |
| Changes outside the animated area | `compare_frames` |
| Loop continuity | `compare_frames` on the first and last frame |
| Part and equipment consistency | the rig itself: parts are copies, followers follow |

Readability, appeal and likeness need a vision model or a person; flag
doubtful frames for a local repair.

## 7. Proposed capabilities

| Capability | Purpose | Today |
| --- | --- | --- |
| `analyze_reference` | Features, color families, proportions, masks | |
| `extract_palette` | Constrained palette with ramps | |
| `generate_base_sprite` | Silhouette-first sprite at a size and view | |
| `create_rig_from_sprite` | Suggest parts and pivots for correction | `split_layer` + `define_rig`, with the labels from the model |
| `generate_directional_set` | Base poses per view | |
| `animate_character` | Apply a preset, direction and timing to a rig | `pose_frame`, by hand |
| `preview_animation` | Native and enlarged playback | `get_animation_contact_sheet` |
| `get_onion_skin` | Compare adjacent frames | `get_onion_skin_preview` |
| `get_frame_diff` | Changed pixels and drift | `compare_frames` |
| `track_landmarks` | Feet, head, hands, weapon, center of mass | |
| `validate_animation` | Palette, bounds, anchors, loops | partly: see Checks |
| `repair_frame` | Local fix without rebuilding | `pose_frame` on one part, `draw_rows` |
| `export_aseprite` | Source, tags, sheet, metadata | `save_sprite` |

Keep the `.aseprite` file as the editable artwork; the rig and its poses live
in it. JSON character specs, palettes and presets are inputs for regeneration,
and per-view files exist only for the views a character needs.

## 8. Roadmap

1. **Baseline and preview.** Done: previews, contact sheets, frame diff,
   bounds.
2. **Rigging MVP.** Done: layered parts first, flat sprites through
   `split_layer` with correction.
3. **Idle and hurt.** Pose templates per body: done (#32). Loop checks next.
4. **Attack key poses.** Anticipation, impact, recovery, and selective redraw
   for complex silhouettes.
5. **Walk and run.** Foot contacts and landmark checks.
6. **Reference pipeline.** `trace_reference`, segmentation into labels.
7. **Directions.** Opposite side, then front and back, then diagonals, with
   shared anchors; then shared motion across views.
8. **Model benchmarking.** The same assets, constraints and budgets across
   models.

### Benchmark suite

A 32x32 soldier and a 64x64 creature with idle, hurt, attack and walk (and
directional variants once they exist). Track time, tool calls, invalid
operations, cost, anchor drift, palette violations, consistency and human
cleanup time against an approved reference, repeatably.
