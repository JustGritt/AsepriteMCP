# Aseprite MCP — Project Specification

## 1. Project Goal

Build a small, auditable MCP server that allows an AI coding agent such as Codex to control a live Aseprite session and iteratively create or edit pixel-art animations.

The primary workflow is:

```text
Agent
  ↓
Inspect current sprite
  ↓
Edit active .aseprite document
  ↓
Render visual preview
  ↓
Analyze result
  ↓
Correct mistakes
  ↓
Repeat until acceptable
```

The system is intentionally focused on this loop.

It is **not** intended to reproduce every Aseprite feature or become a general-purpose Aseprite automation framework.

---

# 2. Core Principles

## 2.1 Live editor first

All edits should affect the currently running Aseprite instance whenever possible.

Preferred architecture:

```text
Codex / MCP Client
        │
        │ MCP stdio
        ▼
Aseprite MCP Server
        │
        │ localhost WebSocket
        ▼
Aseprite Extension
        │
        │ Lua / Aseprite API
        ▼
Active .aseprite Document
```

The user should be able to watch changes happen inside Aseprite.

Avoid workflows that repeatedly launch Aseprite in headless mode and modify the file externally.

---

## 2.2 Visual verification is mandatory

Agents must never assume that an edit is correct because the underlying command succeeded.

Every meaningful visual edit should follow this pattern:

```text
EDIT
  ↓
PREVIEW
  ↓
ANALYZE
  ↓
CORRECT if needed
```

For animation work:

```text
EDIT FRAME
  ↓
FRAME PREVIEW
  ↓
CONTACT SHEET / ONION SKIN
  ↓
ANALYZE MOTION
  ↓
CORRECT
```

---

## 2.3 Small MCP surface

Do not expose the complete Aseprite API directly.

Prefer a small collection of predictable MCP tools.

Target:

```text
~20–40 tools
```

Avoid adding tools unless they materially improve the agent workflow.

Prefer reusable primitives over highly specialized commands.

---

## 2.4 Safe by default

The MCP server must not give the agent unrestricted access to the host machine.

Avoid:

```text
arbitrary shell execution
arbitrary filesystem access
arbitrary Lua execution
unrestricted absolute paths
filesystem deletion
```

Expose explicit whitelisted operations instead.

---

# 3. Scope

## Required capabilities

The MVP must support:

- connecting to the currently running Aseprite instance
- reading information about the active sprite
- opening an `.aseprite` file
- saving the active sprite
- listing layers
- selecting layers
- creating layers
- listing frames
- selecting frames
- creating frames
- duplicating frames
- deleting frames
- editing frame duration
- reading canvas pixels
- drawing pixels
- erasing pixels
- clearing a cel
- rendering the current canvas
- rendering individual frames
- undo
- redo
- animation tags
- animation contact sheets
- visual inspection by the agent

---

# 4. Non-Goals

The initial version does NOT need:

- tilemap editing
- text tools
- advanced brushes
- filters
- effects
- color curves
- complex selections
- scripting arbitrary Lua
- arbitrary CLI execution
- integration with multiple Aseprite processes
- multi-user networking
- cloud communication
- remote WebSocket access

These can be considered later if required.

---

# 5. Repository Structure

Recommended structure:

```text
aseprite-mcp/
├── server/
│   ├── main.py
│   ├── bridge/
│   │   ├── websocket.py
│   │   └── protocol.py
│   │
│   ├── tools/
│   │   ├── sprite.py
│   │   ├── frames.py
│   │   ├── layers.py
│   │   ├── drawing.py
│   │   ├── history.py
│   │   ├── animation.py
│   │   └── inspection.py
│   │
│   └── models/
│       └── protocol.py
│
├── aseprite-extension/
│   ├── package.json
│   ├── main.lua
│   ├── websocket.lua
│   ├── protocol.lua
│   └── commands/
│       ├── sprite.lua
│       ├── frames.lua
│       ├── layers.lua
│       ├── drawing.lua
│       ├── history.lua
│       └── inspection.lua
│
├── tests/
│
├── docs/
│   ├── PROTOCOL.md
│   ├── TOOLS.md
│   └── ARCHITECTURE.md
│
└── README.md
```

This structure is only a recommendation.

Agents may adjust it when there is a strong technical reason.

---

# 6. Communication Architecture

The MCP server communicates with the Aseprite extension through a local WebSocket.

Only localhost connections are allowed.

Example:

```text
127.0.0.1:32145
```

The exact port may be configurable.

The WebSocket server must not bind to:

```text
0.0.0.0
```

unless explicitly enabled by the user.

---

# 7. Command Protocol

Prefer structured messages instead of sending arbitrary Lua scripts.

Example request:

```json
{
  "id": "request-123",
  "command": "frame.duplicate",
  "params": {
    "frame": 3
  }
}
```

Example successful response:

```json
{
  "id": "request-123",
  "ok": true,
  "result": {
    "frame": 4
  }
}
```

Example error:

```json
{
  "id": "request-123",
  "ok": false,
  "error": {
    "code": "INVALID_FRAME",
    "message": "Frame 12 does not exist."
  }
}
```

Every request must have a matching response.

Do not rely on plain-text parsing when structured data can be used instead.

---

# 8. Initial MCP Tool Set

## Sprite

### `get_sprite_info`

Returns information about the current sprite.

Expected information:

```json
{
  "filename": "oddkin_attack.aseprite",
  "width": 64,
  "height": 64,
  "colorMode": "indexed",
  "frameCount": 6,
  "layerCount": 4,
  "activeFrame": 3,
  "activeLayer": "Character"
}
```

---

### `open_sprite`

Open an `.aseprite` file.

Input:

```json
{
  "path": "Assets/Sprites/Tamer/attack.aseprite"
}
```

Paths must remain within configured allowed directories.

---

### `save_sprite`

Save the active document.

Do not allow arbitrary filesystem destinations by default.

---

# 9. Layer Tools

## `list_layers`

Return:

- layer ID
- name
- type
- visibility
- opacity
- active state

---

## `select_layer`

Select a layer using a stable layer ID whenever possible.

Avoid relying solely on layer names.

---

## `create_layer`

Create a normal image layer.

---

## `delete_layer`

Delete a layer.

This operation should be undoable.

---

## `set_layer_visibility`

Show or hide a layer.

Useful during visual inspection.

---

# 10. Frame Tools

## `list_frames`

Return:

```json
[
  {
    "index": 1,
    "duration": 80
  },
  {
    "index": 2,
    "duration": 80
  }
]
```

---

## `select_frame`

Change the currently active frame.

---

## `create_frame`

Create an empty frame.

---

## `duplicate_frame`

Duplicate an existing frame including relevant cels.

This is one of the most important animation operations.

---

## `delete_frame`

Delete a frame.

Must remain undoable.

---

## `set_frame_duration`

Set frame duration in milliseconds.

Example:

```json
{
  "frame": 4,
  "duration": 60
}
```

---

# 11. Drawing Tools

The initial drawing API should favor operations that minimize excessive MCP round trips.

Avoid forcing the model to make one MCP call per pixel.

---

## `draw_pixels`

Preferred format:

```json
{
  "layer": 3,
  "frame": 4,
  "pixels": [
    {
      "x": 24,
      "y": 18,
      "color": "#E6A15C"
    },
    {
      "x": 25,
      "y": 18,
      "color": "#E6A15C"
    }
  ]
}
```

Large batches should be supported.

---

## `erase_pixels`

Erase multiple pixels in a single call.

---

## `clear_cel`

Clear the current layer/frame cel.

---

## `fill`

Flood-fill a connected region.

---

## `draw_line`

Useful for larger shapes and animation construction.

---

# 12. Image Inspection

This is one of the most important parts of the system.

The model must be able to inspect its work.

---

## `get_canvas_preview`

Render the current composite canvas.

Preferred output:

- PNG
- transparent background when applicable
- nearest-neighbor scaling

Input:

```json
{
  "scale": 8
}
```

A 32×32 sprite may therefore be returned as:

```text
256×256
```

This significantly improves visual inspection.

---

## `get_frame_preview`

Render a specific frame.

---

## `get_layer_preview`

Optional but recommended.

Render only a specific layer.

Useful for debugging individual sprite components.

---

## `get_region`

Return pixel information for a region.

Useful when the agent needs exact pixel/color information rather than visual perception.

---

# 13. Animation Inspection

Animation inspection should receive special attention.

A model cannot reliably judge animation by inspecting isolated frames alone.

---

## `get_animation_contact_sheet`

Generate an image containing every frame in sequence.

Example:

```text
┌──────┬──────┬──────┬──────┬──────┬──────┐
│ F01  │ F02  │ F03  │ F04  │ F05  │ F06  │
│      │      │      │      │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┘

 80ms   80ms   50ms   50ms   80ms   120ms
```

Prefer including:

- frame number
- duration
- animation tag
- consistent scale
- transparent or neutral background

---

## `get_onion_skin_preview`

Render:

```text
previous frame
current frame
next frame
```

using visually distinct opacity levels.

This is useful for evaluating:

- motion arcs
- spacing
- silhouette continuity
- limb movement
- unintended jitter

---

## `get_animation_info`

Return:

```json
{
  "tag": "attack",
  "from": 1,
  "to": 6,
  "direction": "forward",
  "durations": [
    80,
    80,
    50,
    50,
    80,
    120
  ]
}
```

---

# 14. Animation Tags

Support:

```text
create_animation_tag
delete_animation_tag
list_animation_tags
update_animation_tag
```

Example tags:

```text
idle
walk
attack
hit
death
```

---

# 15. History

## `undo`

Must use Aseprite's native document history where possible.

---

## `redo`

Same requirement.

---

## `get_history_info`

Optional.

May expose whether undo/redo is currently available.

---

# 16. Edit Transactions

Transactions are strongly recommended.

They allow the agent to experiment without permanently damaging the sprite.

Desired flow:

```text
begin_edit
   ↓
perform modifications
   ↓
inspect
   ↓
acceptable?
  ↙     ↘
yes     no
 ↓       ↓
commit  rollback
```

Potential tools:

```text
begin_edit
commit_edit
rollback_edit
```

Implementation may rely on Aseprite undo groups or another safe mechanism.

Do not create complicated custom history if Aseprite's native history can provide the same behavior.

---

# 17. Agent Workflow

Agents using this MCP should follow the workflow below.

## Before editing

Always inspect:

```text
get_sprite_info
list_layers
list_frames
list_animation_tags
```

Do not assume the current document structure.

---

## Before modifying an animation

Inspect:

```text
get_animation_info
get_animation_contact_sheet
```

Optionally inspect important individual frames.

---

## During editing

Prefer:

```text
duplicate previous pose
→ make targeted change
→ preview
```

instead of recreating every frame from scratch.

---

## After every substantial edit

Call:

```text
get_frame_preview
```

or:

```text
get_canvas_preview
```

Then visually evaluate the result.

---

## After changing multiple animation frames

Call:

```text
get_animation_contact_sheet
```

and preferably:

```text
get_onion_skin_preview
```

---

# 18. Animation Evaluation Checklist

Agents should evaluate the following properties.

## Silhouette

Is the pose readable at native sprite size?

Avoid shapes that merge important body parts together.

---

## Volume consistency

Body parts should not unexpectedly grow or shrink between frames unless intentionally animated.

Pay particular attention to:

```text
head
torso
hands
feet
weapons
hair
clothing
```

---

## Motion arcs

Movement should generally follow smooth paths.

Example:

```text
bad:

●
   ●
●
      ●


better:

●
  ●
    ●
      ●
```

---

## Spacing

Frames do not need equal physical displacement.

Acceleration may look like:

```text
● ●  ●    ●
```

Deceleration may look like:

```text
●    ●  ● ●
```

---

## Pixel stability

Unrelated regions should not jitter unnecessarily.

Use frame comparison when appropriate.

---

## Palette consistency

Do not introduce near-duplicate colors without reason.

Reuse existing palette colors whenever possible.

---

## Timing

Frame timing is part of the animation.

Do not assume every frame should have identical duration.

---

# 19. Useful Semantic Tools

These are not required for the first MVP but would be highly valuable.

## `compare_frames`

Compare two frames.

Possible result:

```json
{
  "changedPixels": 53,
  "bounds": {
    "x": 17,
    "y": 11,
    "width": 31,
    "height": 42
  }
}
```

Optionally return a visual diff.

---

## `shift_cel`

Translate a cel by:

```text
x
y
```

without manually modifying every pixel.

---

## `copy_cel`

Copy a cel from one frame/layer to another.

---

## `flip_cel`

Horizontal or vertical flip.

---

## `get_used_palette`

Return colors currently used by the animation.

---

## `get_animation_bounds`

Return the bounding box of visible pixels across an animation.

Useful for detecting unwanted positional drift.

---

# 20. Agent Editing Strategy

Agents should make small iterative changes.

Preferred:

```text
modify 10–100 pixels
→ inspect
→ modify again
```

Avoid:

```text
rewrite entire sprite
→ hope it worked
```

unless explicitly asked to redesign the asset.

---

# 21. Security

The MCP must be safe enough to run alongside a real game project.

## Network

The WebSocket bridge should bind only to:

```text
127.0.0.1
```

by default.

---

## Filesystem

Allowed paths should be scoped.

Example:

```text
<ProjectRoot>/Assets/Sprites/**
```

Reject attempts such as:

```text
../../../../Users/...
```

Canonicalize paths before validating them.

---

## Lua

Do NOT expose:

```text
run_lua
execute_lua
eval_lua
```

in the initial version.

If arbitrary Lua is ever added, it should require explicit opt-in.

---

## Shell

Never expose arbitrary shell execution through the MCP.

---

## File deletion

Do not provide arbitrary filesystem deletion.

Deleting Aseprite layers or frames is acceptable because those operations are contained within the document and undoable.

---

# 22. Reliability

MCP operations should be deterministic where possible.

Every command should return either:

```json
{
  "ok": true,
  "result": {}
}
```

or:

```json
{
  "ok": false,
  "error": {}
}
```

Do not silently ignore errors.

---

# 23. Timeouts

WebSocket requests should have explicit timeouts.

Example:

```text
5 seconds
```

Long-running image operations may use longer limits if necessary.

If Aseprite is disconnected, return a clear error such as:

```json
{
  "code": "ASEPRITE_NOT_CONNECTED",
  "message": "No Aseprite extension is currently connected."
}
```

---

# 24. Connection State

The MCP server should expose:

```text
get_connection_status
```

Possible result:

```json
{
  "connected": true,
  "asepriteVersion": "1.3.x",
  "documentOpen": true,
  "document": "oddkin_attack.aseprite"
}
```

---

# 25. Logging

Log:

- connection events
- disconnections
- tool calls
- Aseprite errors
- protocol errors

Avoid logging:

- huge pixel arrays
- binary image contents
- unnecessary project data

Development logging may be more verbose than production logging.

---

# 26. Testing

Tests should prioritize operations that could corrupt or unexpectedly modify assets.

At minimum test:

```text
path sandboxing
frame creation
frame duplication
frame deletion
layer creation
layer deletion
undo
redo
save
invalid frame indices
invalid layer IDs
disconnected Aseprite instance
malformed WebSocket messages
```

---

# 27. Manual Integration Test

A minimum integration test should perform:

```text
1. Start Aseprite
2. Connect extension
3. Start MCP server
4. Create/open test sprite
5. Create layer
6. Draw pixels
7. Duplicate frame
8. Modify duplicate
9. Render contact sheet
10. Undo modification
11. Confirm restoration
12. Save sprite
```

The resulting `.aseprite` document should remain valid and editable.

---

# 28. Development Priorities

Implement in this order.

## Phase 1 — Connection

```text
MCP server
WebSocket bridge
Aseprite extension
connection status
```

Goal:

```text
Codex can communicate with Aseprite.
```

---

## Phase 2 — Document inspection

Implement:

```text
get_sprite_info
list_layers
list_frames
get_canvas_preview
```

Goal:

```text
Codex can understand what is currently open.
```

---

## Phase 3 — Editing

Implement:

```text
select_layer
select_frame
draw_pixels
erase_pixels
clear_cel
```

Goal:

```text
Codex can visibly modify the active sprite.
```

---

## Phase 4 — Animation

Implement:

```text
create_frame
duplicate_frame
delete_frame
set_frame_duration
animation tags
```

Goal:

```text
Codex can construct animations.
```

---

## Phase 5 — Feedback loop

Implement:

```text
get_frame_preview
get_animation_contact_sheet
get_onion_skin_preview
undo
redo
```

Goal:

```text
Codex can edit → inspect → correct autonomously.
```

This phase represents the first real project milestone.

---

## Phase 6 — Advanced agent tooling

Consider:

```text
compare_frames
shift_cel
copy_cel
animation_bounds
visual diff
transactions
```

---

# 29. Definition of MVP Success

The MVP is successful when the following prompt can be executed reliably:

```text
Open attack.aseprite.

Inspect the sprite and existing palette.

Create a new 6-frame attack animation using the current idle pose as
the starting point.

Keep the character proportions and palette consistent.

After editing each frame, inspect the rendered result.

After all frames are complete, generate a contact sheet and inspect
the animation for inconsistent volume, motion arcs, spacing and pixel
jitter.

Correct any obvious issues you find.

Save the final .aseprite file.
```

The agent should be able to complete this without:

- manually editing files outside Aseprite
- restarting Aseprite
- asking the user to reload the document
- executing arbitrary Lua
- executing shell commands through the MCP

---

# 30. Agent Rules

Agents contributing to this project should follow these rules.

### Do

- keep the MCP API small
- favor live Aseprite interaction
- favor structured commands
- reuse Aseprite's native API
- preserve native undo history
- verify visual changes
- add tests for destructive operations
- keep security boundaries explicit
- prefer batch pixel operations
- keep protocol responses machine-readable

### Do not

- expose arbitrary shell commands
- expose arbitrary Lua without explicit discussion
- add dozens of redundant MCP tools
- bypass path restrictions
- manipulate `.aseprite` binary files directly
- silently overwrite unrelated project files
- treat successful API execution as visual success
- make large architectural changes without updating this document

---

# 31. Reference Projects

The following projects may be used as architectural references:

```text
giangdvdotdev/aseprite-mcp
ZhangDongyang800/Aseprite_MCP
MalloyTheDev/aseprite-mcp
```

Relevant ideas worth studying:

### giangdvdotdev

- minimal MCP tool surface
- live Aseprite bridge
- native document interaction
- preview scaling
- native undo/redo

### ZhangDongyang800

- live WebSocket architecture
- animation-oriented inspection
- canvas previews
- onion-skin workflows
- richer animation primitives

### MalloyTheDev

- structured tool design
- defensive validation
- workspace path sandboxing
- testing
- high-level asset operations

Do not copy architectural complexity unless the project actually needs it.

---

# 32. Architectural Decision Guideline

When deciding whether to add a feature, ask:

```text
Does this help the agent:

1. understand the sprite,
2. modify the sprite,
3. inspect the result,
4. understand animation,
5. correct mistakes,
6. or safely preserve the asset?
```

If the answer is no, the feature is probably outside the scope of this MCP.

---

# 33. Long-Term Vision

The long-term goal is not simply:

```text
AI can use Aseprite
```

The desired result is:

```text
AI can behave like an iterative pixel-art animation assistant
inside Aseprite.
```

A mature version should be able to:

```text
inspect existing artwork
↓
understand sprite structure
↓
create or modify poses
↓
construct animation frames
↓
inspect temporal consistency
↓
identify visual problems
↓
correct them
↓
repeat
↓
deliver an editable .aseprite asset
```

The quality of this feedback loop is more important than the number of MCP tools exposed.