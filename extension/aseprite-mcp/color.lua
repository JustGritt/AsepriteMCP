-- Color conversion. The MCP server validates the *format* of a color; this is
-- the only place that knows the color mode of the document, and therefore the
-- only place that can turn "#E6A15C" into an actual pixel value.

local M = {}
local proto = nil

function M.setProtocol(p) proto = p end

--- Parse a canonical "#rrggbbaa" string into components.
function M.parseHex(hex)
  if type(hex) ~= "string" then
    proto.failf(proto.ERROR.INVALID_PARAMS, "Expected a hex color string, got %s", type(hex))
  end
  local digits = hex:gsub("^#", "")
  if #digits == 6 then digits = digits .. "ff" end
  if #digits ~= 8 then
    proto.failf(proto.ERROR.INVALID_PARAMS, "Bad hex color %q", hex)
  end
  local r = tonumber(digits:sub(1, 2), 16)
  local g = tonumber(digits:sub(3, 4), 16)
  local b = tonumber(digits:sub(5, 6), 16)
  local a = tonumber(digits:sub(7, 8), 16)
  if not (r and g and b and a) then
    proto.failf(proto.ERROR.INVALID_PARAMS, "Bad hex color %q", hex)
  end
  return r, g, b, a
end

function M.toHex(r, g, b, a)
  return string.format("#%02x%02x%02x%02x", r, g, b, a)
end

--- Nearest palette entry to an RGB triple, by squared distance.
-- Aseprite exposes no nearest-color lookup, so indexed sprites need this.
-- Returns index and whether the match was exact.
function M.nearestPaletteIndex(palette, r, g, b, a)
  local bestIndex, bestDistance = 0, math.huge
  for i = 0, #palette - 1 do
    local c = palette:getColor(i)
    -- A fully transparent target should only ever match a transparent entry.
    if (a == 0) == (c.alpha == 0) then
      local dr, dg, db = c.red - r, c.green - g, c.blue - b
      local distance = dr * dr + dg * dg + db * db
      if distance < bestDistance then
        bestIndex, bestDistance = i, distance
      end
    end
  end
  return bestIndex, bestDistance == 0
end

--- Convert a request color into a pixel value for the given sprite.
-- Returns the pixel value plus a note when the color had to be snapped onto the
-- palette, so the agent can be told it drifted off-palette.
function M.toPixelValue(sprite, spec)
  local mode = sprite.colorMode

  if spec.index ~= nil then
    if mode ~= ColorMode.INDEXED then
      proto.fail(
        proto.ERROR.UNSUPPORTED_COLOR_MODE,
        "A palette index was given but this sprite is not in indexed color mode."
      )
    end
    local palette = sprite.palettes[1]
    if spec.index < 0 or spec.index >= #palette then
      proto.failf(
        proto.ERROR.INVALID_PARAMS,
        "Palette index %d is out of range; this palette has %d entries (0-%d).",
        spec.index, #palette, #palette - 1
      )
    end
    return spec.index, nil
  end

  local r, g, b, a = M.parseHex(spec.color)

  if mode == ColorMode.RGB then
    return app.pixelColor.rgba(r, g, b, a), nil
  elseif mode == ColorMode.GRAY then
    -- Rec. 601 luma, which is what Aseprite uses when converting to grayscale.
    local v = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
    return app.pixelColor.graya(v, a), nil
  elseif mode == ColorMode.INDEXED then
    local palette = sprite.palettes[1]
    local index, exact = M.nearestPaletteIndex(palette, r, g, b, a)
    if exact then return index, nil end
    local c = palette:getColor(index)
    return index, string.format(
      "%s is not in the palette; snapped to index %d (%s)",
      spec.color, index, M.toHex(c.red, c.green, c.blue, c.alpha)
    )
  end

  proto.failf(proto.ERROR.UNSUPPORTED_COLOR_MODE, "Unsupported color mode %s", tostring(mode))
end

--- The pixel value meaning "fully transparent" for this sprite.
function M.transparentValue(sprite)
  if sprite.colorMode == ColorMode.INDEXED then
    return sprite.transparentColor
  elseif sprite.colorMode == ColorMode.GRAY then
    return app.pixelColor.graya(0, 0)
  end
  return app.pixelColor.rgba(0, 0, 0, 0)
end

--- Read a pixel value back as "#rrggbbaa", for inspection output.
function M.pixelToHex(sprite, value)
  local mode = sprite.colorMode
  if mode == ColorMode.RGB then
    return M.toHex(
      app.pixelColor.rgbaR(value), app.pixelColor.rgbaG(value),
      app.pixelColor.rgbaB(value), app.pixelColor.rgbaA(value)
    )
  elseif mode == ColorMode.GRAY then
    local v = app.pixelColor.grayaV(value)
    return M.toHex(v, v, v, app.pixelColor.grayaA(value))
  else
    local palette = sprite.palettes[1]
    if value < 0 or value >= #palette then
      return "#00000000"
    end
    local c = palette:getColor(value)
    -- The index that means "transparent" reads back as transparent.
    if value == sprite.transparentColor then
      return M.toHex(c.red, c.green, c.blue, 0)
    end
    return M.toHex(c.red, c.green, c.blue, c.alpha)
  end
end

return M
