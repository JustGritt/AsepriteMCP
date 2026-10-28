# AsepriteMCP — Token Optimization Guide

**Status:** Architecture proposal  
**Project:** AsepriteMCP  
**Goal:** Enable AI agents to generate and edit pixel-art assets using fewer tokens, fewer tool calls, and more predictable operations.

## 1. Overview

AsepriteMCP connects AI agents to Aseprite through the Model Context Protocol (MCP).

The goal is to make it possible to create sprites, animations, tilesets, UI elements, and other pixel-art assets using natural language.

A key challenge is token consumption.

When an AI agent performs many small drawing operations, it generates significant overhead through tool arguments, responses, repeated reasoning, and image inspection.

AsepriteMCP should minimize that overhead by providing high-level drawing operations, compact feedback, persistent state, and efficient preview mechanisms.

**Core design principle:**

> The AI defines the artistic intent. AsepriteMCP executes the drawing operations.

## 2. Optimization objectives

The project should aim to:

- Reduce the number of tool calls required to create an asset.
- Minimize the size of tool requests and responses.
- Avoid retransmitting unchanged sprite information.
- Support batch and declarative drawing operations.
- Allow local execution of repetitive drawing logic.
- Provide compact previews and incremental visual feedback.
- Preserve editable Aseprite layers and frames.
- Measure actual token usage instead of relying on estimates.

Optimization should preserve output quality, editability, and reliability.

## 3. Recommended architecture

```text
User / AI Agent
      |
      v
MCP Tool Interface
      |
      v
Asset Command Planner
      |
      v
Command Validator
      |
      v
Drawing Execution Engine
      |
      +---- Geometry & primitives
      +---- Palette operations
      +---- Reusable asset templates
      +---- Layer & frame operations
      +---- Batch execution
      |
      v
Aseprite Integration
      |
      +---- Aseprite Lua scripting
      +---- Aseprite CLI
      +---- Existing integration backend
      |
      v
Sprite State & Preview Cache
```

The exact integration layer depends on the existing implementation.

### Responsibilities

**AI agent**

- Interprets the requested asset.
- Chooses appropriate drawing tools.
- Supplies design specifications.
- Evaluates previews when needed.
- Requests targeted corrections.

**MCP server**

- Validates commands.
- Converts high-level instructions into drawing operations.
- Executes batches.
- Maintains document identifiers and revisions.
- Reports concise operation results.
- Manages preview generation and caching.

**Aseprite**

- Stores the editable source artwork.
- Manages layers, frames, cels, and palettes.
- Produces exported images and animations.

## 4. Tool design

Tools should correspond to useful drawing workflows rather than individual interface actions.

The following names and payloads are proposed APIs.

### 4.1 `create_asset`

Create an asset from a structured specification using a server-supported template or generator.

```json
{
  "name": "iron_sword",
  "type": "sword",
  "canvas": [32, 32],
  "palette": "steel",
  "options": {
    "outline": true,
    "shading": "simple"
  }
}
```

Expected compact result:

```json
{
  "ok": true,
  "asset_id": "asset_001",
  "revision": 1
}
```

The server must implement the requested asset type. The model should not assume that arbitrary natural-language asset descriptions are automatically supported.

### 4.2 `draw_batch`

Execute multiple operations in a single MCP call.

```json
{
  "asset_id": "asset_001",
  "operations": [
    {
      "op": "rect",
      "x": 4,
      "y": 4,
      "w": 24,
      "h": 24,
      "color": "#222034"
    },
    {
      "op": "line",
      "from": [8, 20],
      "to": [20, 8],
      "color": "#FFFFFF"
    },
    {
      "op": "fill",
      "x": 10,
      "y": 10,
      "color": "#AAAAAA"
    }
  ]
}
```

Benefits:

- One tool call instead of many.
- Consistent operation ordering.
- Reduced intermediate feedback.
- Easier rollback and error reporting.

Support atomic execution when the backend allows it. If an operation fails, report its index and whether previous operations were committed.

### 4.3 `apply_asset_patch`

Modify an existing asset without resending the complete specification.

```json
{
  "asset_id": "asset_001",
  "base_revision": 1,
  "operations": [
    {
      "op": "replace_color",
      "from": "#AAAAAA",
      "to": "#C0C0C0",
      "region": [8, 8, 16, 16]
    }
  ]
}
```

Return the updated revision and affected bounding box.

Use revision checks to prevent patches from being applied to stale asset state.

### 4.4 `get_asset_info`

Return concise metadata without exporting pixel data.

```json
{
  "asset_id": "asset_001",
  "revision": 2,
  "size": [32, 32],
  "frames": 1,
  "layers": 3,
  "palette_size": 8
}
```

Only return detailed layer, palette, or frame information when explicitly requested.

### 4.5 `get_preview`

Return a visual representation only when inspection is necessary.

Suggested parameters:

- `asset_id`
- `revision`
- `region`
- `frame`
- `scale`
- `format`

Previews may use a file/resource reference rather than embedding image data into a text response, depending on client capabilities.

For incremental editing, request only the changed area when practical.

## 5. Token-efficient response design

Successful drawing operations should return the smallest response that provides useful state and error information.

**Avoid:**

- Full pixel arrays for every successful operation.
- Repeated layer and palette metadata.
- Base64 image content inside ordinary text responses.
- Detailed logs on success.
- Repeated copies of the original tool arguments.

**Prefer:**

```json
{
  "ok": true,
  "revision": 7,
  "changed": [4, 4, 20, 20]
}
```

Full diagnostics should be available through an explicit debug mode.

Errors should still be actionable:

```json
{
  "ok": false,
  "code": "INVALID_LAYER",
  "operation_index": 2,
  "message": "Layer does not exist."
}
```

Do not remove information required for reliable error recovery merely to save tokens.

## 6. Persistent state

Use stable asset identifiers instead of repeatedly transmitting complete documents.

Suggested state:

```json
{
  "asset_id": "asset_001",
  "revision": 7,
  "document": "assets/sword.aseprite",
  "canvas": [32, 32],
  "palette_id": "steel",
  "active_layer": "Blade"
}
```

The server can manage:

- Active documents.
- Layer identifiers.
- Palette references.
- Previously applied commands.
- Asset revisions.
- Cached previews.
- Undo or transaction history.

Persistent state must have a documented lifetime.

If state is only stored in memory, it may disappear after a server restart. File-backed state or explicit restoration should be used when persistence across sessions is required.

## 7. Image inspection policy

Do not request a full preview after every drawing operation.

Recommended workflow:

1. Create the base asset.
2. Execute a batch of drawing operations.
3. Request one preview.
4. Identify necessary corrections.
5. Apply a targeted patch.
6. Request a final preview if necessary.
7. Save or export.

Preview frequency should adapt to operation complexity.

For deterministic edits, such as replacing a known color, preview inspection may not be necessary.

For composition-sensitive operations, such as changing a character's silhouette, visual inspection is usually valuable.

## 8. Tool discovery and schema optimization

Every MCP tool definition adds potential context overhead when exposed to a model.

Recommended practices:

- Keep tool descriptions concise and specific.
- Use clear operation names.
- Avoid redundant tools with overlapping functionality.
- Group related functionality when doing so improves discoverability.
- Use constrained enums for supported operations.
- Avoid excessively nested schemas.
- Provide separate advanced tools only when required.

Where the MCP host supports it, use progressive tool discovery.

For example, an agent creating a static icon may need drawing, palette, and export operations, but not the complete animation toolset.

**Important:** The server cannot guarantee reduced model-context usage through shorter definitions alone. The host or MCP client determines which schemas are transmitted to the model and when.

## 9. Advanced optimizations

### Reusable templates

Provide server-side generators for common assets:

- Weapons and equipment.
- Characters and NPCs.
- Terrain tiles.
- Decorative props.
- UI icons.
- Animation effects.

Templates should accept compact parameters while generating detailed artwork deterministically.

### Relative coordinates

Support drawing operations relative to a specified origin or region.

This enables the reuse of shapes without recalculating every coordinate.

### Palette references

Prefer palette indices or named colors when the palette is stable.

For example:

```json
{
  "palette": {
    "outline": "#222034",
    "metal": "#9BADB7",
    "highlight": "#DFEFD7"
  }
}
```

Subsequent commands can refer to named colors.

### Local procedures

Allow repeated geometric patterns to be executed inside the server rather than generated as individual AI tool calls.

Procedures should be validated, bounded, and limited to supported capabilities.

Arbitrary code execution should not be the default interface.

### Compact pixel representations

For complex handcrafted pixel art, support a structured grid or run-length encoded representation as an optional import format.

This can reduce coordinate repetition, but it does not guarantee fewer tokens for every asset.

Compare encoding formats with real model token counts.

## 10. Agent workflow instructions

The following rules should be included in the AI agent's project instructions.

**AsepriteMCP Agent Rules**

1. Prefer high-level asset generators when available.
2. Use batch operations instead of individual pixel calls.
3. Never fetch complete document state unless required.
4. Reuse asset IDs, palettes, and revisions.
5. Avoid repeated screenshots for deterministic operations.
6. Prefer editing an existing asset over recreating it.
7. Group related changes into a single logical operation.
8. Use the smallest tool response that supports the next decision.
9. Do not assume a tool or generator exists without discovering it.
10. Validate and preview the completed asset before delivery.

The agent should optimize tool calls without compromising asset quality.

## 11. Performance monitoring

Instrument both the server and the MCP client or host where possible.

Track:

| Metric | Purpose |
|---|---|
| MCP calls per asset | Measure interaction overhead |
| Input tokens | Measure model request cost |
| Output tokens | Measure model generation cost |
| Tool-result tokens | Measure response overhead |
| Tool-schema tokens | Measure discovery overhead |
| Preview count | Measure visual feedback frequency |
| Execution time | Measure processing latency |
| Failed operations | Measure reliability |
| Successful assets | Measure completion quality |

Token usage should be collected from actual model/provider usage data where available.

A server-side tokenizer estimate is useful, but it does not necessarily capture the complete model context, including image inputs and host-managed tool schemas.

### Benchmark scenarios

Create a repeatable benchmark set:

- 16×16 simple icon.
- 32×32 weapon sprite.
- 32×32 character sprite.
- 64×64 environment tile.
- Four-frame animated sprite.
- Existing-sprite recolor.
- Targeted layer correction.

Compare baseline and optimized implementations using identical specifications, models, and quality criteria.

## 12. Implementation roadmap

### Phase 1 — Measure and reduce overhead

- [ ] Add per-tool invocation logging.
- [ ] Measure response sizes and token usage.
- [ ] Introduce compact response modes.
- [ ] Remove unnecessary result fields.
- [ ] Identify the most frequently called tools.

### Phase 2 — Batch drawing

- [ ] Implement `draw_batch`.
- [ ] Validate operation parameters.
- [ ] Support error reporting by operation index.
- [ ] Implement rollback or partial-commit semantics.
- [ ] Benchmark calls per asset.

### Phase 3 — Persistent asset state

- [ ] Introduce stable asset IDs.
- [ ] Add revision tracking.
- [ ] Implement incremental patches.
- [ ] Cache unchanged metadata.
- [ ] Support session restoration where needed.

### Phase 4 — Semantic drawing

- [ ] Implement reusable asset templates.
- [ ] Add named palettes.
- [ ] Support relative geometry.
- [ ] Implement common shading patterns.
- [ ] Add parameterized animation generation.

### Phase 5 — Adaptive inspection

- [ ] Support region-based previews.
- [ ] Cache previews by revision.
- [ ] Add optional image-difference reporting.
- [ ] Implement preview-on-demand workflows.
- [ ] Benchmark final quality against baseline.

## 13. Success criteria

The optimization effort should demonstrate:

- Fewer MCP calls for comparable assets.
- Reduced model token usage.
- Smaller routine tool responses.
- Lower unnecessary preview frequency.
- Comparable or improved visual quality.
- Preserved editability and reliable saving.

A target such as 50% fewer tokens may be useful as an initial engineering objective, but it must be validated through repeatable benchmarks.

## 14. Long-term direction

AsepriteMCP should evolve beyond remote control of individual Aseprite actions.

Its long-term goal is to provide a compact, structured pixel-art authoring interface that translates AI-generated specifications into editable sprite assets.

This approach makes the server more useful for game developers, improves consistency, and reduces the need for expensive low-level interactions.

The ideal workflow is:

**Describe → Generate → Inspect → Refine → Export**

Rather than:

**Click → Draw → Inspect → Click → Draw → Repeat**