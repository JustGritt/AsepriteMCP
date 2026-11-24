-- Bring an image file into the active sprite as a reference layer (#23).
--
-- Working from a picture used to need a throwaway script to shrink it and a
-- second document to hold it. The test that prompted this also showed what the
-- feature should be: reducing a photo to pixel art automatically came out
-- mushy, while painting over it as a guide worked. So the image lands on its own
-- layer, scaled down by averaging the pixels each target pixel covers (Aseprite's
-- image:resize only offers bilinear and rotsprite, which sample a few source
-- pixels and alias badly at 1024 -> 32), and can be snapped to a palette so
-- get_region reads it as a grid to trace.

return function(deps)
  local proto, doc, color, fsio = deps.proto, deps.doc, deps.color, deps.fsio
  local M = {}

  local pc = app.pixelColor

  -- How far, per channel, a pixel may be from the background color and still
  -- count as background. Generated images rarely have a perfectly flat one.
  local KEY_TOLERANCE = 48

  --- Make the background transparent in place: pixels near `key` ({r, g, b})
  -- reached from the border, 4-connected. The same color enclosed by the art,
  -- such as a white cross on a tabard, stays (#40).
  local function keyOut(image, key)
    local w, h = image.width, image.height
    local clear = pc.rgba(0, 0, 0, 0)
    local stack, removed = {}, 0
    -- A cleared pixel no longer matches, so each is visited once.
    local function visit(x, y)
      local value = image:getPixel(x, y)
      if pc.rgbaA(value) > 0
        and math.abs(pc.rgbaR(value) - key[1]) <= KEY_TOLERANCE
        and math.abs(pc.rgbaG(value) - key[2]) <= KEY_TOLERANCE
        and math.abs(pc.rgbaB(value) - key[3]) <= KEY_TOLERANCE then
        image:drawPixel(x, y, clear)
        removed = removed + 1
        stack[#stack + 1] = y * w + x
      end
    end
    for x = 0, w - 1 do visit(x, 0) visit(x, h - 1) end
    for y = 1, h - 2 do visit(0, y) visit(w - 1, y) end
    while #stack > 0 do
      local i = stack[#stack]
      stack[#stack] = nil
      local x, y = i % w, i // w
      if x > 0 then visit(x - 1, y) end
      if x < w - 1 then visit(x + 1, y) end
      if y > 0 then visit(x, y - 1) end
      if y < h - 1 then visit(x, y + 1) end
    end
    return removed
  end

  --- Resample an RGB image to w x h: an area average when shrinking, the
  -- nearest pixel otherwise. Returns rows of {r, g, b, a}, alpha averaged with
  -- colors weighted by it, so transparent pixels do not darken the edges.
  local function resample(source, w, h)
    local sw, sh = source.width, source.height
    local out = {}
    if w <= sw and h <= sh then
      local sums = {}
      for i = 1, w * h do sums[i] = { 0, 0, 0, 0, 0 } end
      for it in source:pixels() do
        local tx = it.x * w // sw
        local ty = it.y * h // sh
        local bin = sums[ty * w + tx + 1]
        local value = it()
        local a = pc.rgbaA(value)
        bin[1] = bin[1] + pc.rgbaR(value) * a
        bin[2] = bin[2] + pc.rgbaG(value) * a
        bin[3] = bin[3] + pc.rgbaB(value) * a
        bin[4] = bin[4] + a
        bin[5] = bin[5] + 1
      end
      for i = 1, w * h do
        local bin = sums[i]
        local alpha = bin[4]
        if alpha == 0 then
          out[i] = { 0, 0, 0, 0 }
        else
          out[i] = {
            math.floor(bin[1] / alpha + 0.5),
            math.floor(bin[2] / alpha + 0.5),
            math.floor(bin[3] / alpha + 0.5),
            math.floor(alpha / bin[5] + 0.5),
          }
        end
      end
      return out, "area average"
    end
    for ty = 0, h - 1 do
      for tx = 0, w - 1 do
        local value = source:getPixel(tx * sw // w, ty * sh // h)
        out[ty * w + tx + 1] = { pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value), pc.rgbaA(value) }
      end
    end
    return out, "nearest"
  end

  --- The colors to snap to, as {r, g, b} triples.
  local function snapColors(sprite, palette)
    local colors = {}
    if palette == "sprite" then
      local pal = sprite.palettes[1]
      for i = 0, #pal - 1 do
        local c = pal:getColor(i)
        if c.alpha > 0 then colors[#colors + 1] = { c.red, c.green, c.blue } end
      end
    else
      for i = 1, #palette do
        local r, g, b = color.parseHex(palette[i])
        colors[#colors + 1] = { r, g, b }
      end
    end
    if #colors == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "The palette to snap to has no opaque colors.")
    end
    return colors
  end

  M["image.import"] = function(params)
    local sprite = doc.activeSprite()
    local frame = doc.resolveFrame(sprite, params.frame)
    local name = params.layer or "Reference"

    local source, why = fsio.readImage(params.path)
    if not source then
      proto.failf(proto.ERROR.LUA_ERROR, "Could not read %s: %s", tostring(params.path), tostring(why))
    end
    local sw, sh = source.width, source.height

    -- A flat background (an image generator's usual output) keyed out first,
    -- or it fills the canvas and snaps to whatever palette color is nearest.
    local keyed = nil
    if params.transparent ~= nil then
      local key
      if params.transparent == "corner" then
        local value = source:getPixel(0, 0)
        key = { pc.rgbaR(value), pc.rgbaG(value), pc.rgbaB(value) }
      else
        local r, g, b = color.parseHex(params.transparent)
        key = { r, g, b }
      end
      keyed = { color.toHex(key[1], key[2], key[3], 255), keyOut(source, key) }
    end

    -- Shrink to fit inside the canvas keeping the aspect ratio, unless told
    -- otherwise; a single side given sets the other by the aspect ratio. Never
    -- enlarged by default: a smaller image is often the finished sprite, and
    -- nearest-neighbour growth by a fraction breaks its pixel grid (#41).
    local w, h = params.width, params.height
    if w == nil and h == nil then
      local scale = math.min(1, sprite.width / sw, sprite.height / sh)
      w, h = math.floor(sw * scale + 0.5), math.floor(sh * scale + 0.5)
    elseif w == nil then
      w = math.floor(sw * h / sh + 0.5)
    elseif h == nil then
      h = math.floor(sh * w / sw + 0.5)
    end
    w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))

    local pixels, method = resample(source, w, h)

    local snapped = nil
    if params.palette ~= nil then
      local colors = snapColors(sprite, params.palette)
      local cache = {}
      for i, p in ipairs(pixels) do
        if p[4] < 128 then
          pixels[i] = { 0, 0, 0, 0 }
        else
          local key = (p[1] << 16) | (p[2] << 8) | p[3]
          local best = cache[key]
          if not best then
            local bestDistance = math.huge
            for _, c in ipairs(colors) do
              local dr, dg, db = c[1] - p[1], c[2] - p[2], c[3] - p[3]
              local distance = dr * dr + dg * dg + db * db
              if distance < bestDistance then best, bestDistance = c, distance end
            end
            cache[key] = best
          end
          pixels[i] = { best[1], best[2], best[3], 255 }
        end
      end
      snapped = #colors
    end

    -- Build the cel in the sprite's own color mode.
    local image = Image(w, h, sprite.colorMode)
    image:clear(color.transparentValue(sprite))
    local distinct, seen = 0, {}
    for i, p in ipairs(pixels) do
      if p[4] > 0 then
        local hex = color.toHex(p[1], p[2], p[3], p[4])
        if not seen[hex] then
          seen[hex] = color.toPixelValue(sprite, { color = hex })
          distinct = distinct + 1
        end
        image:drawPixel((i - 1) % w, (i - 1) // w, seen[hex])
      end
    end

    local x, y = (sprite.width - w) // 2, (sprite.height - h) // 2
    local layer, created = nil, false
    for _, entry in ipairs(doc.allLayers(sprite)) do
      if entry.layer.name == name and entry.depth == 0 then layer = entry.layer break end
    end
    app.transaction("mcp: import image", function()
      if layer == nil then
        if params.reference == false then
          layer = sprite:newLayer()
          layer.name = name
        else
          -- A reference layer, which PNG saves and composites (previews, sprite
          -- sheets) leave out (#42). Only the command makes one: isReference is
          -- read-only. It acts on app.sprite, which activeSprite returned.
          app.command.NewLayer{ reference = true, name = name }
          layer = app.layer
        end
        created = true
        -- At the bottom, under everything drawn from it; above a background.
        local bottom = sprite.layers[1]
        layer.stackIndex = (bottom ~= layer and bottom.isBackground) and 2 or 1
      else
        doc.requireImageLayer(layer)
      end
      sprite:newCel(layer, frame, image, Point(x, y))
    end)

    return {
      layer = layer.name,
      id = doc.shortId(sprite, layer),
      created = created or nil,
      reference = layer.isReference or nil,
      frame = frame,
      source = proto.array({ sw, sh }),
      box = proto.array({ x, y, w, h }),
      method = method,
      snappedTo = snapped,
      keyedOut = keyed and { color = keyed[1], pixels = keyed[2] } or nil,
      distinctColors = distinct,
    }
  end

  return M
end
