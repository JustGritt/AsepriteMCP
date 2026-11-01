-- Creates the starting sprites for the docs/BENCHMARKS.md prompts, so every
-- version of the server is measured from byte-identical documents.
-- Run with: Aseprite.exe -b --script-param out=<dir> --script tests/lua/make_bench_fixtures.lua

local OUT = app.params["out"]
assert(OUT and OUT ~= "", "pass --script-param out=<dir>")

local function rgba(r, g, b) return app.pixelColor.rgba(r, g, b, 255) end

local SKIN = rgba(230, 161, 92)
local CLOTH = rgba(74, 92, 138)
local DARK = rgba(38, 43, 68)
local ARMOUR = rgba(59, 93, 201)
local ARMOUR_SHADE = rgba(41, 54, 111)
local STEEL = rgba(155, 173, 183)

local function save(sprite, name)
  for _, frame in ipairs(sprite.frames) do frame.duration = 0.1 end
  sprite:saveAs(app.fs.joinPath(OUT, name))
  sprite:close()
end

-- rects are {x, y, w, h, color}, drawn in order and shifted down by dy.
local function paint(sprite, layer, frame, rects, dy)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:clear(app.pixelColor.rgba(0, 0, 0, 0))
  for _, r in ipairs(rects) do
    for y = r[2], r[2] + r[4] - 1 do
      for x = r[1], r[1] + r[3] - 1 do
        image:drawPixel(x, y + (dy or 0), r[5])
      end
    end
  end
  sprite:newCel(layer, frame, image, Point(0, 0))
end

local function withFrames(sprite, count)
  for _ = 2, count do sprite:newEmptyFrame() end
end

-- The same idle pose as make_fixture.lua.
local FIGURE = {
  { 13, 6, 6, 6, SKIN }, { 13, 5, 6, 1, DARK },
  { 12, 12, 8, 9, CLOTH },
  { 10, 13, 2, 6, SKIN }, { 20, 13, 2, 6, SKIN },
  { 13, 21, 2, 6, DARK }, { 17, 21, 2, 6, DARK },
  { 12, 27, 4, 2, DARK }, { 16, 27, 4, 2, DARK },
}

local KNIGHT = {
  { 13, 4, 6, 3, ARMOUR }, { 13, 7, 6, 5, SKIN }, { 13, 8, 6, 1, DARK },
  { 11, 12, 10, 9, ARMOUR }, { 11, 18, 10, 3, ARMOUR_SHADE },
  { 9, 13, 2, 6, ARMOUR_SHADE }, { 21, 13, 2, 6, ARMOUR_SHADE },
  { 23, 6, 1, 13, STEEL },
  { 13, 21, 2, 6, DARK }, { 17, 21, 2, 6, DARK },
  { 12, 27, 4, 2, ARMOUR_SHADE }, { 16, 27, 4, 2, ARMOUR_SHADE },
}

-- 1 and 2: blank canvases.
save(Sprite(16, 16, ColorMode.RGB), "1-potion.aseprite")
save(Sprite(32, 32, ColorMode.RGB), "2-knight.aseprite")

-- 3: a single still pose to animate.
do
  local s = Sprite(32, 32, ColorMode.RGB)
  s.layers[1].name = "Character"
  paint(s, s.layers[1], 1, FIGURE)
  save(s, "3-idle.aseprite")
end

-- 4: a four-frame knight with blue armour in two shades.
do
  local s = Sprite(32, 32, ColorMode.RGB)
  s.layers[1].name = "Knight"
  withFrames(s, 4)
  for i, dy in ipairs({ 0, -1, 0, 1 }) do paint(s, s.layers[1], i, KNIGHT, dy) end
  save(s, "4-armour.aseprite")
end

-- 5: a body and a separate arm layer; the arm is one pixel longer in frame 3.
do
  local s = Sprite(32, 32, ColorMode.RGB)
  local body = s.layers[1]
  body.name = "Body"
  local arm = s:newLayer()
  arm.name = "Arm"
  withFrames(s, 4)
  for i = 1, 4 do
    paint(s, body, i, { FIGURE[1], FIGURE[2], FIGURE[3], FIGURE[4], FIGURE[6], FIGURE[7], FIGURE[8], FIGURE[9] })
    paint(s, arm, i, { { 20, 13, 2, i == 3 and 7 or 6, SKIN } })
  end
  save(s, "5-arm.aseprite")
end

print("FIXTURES_DONE")
