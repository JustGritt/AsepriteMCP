-- Document helpers shared by every command handler: resolving references,
-- validating them, and the cel-expansion logic that drawing depends on.

local M = {}
local proto = nil

function M.setProtocol(p) proto = p end

-- Aseprite stores frame duration in seconds; the MCP surface is milliseconds.
-- Converting in exactly one place is what keeps that from becoming a 1000x bug.
function M.msFromSeconds(seconds) return math.floor(seconds * 1000 + 0.5) end
function M.secondsFromMs(ms) return ms / 1000.0 end

function M.activeSprite()
  local sprite = app.sprite
  if not sprite then
    proto.fail(
      proto.ERROR.NO_ACTIVE_SPRITE,
      "No sprite is open in Aseprite. Open one with open_sprite, or open a document by hand."
    )
  end
  return sprite
end

function M.colorModeName(mode)
  if mode == ColorMode.RGB then return "rgb" end
  if mode == ColorMode.GRAY then return "grayscale" end
  if mode == ColorMode.INDEXED then return "indexed" end
  if ColorMode.TILEMAP and mode == ColorMode.TILEMAP then return "tilemap" end
  return "unknown"
end

function M.layerId(layer)
  local ok, id = pcall(function() return tostring(layer.uuid) end)
  -- Older 1.3 builds have no layer.uuid; the capability probe in main.lua tells
  -- the server to fall back to names when that happens.
  if ok and id and id ~= "" then return id end
  return nil
end

--- The id get_sprite_info prints: the first 8 characters of the uuid, or the
-- whole uuid in the unlikely case another layer shares that prefix. A full
-- uuid is 36 characters the model has to type back on every layer argument.
function M.shortId(sprite, layer)
  local id = M.layerId(layer)
  if not id then return nil end
  local short = id:sub(1, 8)
  for _, entry in ipairs(M.allLayers(sprite)) do
    local other = M.layerId(entry.layer)
    if entry.layer ~= layer and other and other:sub(1, 8) == short then return id end
  end
  return short
end

local DIRECTION_NAMES = {
  [AniDir.FORWARD] = "forward",
  [AniDir.REVERSE] = "reverse",
  [AniDir.PING_PONG] = "pingpong",
  [AniDir.PING_PONG_REVERSE] = "pingpong_reverse",
}

function M.directionName(aniDir)
  return DIRECTION_NAMES[aniDir] or tostring(aniDir)
end

--- Depth-first list of every layer, groups included, outermost first.
function M.allLayers(sprite)
  local out = {}
  local function walk(layers, depth, parentName)
    for i = #layers, 1, -1 do
      local layer = layers[i]
      out[#out + 1] = { layer = layer, depth = depth, parent = parentName }
      if layer.isGroup then walk(layer.layers, depth + 1, layer.name) end
    end
  end
  walk(sprite.layers, 0, nil)
  return out
end

--- Resolve a layer reference: full uuid, then exact name, then a unique uuid
--- prefix such as the 8-character ids get_sprite_info prints.
function M.resolveLayer(sprite, ref)
  if ref == nil then
    local layer = app.layer
    if not layer then
      proto.fail(proto.ERROR.INVALID_LAYER, "There is no active layer to draw on.")
    end
    return layer
  end
  if type(ref) ~= "string" then
    proto.failf(proto.ERROR.INVALID_LAYER, "Layer reference must be a string, got %s", type(ref))
  end

  local entries = M.allLayers(sprite)
  for _, entry in ipairs(entries) do
    if M.layerId(entry.layer) == ref then return entry.layer end
  end

  local matches = {}
  for _, entry in ipairs(entries) do
    if entry.layer.name == ref then matches[#matches + 1] = entry.layer end
  end
  if #matches == 1 then return matches[1] end
  if #matches > 1 then
    proto.failf(
      proto.ERROR.INVALID_LAYER,
      "%d layers are named %q. Use its id from get_sprite_info instead.", #matches, ref
    )
  end

  -- Six characters is the floor, so a short layer name is never read as an id.
  if #ref >= 6 then
    local found
    for _, entry in ipairs(entries) do
      local id = M.layerId(entry.layer)
      if id and id:sub(1, #ref) == ref then
        if found then
          proto.failf(
            proto.ERROR.INVALID_LAYER,
            "%q is the start of more than one layer id. Use more characters.", ref
          )
        end
        found = entry.layer
      end
    end
    if found then return found end
  end

  local names = {}
  for _, entry in ipairs(entries) do names[#names + 1] = entry.layer.name end
  proto.failf(
    proto.ERROR.INVALID_LAYER,
    "No layer matches %q. Available layers: %s", ref, table.concat(names, ", ")
  )
end

--- Resolve a 1-based frame number, defaulting to the active frame.
function M.resolveFrame(sprite, ref)
  if ref == nil then
    return app.frame and app.frame.frameNumber or 1
  end
  if type(ref) ~= "number" or ref ~= math.floor(ref) then
    proto.failf(proto.ERROR.INVALID_FRAME, "Frame must be a whole number, got %s", tostring(ref))
  end
  if ref < 1 or ref > #sprite.frames then
    proto.failf(
      proto.ERROR.INVALID_FRAME,
      "Frame %d does not exist. This sprite has %d frame(s), numbered 1-%d.",
      ref, #sprite.frames, #sprite.frames
    )
  end
  return ref
end

function M.requireImageLayer(layer)
  if layer.isGroup then
    proto.failf(
      proto.ERROR.INVALID_LAYER,
      "%q is a group layer and holds no pixels. Pick one of its child layers.", layer.name
    )
  end
  if layer.isTilemap then
    proto.failf(
      proto.ERROR.INVALID_LAYER,
      "%q is a tilemap layer, which this server does not edit.", layer.name
    )
  end
  return layer
end

--- Clear an image to the value that reads as transparent for its sprite.
local function clearTo(image, value)
  image:clear(value)
end

--- Write pixels into a cel, growing the cel when they fall outside its bounds.
--
-- Without this, drawing near the edge of an existing cel silently clips, which
-- looks to the agent like the command succeeded and did nothing.
--
-- points: array of {x=, y=, value=} in sprite coordinates.
-- Returns the number written, the number skipped for being off-canvas, and the
-- bounding box of the written pixels as {x, y, width, height} (nil if none).
function M.writePixels(sprite, layer, frameNumber, points, transparent)
  local cel = layer:cel(frameNumber)

  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local kept, skipped = {}, 0
  for _, p in ipairs(points) do
    if p.x >= 0 and p.y >= 0 and p.x < sprite.width and p.y < sprite.height then
      kept[#kept + 1] = p
      if p.x < minX then minX = p.x end
      if p.y < minY then minY = p.y end
      if p.x > maxX then maxX = p.x end
      if p.y > maxY then maxY = p.y end
    else
      skipped = skipped + 1
    end
  end
  if #kept == 0 then return 0, skipped end
  local changed = proto.array({ minX, minY, maxX - minX + 1, maxY - minY + 1 })

  local x0, y0, x1, y1 = minX, minY, maxX, maxY
  if cel then
    local b = cel.bounds
    if b.x < x0 then x0 = b.x end
    if b.y < y0 then y0 = b.y end
    if b.x + b.width - 1 > x1 then x1 = b.x + b.width - 1 end
    if b.y + b.height - 1 > y1 then y1 = b.y + b.height - 1 end
  end

  local image = Image(x1 - x0 + 1, y1 - y0 + 1, sprite.colorMode)
  clearTo(image, transparent)
  if cel then
    image:drawImage(cel.image, Point(cel.bounds.x - x0, cel.bounds.y - y0))
  end
  for _, p in ipairs(kept) do
    image:drawPixel(p.x - x0, p.y - y0, p.value)
  end

  if cel then
    cel.image = image
    cel.position = Point(x0, y0)
  else
    sprite:newCel(layer, frameNumber, image, Point(x0, y0))
  end
  return #kept, skipped, changed
end

--- Erase pixels. Unlike writing, this never grows the cel: erasing outside the
--- existing bounds is a no-op by definition.
function M.erasePixels(sprite, layer, frameNumber, points, transparent)
  local cel = layer:cel(frameNumber)
  if not cel then return 0 end
  local b = cel.bounds
  local image = Image(cel.image)
  local erased = 0
  for _, p in ipairs(points) do
    local lx, ly = p.x - b.x, p.y - b.y
    if lx >= 0 and ly >= 0 and lx < b.width and ly < b.height then
      image:drawPixel(lx, ly, transparent)
      erased = erased + 1
    end
  end
  if erased > 0 then cel.image = image end
  return erased
end

return M
