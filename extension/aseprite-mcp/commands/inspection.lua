-- Inspection and rendering commands (spec section 12).
--
-- Previews are rendered over a checkerboard rather than left transparent. Spec
-- section 12 suggests a transparent background, but a transparent PNG is
-- composited by whatever views it, which can make a light sprite invisible on
-- white or a dark one invisible on black -- and an invisible preview defeats the
-- whole point. The checkerboard is the convention Aseprite itself uses, and the
-- response text states it so the agent never mistakes it for artwork.

local SYMBOLS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

return function(deps)
  local proto, doc, color, render = deps.proto, deps.doc, deps.color, deps.render
  local fsio, rigstore = deps.fsio, deps.rigstore
  local M = {}

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

  --- The part of the canvas a preview covers: params.region clamped to the
  -- canvas, or the whole canvas.
  local function previewArea(sprite, region)
    if region == nil then return 0, 0, sprite.width, sprite.height, false end
    local x0, y0 = math.max(0, math.floor(region.x)), math.max(0, math.floor(region.y))
    local x1 = math.min(sprite.width, math.floor(region.x + region.width))
    local y1 = math.min(sprite.height, math.floor(region.y + region.height))
    if x1 <= x0 or y1 <= y0 then
      proto.failf(
        proto.ERROR.INVALID_PARAMS,
        "Region %d,%d %dx%d lies outside the %dx%d canvas.",
        region.x, region.y, region.width, region.height, sprite.width, sprite.height
      )
    end
    return x0, y0, x1 - x0, y1 - y0, true
  end

  --- Crop, scale within the size budget, draw over a checkerboard and write.
  -- Shared by render.canvas and render.layer so both zoom and cap the same way.
  local function writePreview(sprite, source, params, result)
    local x, y, w, h, cropped = previewArea(sprite, params.region)
    if cropped then
      source = render.crop(source, x, y, w, h)
      result.region = proto.array({ x, y, w, h })
    end
    local requested = params.scale or 8
    local scale, reduced = render.fitScale(
      function(s) return w * s, h * s end, requested, params.maxEdge, params.maxPixels)

    local out = Image(w * scale, h * scale, ColorMode.RGB)
    render.checkerboard(out, math.max(4, math.floor(scale / 2) * 2))
    out:drawImage(render.upscale(source, scale), Point(0, 0))
    writePng(out, params.outPath)

    result.width = sprite.width
    result.height = sprite.height
    result.scale = scale
    result.requestedScale = requested
    result.scaleReduced = reduced or nil
    result.empty = render.isEmpty(source) or nil
    result.background = "checkerboard"
    return result
  end

  M["render.canvas"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local composite = render.compositeFrame(sprite, frameNumber)
    return writePreview(sprite, composite, params, { frame = frameNumber })
  end

  M["render.layer"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.requireImageLayer(doc.resolveLayer(sprite, params.layer))
    local frameNumber = doc.resolveFrame(sprite, params.frame)

    local function toRGBA(value)
      local hex = color.pixelToHex(sprite, value)
      return color.parseHex(hex)
    end
    local image = render.layerFrame(sprite, layer, frameNumber, toRGBA)
    return writePreview(sprite, image, params, {
      layer = layer.name,
      id = doc.shortId(sprite, layer),
      frame = frameNumber,
    })
  end

  --- Which visible layer shows at each pixel, as rows of characters.
  -- The structure view: at 18 px the model cannot tell the arm from the torso
  -- by color, but it can read a grid of part letters once each part is a layer.
  local function layerRegion(sprite, frame, x0, y0, w, h)
    local layers = {}
    local function walk(list, parentVisible)
      for i = #list, 1, -1 do
        local layer = list[i]
        local visible = parentVisible and layer.isVisible
        if layer.isGroup then
          walk(layer.layers, visible)
        elseif visible and not layer.isTilemap then
          local cel = layer:cel(frame)
          if cel then layers[#layers + 1] = { layer = layer, cel = cel } end
        end
      end
    end
    walk(sprite.layers, true)

    -- Which layer shows at each pixel, as an index into layers (top first).
    local owners, present, clipped = {}, {}, false
    for y = y0, y0 + h - 1 do
      local row = {}
      for x = x0, x0 + w - 1 do
        local owner = false
        if x < 0 or y < 0 or x >= sprite.width or y >= sprite.height then
          clipped = true
          owner = nil
        else
          for index, entry in ipairs(layers) do
            local b = entry.cel.bounds
            local lx, ly = x - b.x, y - b.y
            if lx >= 0 and ly >= 0 and lx < b.width and ly < b.height
              and rigstore.isOpaque(sprite, entry.cel.image:getPixel(lx, ly)) then
              owner = index
              present[index] = true
              break
            end
          end
        end
        row[#row + 1] = owner
      end
      owners[#owners + 1] = row
    end

    -- Letters are given bottom of the stack first, so a body part gets its
    -- own initial before what sits on it (head h, hat H). Names that share an
    -- initial use their last word instead: leg_far f, leg_near n.
    local initials = {}
    for index in pairs(present) do
      local c = layers[index].layer.name:sub(1, 1):lower()
      initials[c] = (initials[c] or 0) + 1
    end
    local used, symbolOf, legend = {}, {}, {}
    for index = #layers, 1, -1 do
      if present[index] then
        local name = layers[index].layer.name
        local first = name:sub(1, 1):lower()
        local last = name:match("[_%-%s]+(%w)%w*$")
        local candidates = {}
        if last and initials[first] > 1 then candidates[1] = last:lower() end
        candidates[#candidates + 1] = first
        candidates[#candidates + 1] = first:upper()
        if last then candidates[#candidates + 1] = last:upper() end
        for i = 2, #name do candidates[#candidates + 1] = name:sub(i, i):lower() end
        for i = 1, #SYMBOLS do candidates[#candidates + 1] = SYMBOLS:sub(i, i) end
        for _, c in ipairs(candidates) do
          if c:match("%w") and not used[c] then
            used[c] = true
            symbolOf[index] = c
            legend[c] = name
            break
          end
        end
      end
    end

    local rows = {}
    for _, row in ipairs(owners) do
      local chars = {}
      for i = 1, w do
        local owner = row[i]
        if owner == nil then
          chars[i] = " "
        elseif owner == false then
          chars[i] = "."
        else
          chars[i] = symbolOf[owner] or "?"
        end
      end
      rows[#rows + 1] = table.concat(chars)
    end
    return {
      frame = frame,
      source = "layers",
      rows = proto.array(rows),
      legend = legend,
      clippedToCanvas = clipped or nil,
    }
  end

  --- Exact pixel values as a character map plus a legend.
  -- Far more compact than one object per pixel, and easy to read positionally.
  M["inspect.region"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local x0, y0 = math.floor(params.x), math.floor(params.y)
    local w, h = math.floor(params.width), math.floor(params.height)

    if params.byLayer then
      if params.layer ~= nil then
        proto.fail(proto.ERROR.INVALID_PARAMS,
          "byLayer labels every visible layer, so it takes no layer.")
      end
      return layerRegion(sprite, frameNumber, x0, y0, w, h)
    end

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

    -- How to read rows is stated once, in the get_region tool description,
    -- rather than repeated in every reply.
    return {
      frame = frameNumber,
      source = source,
      rows = proto.array(rows),
      legend = legend,
      distinctColors = nextSymbol,
      clippedToCanvas = clipped or nil,
      note = nextSymbol > #SYMBOLS
        and "More distinct colors than legend symbols; extras are shown as ?."
        or nil,
    }
  end

  M["inspect.palette"] = function()
    local sprite = doc.activeSprite()
    local palette = sprite.palettes[1]
    -- Positional: colors[1] is palette index 0. Alpha is spelled out only
    -- when it is not ff, which is rare.
    local entries = {}
    for i = 0, #palette - 1 do
      local c = palette:getColor(i)
      entries[#entries + 1] = c.alpha == 255
        and string.format("#%02x%02x%02x", c.red, c.green, c.blue)
        or color.toHex(c.red, c.green, c.blue, c.alpha)
    end
    return {
      colorMode = doc.colorModeName(sprite.colorMode),
      transparentIndex = sprite.colorMode == ColorMode.INDEXED and sprite.transparentColor or nil,
      colors = proto.array(entries),
    }
  end

  return M
end
