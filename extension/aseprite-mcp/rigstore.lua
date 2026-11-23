-- Rig storage: where a character rig lives in the .aseprite file, and the
-- bookkeeping that keeps it valid. See docs/ANIMATION.md.
--
-- Everything is kept in Aseprite 1.3 user properties under this extension's
-- key, so a rig travels with the file and survives sessions:
--
--   sprite.properties(EXT).rig   { rest, parts (bottom to top), follows, outline }
--   cel.properties(EXT).pose     the recipe a posed cel was built from, plus a
--                                hash of the pixels it was given
--   cel.properties(EXT).outline  { hash } on an outline cel the rig drew
--
-- The hash is what tells a cel the rig wrote from one a person or the agent
-- edited afterwards. It covers opaque pixels in canvas coordinates, so it does
-- not change if Aseprite stores the same pixels in a differently sized cel.

local M = {}

M.EXT = "aseprite-mcp"
M.OUTLINE_LAYER = "outline"

local FNV_OFFSET, FNV_PRIME = 2166136261, 16777619
-- The hash of a cel with no opaque pixel.
M.EMPTY_HASH = FNV_OFFSET

local function mix(h, n)
  return ((h ~ (n & 0xffffffff)) * FNV_PRIME) & 0xffffffff
end

function M.isOpaque(sprite, value)
  local mode = sprite.colorMode
  if mode == ColorMode.RGB then return app.pixelColor.rgbaA(value) > 0 end
  if mode == ColorMode.GRAY then return app.pixelColor.grayaA(value) > 0 end
  return value ~= sprite.transparentColor
end

--- Hash an image as if placed at (px, py) on the canvas.
function M.hashImage(sprite, image, px, py)
  local h = FNV_OFFSET
  for it in image:pixels() do
    local value = it()
    if M.isOpaque(sprite, value) then
      h = mix(mix(mix(h, it.x + px), it.y + py), value)
    end
  end
  return h
end

function M.hashCel(sprite, cel)
  if not cel then return M.EMPTY_HASH end
  return M.hashImage(sprite, cel.image, cel.position.x, cel.position.y)
end

--- The rig as a plain table, or nil. Property tables come back as copies, so
-- a change is only kept by passing the whole table to save().
function M.load(sprite)
  local rig = sprite.properties(M.EXT).rig
  if rig == nil then return nil end
  local parts = {}
  for i = 1, #rig.parts do parts[i] = rig.parts[i] end
  local follows = {}
  if rig.follows then
    for _, name in ipairs(parts) do
      if rig.follows[name] then follows[name] = rig.follows[name] end
    end
  end
  local outline = nil
  if rig.outline then
    local silhouette = nil
    if rig.outline.parts then
      silhouette = {}
      for i = 1, #rig.outline.parts do silhouette[i] = rig.outline.parts[i] end
    end
    outline = {
      color = rig.outline.color,
      layer = rig.outline.layer or M.OUTLINE_LAYER,
      parts = silhouette,
      floor = rig.outline.floor,
    }
  end
  return { rest = rig.rest, parts = parts, follows = follows, outline = outline }
end

function M.save(sprite, rig)
  local follows = next(rig.follows or {}) and rig.follows or nil
  sprite.properties(M.EXT).rig = {
    rest = rig.rest,
    parts = rig.parts,
    follows = follows,
    outline = rig.outline,
  }
end

--- Top-level layers by exact name, without failing: renumbering must not
-- raise just because a part layer was deleted.
local function partLayers(sprite, rig)
  local wanted, out = {}, {}
  for _, name in ipairs(rig.parts) do wanted[name] = true end
  local function walk(layers)
    for _, layer in ipairs(layers) do
      if layer.isGroup then
        walk(layer.layers)
      elseif wanted[layer.name] then
        out[#out + 1] = layer
      end
    end
  end
  walk(sprite.layers)
  return out
end

--- Rewrite every frame number the rig holds after frames moved.
-- remap(n) returns the new number, or nil when frame n was deleted.
local function renumber(sprite, remap)
  local rig = M.load(sprite)
  if not rig then return end
  rig.rest = remap(rig.rest) or 0
  M.save(sprite, rig)
  for _, layer in ipairs(partLayers(sprite, rig)) do
    for _, cel in ipairs(layer.cels) do
      local props = cel.properties(M.EXT)
      local pose = props.pose
      if pose and pose.src then
        local copy = {}
        for k, v in pairs(pose) do copy[k] = v end
        copy.src = remap(pose.src) or 0
        props.pose = copy
      end
    end
  end
end

--- A frame was inserted at `position`: frames from there on moved up by one.
function M.onInsert(sprite, position)
  renumber(sprite, function(n) return n >= position and n + 1 or n end)
end

--- Frame `deleted` is gone: later frames moved down by one, and anything that
-- pointed at it now points at frame 0, which pose and refresh report.
function M.onDelete(sprite, deleted)
  renumber(sprite, function(n)
    if n == deleted then return nil end
    return n > deleted and n - 1 or n
  end)
end

return M
