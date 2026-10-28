-- Drawing commands (spec section 11).
--
-- Every handler resolves one target cel, collects the points it needs to write,
-- and hands them to doc.writePixels inside a single transaction, so one MCP call
-- is one undo step and pixels outside the current cel bounds grow the cel rather
-- than being silently dropped.

return function(deps)
  local proto, doc, color = deps.proto, deps.doc, deps.color
  local M = {}

  local function target(sprite, params)
    local layer = doc.requireImageLayer(doc.resolveLayer(sprite, params.layer))
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    return layer, frameNumber
  end

  --- Collect the at-most-few distinct palette-snap notes worth reporting.
  local function noteCollector()
    local seen, notes = {}, {}
    return function(note)
      if note and not seen[note] and #notes < 5 then
        seen[note] = true
        notes[#notes + 1] = note
      end
    end, notes
  end

  M["draw.pixels"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params)
    local pixels = params.pixels
    if not proto.isStructured(pixels) or #pixels == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "pixels must be a non-empty array.")
    end

    -- A pixel flagged erase is written as transparent, so draw_rows can clear
    -- and paint in one transaction. Erasing outside the existing cel is a no-op
    -- by definition, so those points are dropped rather than growing the cel.
    local transparent = color.transparentValue(sprite)
    local before = layer:cel(frameNumber)
    local bounds = before and before.bounds

    local addNote, notes = noteCollector()
    local points, erased, erasedOffCanvas = {}, 0, 0
    for i, p in ipairs(pixels) do
      if type(p.x) ~= "number" or type(p.y) ~= "number" then
        proto.failf(proto.ERROR.INVALID_PARAMS, "pixels[%d] needs numeric x and y.", i)
      end
      local x, y = math.floor(p.x), math.floor(p.y)
      if p.erase then
        -- Counted so an over-long draw_rows row is reported rather than
        -- silently clipped; erasing inside the canvas but outside the cel is
        -- just a no-op and needs no warning.
        if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height then
          erasedOffCanvas = erasedOffCanvas + 1
        end
        if bounds and x >= bounds.x and y >= bounds.y
          and x < bounds.x + bounds.width and y < bounds.y + bounds.height
          and x >= 0 and y >= 0 and x < sprite.width and y < sprite.height then
          points[#points + 1] = { x = x, y = y, value = transparent }
          erased = erased + 1
        end
      else
        local value, note = color.toPixelValue(sprite, p)
        addNote(note)
        points[#points + 1] = { x = x, y = y, value = value }
      end
    end

    local written, skipped, changed = 0, 0, nil
    if #points > 0 then
      app.transaction("mcp: draw pixels", function()
        written, skipped, changed = doc.writePixels(sprite, layer, frameNumber, points,
          transparent)
      end)
    end

    local result = {
      written = written - erased,
      erased = erased > 0 and erased or nil,
      changed = changed,
      layer = layer.name,
      frame = frameNumber,
      note = #points == 0
        and "Nothing changed: every pixel was an erase outside the existing cel."
        or nil,
    }
    skipped = (skipped or 0) + erasedOffCanvas
    if skipped > 0 then
      result.skippedOffCanvas = skipped
      result.warning = string.format(
        "%d pixel(s) fell outside the %dx%d canvas and were ignored.",
        skipped, sprite.width, sprite.height
      )
    end
    if #notes > 0 then
      result.paletteNotes = proto.array(notes)
    end
    return result
  end

  M["draw.erase"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params)
    local pixels = params.pixels
    if not proto.isStructured(pixels) or #pixels == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "pixels must be a non-empty array.")
    end

    local points = {}
    for i, p in ipairs(pixels) do
      if type(p.x) ~= "number" or type(p.y) ~= "number" then
        proto.failf(proto.ERROR.INVALID_PARAMS, "pixels[%d] needs numeric x and y.", i)
      end
      points[#points + 1] = { x = math.floor(p.x), y = math.floor(p.y) }
    end

    local erased
    app.transaction("mcp: erase pixels", function()
      erased = doc.erasePixels(sprite, layer, frameNumber, points,
        color.transparentValue(sprite))
    end)
    return {
      erased = erased,
      layer = layer.name,
      frame = frameNumber,
      note = erased == 0
        and "Nothing was erased: those coordinates hold no pixels on this layer and frame."
        or nil,
    }
  end

  M["draw.clearCel"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params)
    local cel = layer:cel(frameNumber)
    if not cel then
      return { cleared = false, layer = layer.name, frame = frameNumber,
               note = "That layer and frame was already empty." }
    end
    app.transaction("mcp: clear cel", function()
      sprite:deleteCel(layer, frameNumber)
    end)
    return { cleared = true, layer = layer.name, frame = frameNumber }
  end

  --- Flood fill, 4-connected, over the target cel composited onto the canvas.
  M["draw.fill"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params)
    local x, y = math.floor(params.x), math.floor(params.y)
    if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height then
      proto.failf(
        proto.ERROR.INVALID_PARAMS,
        "Fill origin (%d,%d) is outside the %dx%d canvas.", x, y, sprite.width, sprite.height
      )
    end

    local transparent = color.transparentValue(sprite)
    local newValue, note = color.toPixelValue(sprite, params)
    local tolerance = params.tolerance or 0
    local w, h = sprite.width, sprite.height

    -- Canvas-sized view of this cel; outside the cel reads as transparent.
    local cel = layer:cel(frameNumber)
    local function valueAt(px, py)
      if not cel then return transparent end
      local b = cel.bounds
      local lx, ly = px - b.x, py - b.y
      if lx < 0 or ly < 0 or lx >= b.width or ly >= b.height then return transparent end
      return cel.image:getPixel(lx, ly)
    end

    -- Cache RGBA decomposition so tolerance comparisons stay cheap.
    local rgbaCache = {}
    local function rgbaOf(value)
      local cached = rgbaCache[value]
      if cached then return cached end
      local hex = color.pixelToHex(sprite, value)
      local r, g, b, a = color.parseHex(hex)
      cached = { r, g, b, a }
      rgbaCache[value] = cached
      return cached
    end

    local seedValue = valueAt(x, y)
    local seedRGBA = tolerance > 0 and rgbaOf(seedValue) or nil
    local function matches(value)
      if value == seedValue then return true end
      if tolerance <= 0 then return false end
      local c = rgbaOf(value)
      return math.abs(c[1] - seedRGBA[1]) <= tolerance
        and math.abs(c[2] - seedRGBA[2]) <= tolerance
        and math.abs(c[3] - seedRGBA[3]) <= tolerance
        and math.abs(c[4] - seedRGBA[4]) <= tolerance
    end

    if seedValue == newValue then
      return {
        filled = 0,
        layer = layer.name,
        frame = frameNumber,
        note = "The origin pixel is already that color; nothing to fill.",
      }
    end

    local visited, points = {}, {}
    local stack = { { x, y } }
    visited[y * w + x] = true
    while #stack > 0 do
      local point = table.remove(stack)
      local px, py = point[1], point[2]
      if matches(valueAt(px, py)) then
        points[#points + 1] = { x = px, y = py, value = newValue }
        local neighbours = { { px - 1, py }, { px + 1, py }, { px, py - 1 }, { px, py + 1 } }
        for _, n in ipairs(neighbours) do
          local nx, ny = n[1], n[2]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local key = ny * w + nx
            if not visited[key] then
              visited[key] = true
              stack[#stack + 1] = n
            end
          end
        end
      end
    end

    local written, _, changed
    app.transaction("mcp: fill", function()
      written, _, changed = doc.writePixels(sprite, layer, frameNumber, points, transparent)
    end)
    return {
      filled = written,
      changed = changed,
      layer = layer.name,
      frame = frameNumber,
      paletteNote = note,
    }
  end

  M["draw.line"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params)
    local x1, y1 = math.floor(params.x1), math.floor(params.y1)
    local x2, y2 = math.floor(params.x2), math.floor(params.y2)
    local value, note = color.toPixelValue(sprite, params)

    -- Bresenham.
    local points = {}
    local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local cx, cy = x1, y1
    while true do
      points[#points + 1] = { x = cx, y = cy, value = value }
      if cx == x2 and cy == y2 then break end
      local e2 = 2 * err
      if e2 > -dy then
        err = err - dy
        cx = cx + sx
      end
      if e2 < dx then
        err = err + dx
        cy = cy + sy
      end
    end

    local written, skipped, changed
    app.transaction("mcp: draw line", function()
      written, skipped, changed = doc.writePixels(sprite, layer, frameNumber, points,
        color.transparentValue(sprite))
    end)
    return {
      written = written,
      changed = changed,
      skippedOffCanvas = (skipped or 0) > 0 and skipped or nil,
      layer = layer.name,
      frame = frameNumber,
      paletteNote = note,
    }
  end

  return M
end
