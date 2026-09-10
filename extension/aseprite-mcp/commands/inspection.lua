-- Inspection and rendering commands (spec section 12).
--
-- Previews are rendered over a checkerboard rather than left transparent. Spec
-- section 12 suggests a transparent background, but a transparent PNG is
-- composited by whatever views it, which can make a light sprite invisible on
-- white or a dark one invisible on black -- and an invisible preview defeats the
-- whole point. The checkerboard is the convention Aseprite itself uses, and the
-- response text states it so the agent never mistakes it for artwork.

local SYMBOLS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local DEFAULT_MAX_PREVIEW_PIXELS = 4000000

return function(deps)
  local proto, doc, color, render = deps.proto, deps.doc, deps.color, deps.render
  local fsio = deps.fsio
  local M = {}

  --- Clamp scale so a big sprite cannot produce an enormous PNG.
  local function fitScale(width, height, scale, maxPixels)
    maxPixels = maxPixels or DEFAULT_MAX_PREVIEW_PIXELS
    local reduced = scale
    while reduced > 1 and (width * reduced) * (height * reduced) > maxPixels do
      reduced = reduced - 1
    end
    return reduced, reduced ~= scale
  end

  local function writePng(image, outPath)
    if type(outPath) ~= "string" or outPath == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "outPath is required for a render command.")
    end
    if not fsio.saveImage(image, outPath) then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Could not write %s. Aseprite may not have been granted file-system access "
          .. "for scripts; see docs/SETUP.md.", outPath
      )
    end
  end

  --- On-demand check that the extension may write files.
  -- Called by get_connection_status rather than at startup, so the Security
  -- prompt appears when someone asks a question, not every time Aseprite opens.
  M["fs.probe"] = function()
    return { canWriteFiles = fsio.canWrite() }
  end

  M["render.canvas"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local scale, reduced = fitScale(sprite.width, sprite.height, params.scale or 8, params.maxPixels)

    local composite = render.compositeFrame(sprite, frameNumber)
    local empty = render.isEmpty(composite)

    local out = Image(sprite.width * scale, sprite.height * scale, ColorMode.RGB)
    render.checkerboard(out, math.max(4, math.floor(scale / 2) * 2))
    out:drawImage(render.upscale(composite, scale), Point(0, 0))
    writePng(out, params.outPath)

    return {
      frame = frameNumber,
      width = sprite.width,
      height = sprite.height,
      scale = scale,
      requestedScale = params.scale or 8,
      scaleReduced = reduced or nil,
      empty = empty or nil,
      background = "checkerboard",
    }
  end

  M["render.layer"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.requireImageLayer(doc.resolveLayer(sprite, params.layer))
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local scale, reduced = fitScale(sprite.width, sprite.height, params.scale or 8, params.maxPixels)

    local function toRGBA(value)
      local hex = color.pixelToHex(sprite, value)
      return color.parseHex(hex)
    end
    local image, empty = render.layerFrame(sprite, layer, frameNumber, toRGBA)

    local out = Image(sprite.width * scale, sprite.height * scale, ColorMode.RGB)
    render.checkerboard(out, math.max(4, math.floor(scale / 2) * 2))
    out:drawImage(render.upscale(image, scale), Point(0, 0))
    writePng(out, params.outPath)

    return {
      layer = layer.name,
      uuid = doc.layerId(layer),
      frame = frameNumber,
      width = sprite.width,
      height = sprite.height,
      scale = scale,
      requestedScale = params.scale or 8,
      scaleReduced = reduced or nil,
      empty = empty or nil,
      background = "checkerboard",
    }
  end

  --- Exact pixel values as a character map plus a legend.
  -- Far more compact than one object per pixel, and easy to read positionally.
  M["inspect.region"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local x0, y0 = math.floor(params.x), math.floor(params.y)
    local w, h = math.floor(params.width), math.floor(params.height)

    local source, image
    if params.layer ~= nil then
      local layer = doc.requireImageLayer(doc.resolveLayer(sprite, params.layer))
      source = layer.name
      local function toRGBA(value)
        return color.parseHex(color.pixelToHex(sprite, value))
      end
      image = render.layerFrame(sprite, layer, frameNumber, toRGBA)
    else
      source = "composite"
      image = render.compositeFrame(sprite, frameNumber)
    end

    local legend, symbolFor, nextSymbol = {}, {}, 0
    local rows = {}
    local clipped = false

    for y = y0, y0 + h - 1 do
      local chars = {}
      for x = x0, x0 + w - 1 do
        if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height then
          chars[#chars + 1] = " "
          clipped = true
        else
          local value = image:getPixel(x, y)
          local a = app.pixelColor.rgbaA(value)
          local hex = string.format("#%02x%02x%02x%02x",
            app.pixelColor.rgbaR(value), app.pixelColor.rgbaG(value),
            app.pixelColor.rgbaB(value), a)
          local symbol
          if a == 0 then
            symbol = "."
            legend["."] = "#00000000"
          else
            symbol = symbolFor[hex]
            if not symbol then
              nextSymbol = nextSymbol + 1
              if nextSymbol <= #SYMBOLS then
                symbol = SYMBOLS:sub(nextSymbol, nextSymbol)
                symbolFor[hex] = symbol
                legend[symbol] = hex
              else
                symbol = "?"
              end
            end
          end
          chars[#chars + 1] = symbol
        end
      end
      rows[#rows + 1] = table.concat(chars)
    end

    return {
      x = x0, y = y0, width = w, height = h,
      frame = frameNumber,
      source = source,
      colorMode = doc.colorModeName(sprite.colorMode),
      rows = proto.array(rows),
      legend = legend,
      distinctColors = nextSymbol,
      clippedToCanvas = clipped or nil,
      note = nextSymbol > #SYMBOLS
        and "More distinct colors than legend symbols; extras are shown as ?."
        or nil,
      reading = "Each row is one pixel row, left to right. '.' is fully transparent; "
        .. "' ' is outside the canvas. Map other characters through legend.",
    }
  end

  M["inspect.palette"] = function()
    local sprite = doc.activeSprite()
    local palette = sprite.palettes[1]
    local entries = {}
    for i = 0, #palette - 1 do
      local c = palette:getColor(i)
      entries[#entries + 1] = {
        index = i,
        color = color.toHex(c.red, c.green, c.blue, c.alpha),
      }
    end
    return {
      colorMode = doc.colorModeName(sprite.colorMode),
      size = #palette,
      transparentIndex = sprite.colorMode == ColorMode.INDEXED and sprite.transparentColor or nil,
      colors = proto.array(entries),
    }
  end

  return M
end
