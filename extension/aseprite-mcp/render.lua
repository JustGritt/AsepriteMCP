-- Rendering: upscaling, compositing, contact sheets and onion skins.
--
-- Everything here renders into an RGB image regardless of the color mode of the
-- document. That sidesteps image:saveAs needing an explicit palette argument for
-- indexed sprites, and gives the agent a consistent RGBA PNG to look at.

local M = {}

local BG_LIGHT = app.pixelColor.rgba(107, 107, 107, 255)
local BG_DARK = app.pixelColor.rgba(86, 86, 86, 255)
local SEPARATOR = app.pixelColor.rgba(24, 24, 24, 255)
local LABEL_INK = app.pixelColor.rgba(255, 255, 255, 255)
local LABEL_BACK = app.pixelColor.rgba(0, 0, 0, 200)

-- 3x5 bitmap digits, so a contact sheet can label its own cells. There is no
-- text API on Image, and a cell the agent cannot identify is a cell it cannot
-- give feedback about.
local DIGITS = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "001", "001", "001" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
}
local GLYPH_W, GLYPH_H = 3, 5

function M.fillRect(image, x, y, w, h, value)
  for iy = y, y + h - 1 do
    for ix = x, x + w - 1 do
      if ix >= 0 and iy >= 0 and ix < image.width and iy < image.height then
        image:drawPixel(ix, iy, value)
      end
    end
  end
end

--- Nearest-neighbour upscale.
--
-- image:resize only offers bilinear and rotsprite, both of which blur pixel art
-- and would wreck the visual analysis this whole server exists to support. So we
-- scale by hand: build one scaled row, then blit it once per output row, which
-- measured ~6x faster than a per-output-pixel drawPixel loop.
function M.upscale(src, scale)
  if scale <= 1 then return src end
  local w, h = src.width, src.height
  local dst = Image(w * scale, h * scale, ColorMode.RGB)
  local row = Image(w * scale, 1, ColorMode.RGB)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local value = src:getPixel(x, y)
      local base = x * scale
      for dx = 0, scale - 1 do row:drawPixel(base + dx, 0, value) end
    end
    local baseY = y * scale
    for dy = 0, scale - 1 do dst:drawImage(row, Point(0, baseY + dy)) end
  end
  return dst
end

function M.checkerboard(image, cell)
  cell = cell or 8
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      local light = ((math.floor(x / cell) + math.floor(y / cell)) % 2) == 0
      image:drawPixel(x, y, light and BG_LIGHT or BG_DARK)
    end
  end
end

--- Composite one frame of the sprite into a fresh RGB image.
function M.compositeFrame(sprite, frameNumber)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:clear(app.pixelColor.rgba(0, 0, 0, 0))
  image:drawSprite(sprite, frameNumber)
  return image
end

--- Render a single layer at a frame, ignoring every other layer.
-- Converts through hex so it works for indexed and grayscale documents too.
function M.layerFrame(sprite, layer, frameNumber, toHexValue)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:clear(app.pixelColor.rgba(0, 0, 0, 0))
  local cel = layer:cel(frameNumber)
  if not cel then return image, true end

  local b = cel.bounds
  local src = cel.image
  local empty = true
  for y = 0, b.height - 1 do
    for x = 0, b.width - 1 do
      local tx, ty = b.x + x, b.y + y
      if tx >= 0 and ty >= 0 and tx < sprite.width and ty < sprite.height then
        local r, g, bl, a = toHexValue(src:getPixel(x, y))
        if a > 0 then
          empty = false
          image:drawPixel(tx, ty, app.pixelColor.rgba(r, g, bl, a))
        end
      end
    end
  end
  return image, empty
end

function M.isEmpty(image)
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      if app.pixelColor.rgbaA(image:getPixel(x, y)) > 0 then return false end
    end
  end
  return true
end

--- Draw a small number with a dark backing so it stays readable over any art.
function M.drawNumber(image, number, x, y)
  local text = tostring(number)
  local w = #text * (GLYPH_W + 1) + 1
  M.fillRect(image, x, y, w, GLYPH_H + 2, LABEL_BACK)
  local cursor = x + 1
  for i = 1, #text do
    local glyph = DIGITS[text:sub(i, i)]
    if glyph then
      for gy = 1, GLYPH_H do
        local rowBits = glyph[gy]
        for gx = 1, GLYPH_W do
          if rowBits:sub(gx, gx) == "1" then
            image:drawPixel(cursor + gx - 1, y + gy, LABEL_INK)
          end
        end
      end
    end
    cursor = cursor + GLYPH_W + 1
  end
end

--- Tint an image toward a color and scale its alpha, for onion-skin ghosts.
function M.tint(image, tr, tg, tb, strength, alphaScale)
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      local value = image:getPixel(x, y)
      local a = app.pixelColor.rgbaA(value)
      if a > 0 then
        local r = app.pixelColor.rgbaR(value)
        local g = app.pixelColor.rgbaG(value)
        local b = app.pixelColor.rgbaB(value)
        image:drawPixel(x, y, app.pixelColor.rgba(
          math.floor(r + (tr - r) * strength),
          math.floor(g + (tg - g) * strength),
          math.floor(b + (tb - b) * strength),
          math.floor(a * alphaScale)
        ))
      end
    end
  end
end

--- Lay frames out in a grid, one cell each, labelled with the frame number.
function M.contactSheet(sprite, frameNumbers, scale, columns)
  local count = #frameNumbers
  columns = columns or count
  if columns > count then columns = count end
  local rows = math.ceil(count / columns)

  local cellW, cellH = sprite.width * scale, sprite.height * scale
  local sheetW = columns * cellW + columns + 1
  local sheetH = rows * cellH + rows + 1

  local sheet = Image(sheetW, sheetH, ColorMode.RGB)
  M.checkerboard(sheet, math.max(4, math.floor(scale / 2) * 2))

  -- Separator grid, so adjacent frames never visually merge.
  for x = 0, columns do
    M.fillRect(sheet, x * (cellW + 1), 0, 1, sheetH, SEPARATOR)
  end
  for y = 0, rows do
    M.fillRect(sheet, 0, y * (cellH + 1), sheetW, 1, SEPARATOR)
  end

  for i, frameNumber in ipairs(frameNumbers) do
    local col = (i - 1) % columns
    local row = math.floor((i - 1) / columns)
    local ox = col * (cellW + 1) + 1
    local oy = row * (cellH + 1) + 1
    sheet:drawImage(M.upscale(M.compositeFrame(sprite, frameNumber), scale), Point(ox, oy))
    M.drawNumber(sheet, frameNumber, ox + 1, oy + 1)
  end

  return sheet, columns, rows
end

--- Previous, current and next frame superimposed at distinct opacities.
function M.onionSkin(sprite, frameNumber, scale)
  local canvas = Image(sprite.width, sprite.height, ColorMode.RGB)
  canvas:clear(app.pixelColor.rgba(0, 0, 0, 0))

  local previous, nextFrame = nil, nil
  if frameNumber > 1 then
    previous = M.compositeFrame(sprite, frameNumber - 1)
    M.tint(previous, 255, 60, 60, 0.65, 0.45)
    canvas:drawImage(previous, Point(0, 0), 255, BlendMode.NORMAL)
  end
  if frameNumber < #sprite.frames then
    nextFrame = M.compositeFrame(sprite, frameNumber + 1)
    M.tint(nextFrame, 60, 140, 255, 0.65, 0.45)
    canvas:drawImage(nextFrame, Point(0, 0), 255, BlendMode.NORMAL)
  end
  canvas:drawImage(M.compositeFrame(sprite, frameNumber), Point(0, 0), 255, BlendMode.NORMAL)

  local out = Image(sprite.width * scale, sprite.height * scale, ColorMode.RGB)
  M.checkerboard(out, math.max(4, math.floor(scale / 2) * 2))
  out:drawImage(M.upscale(canvas, scale), Point(0, 0))
  return out, previous ~= nil, nextFrame ~= nil
end

return M
