-- Cel transforms and recolor (spec section 19).
--
-- Most animation frames are an earlier pose moved, mirrored or copied, and most
-- palette fixes are one colour swapped for another. Without these the agent
-- redraws every pixel, which costs thousands of output tokens per frame; with
-- them it is one short call. Each handler is one transaction, so one undo still
-- reverses one call.

return function(deps)
  local proto, doc, color = deps.proto, deps.doc, deps.color
  local M = {}

  local function target(sprite, layerRef, frameRef)
    local layer = doc.requireImageLayer(doc.resolveLayer(sprite, layerRef))
    return layer, doc.resolveFrame(sprite, frameRef)
  end

  local function requireCel(layer, frameNumber)
    local cel = layer:cel(frameNumber)
    if not cel then
      proto.failf(
        proto.ERROR.INVALID_PARAMS,
        "Layer %q has no cel in frame %d, so there is nothing to transform.",
        layer.name, frameNumber
      )
    end
    return cel
  end

  M["cel.shift"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params.layer, params.frame)
    if layer.isBackground then
      proto.failf(
        proto.ERROR.INVALID_LAYER,
        "%q is the background layer, which cannot move. Shift a normal layer instead.",
        layer.name
      )
    end
    local cel = requireCel(layer, frameNumber)
    local dx, dy = math.floor(params.dx or 0), math.floor(params.dy or 0)
    app.transaction("mcp: shift cel", function()
      cel.position = Point(cel.position.x + dx, cel.position.y + dy)
    end)
    return {
      layer = layer.name,
      frame = frameNumber,
      position = proto.array({ cel.position.x, cel.position.y }),
    }
  end

  --- Mirror a cel within the canvas, so a sprite facing right ends up facing
  -- left in the same place rather than flipped about its own corner.
  M["cel.flip"] = function(params)
    local sprite = doc.activeSprite()
    local layer, frameNumber = target(sprite, params.layer, params.frame)
    local cel = requireCel(layer, frameNumber)
    local horizontal = params.direction ~= "vertical"

    local src = cel.image
    local w, h = src.width, src.height
    local out = Image(src.spec)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local sx = horizontal and (w - 1 - x) or x
        local sy = horizontal and y or (h - 1 - y)
        out:drawPixel(x, y, src:getPixel(sx, sy))
      end
    end

    local pos = cel.position
    local newPos = horizontal and Point(sprite.width - (pos.x + w), pos.y)
      or Point(pos.x, sprite.height - (pos.y + h))
    app.transaction("mcp: flip cel", function()
      cel.image = out
      cel.position = newPos
    end)
    return {
      layer = layer.name,
      frame = frameNumber,
      direction = horizontal and "horizontal" or "vertical",
    }
  end

  M["cel.copy"] = function(params)
    local sprite = doc.activeSprite()
    local fromLayer, fromFrame = target(sprite, params.fromLayer, params.fromFrame)
    local toLayer, toFrame = target(sprite, params.toLayer or params.fromLayer, params.toFrame)
    if fromLayer == toLayer and fromFrame == toFrame then
      proto.fail(proto.ERROR.INVALID_PARAMS, "Source and destination are the same cel.")
    end
    local src = requireCel(fromLayer, fromFrame)
    local replaced = toLayer:cel(toFrame) ~= nil

    app.transaction("mcp: copy cel", function()
      local cel = sprite:newCel(toLayer, toFrame, Image(src.image), src.position)
      cel.opacity = src.opacity
    end)
    return {
      from = { layer = fromLayer.name, frame = fromFrame },
      to = { layer = toLayer.name, frame = toFrame },
      replaced = replaced or nil,
    }
  end

  --- Swap one colour for another on a layer, across one frame or many.
  M["cel.replaceColor"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.requireImageLayer(doc.resolveLayer(sprite, params.layer))

    local frames = {}
    if params.frames == "all" then
      for i = 1, #sprite.frames do frames[#frames + 1] = i end
    elseif proto.isStructured(params.frames) then
      for _, f in ipairs(params.frames) do frames[#frames + 1] = doc.resolveFrame(sprite, f) end
    else
      frames[1] = doc.resolveFrame(sprite, params.frame)
    end

    local fr, fg, fb, fa = color.parseHex(params.from)
    local newValue, note = color.toPixelValue(sprite, { color = params.to })
    local tolerance = params.tolerance or 0
    local region = params.region

    local rgbaCache = {}
    local function matches(value)
      local c = rgbaCache[value]
      if not c then
        c = { color.parseHex(color.pixelToHex(sprite, value)) }
        rgbaCache[value] = c
      end
      return math.abs(c[1] - fr) <= tolerance and math.abs(c[2] - fg) <= tolerance
        and math.abs(c[3] - fb) <= tolerance and math.abs(c[4] - fa) <= tolerance
    end

    local replaced, touchedFrames = 0, 0
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    app.transaction("mcp: replace color", function()
      for _, frameNumber in ipairs(frames) do
        local cel = layer:cel(frameNumber)
        if cel then
          local b = cel.bounds
          local image = Image(cel.image)
          local count = 0
          for y = 0, b.height - 1 do
            for x = 0, b.width - 1 do
              local sx, sy = b.x + x, b.y + y
              local inside = region == nil or (sx >= region.x and sy >= region.y
                and sx < region.x + region.width and sy < region.y + region.height)
              local value = image:getPixel(x, y)
              if inside and value ~= newValue and matches(value) then
                image:drawPixel(x, y, newValue)
                count = count + 1
                if sx < minX then minX = sx end
                if sy < minY then minY = sy end
                if sx > maxX then maxX = sx end
                if sy > maxY then maxY = sy end
              end
            end
          end
          if count > 0 then
            cel.image = image
            replaced = replaced + count
            touchedFrames = touchedFrames + 1
          end
        end
      end
    end)

    return {
      replaced = replaced,
      frames = touchedFrames,
      layer = layer.name,
      changed = replaced > 0 and proto.array({ minX, minY, maxX - minX + 1, maxY - minY + 1 })
        or nil,
      paletteNote = note,
      note = replaced == 0 and "No pixel matched that color." or nil,
    }
  end

  return M
end
