-- Creates sprites/attack.aseprite: a small idle pose to animate from.
-- Run with: Aseprite.exe -b --script tests/lua/make_fixture.lua

local TEST_DIR = app.fs.filePath(debug.getinfo(1, "S").source:sub(2))
local REPO_ROOT = app.fs.normalizePath(app.fs.joinPath(TEST_DIR, "..", ".."))
local OUT = app.fs.joinPath(REPO_ROOT, "sprites", "attack.aseprite")

local sprite = Sprite(32, 32, ColorMode.RGB)
sprite.filename = OUT

local layer = sprite.layers[1]
layer.name = "Character"

local SKIN = app.pixelColor.rgba(230, 161, 92, 255)
local CLOTH = app.pixelColor.rgba(74, 92, 138, 255)
local DARK = app.pixelColor.rgba(38, 43, 68, 255)

local image = Image(sprite.width, sprite.height, ColorMode.RGB)
image:clear(app.pixelColor.rgba(0, 0, 0, 0))

local function rect(x, y, w, h, value)
  for iy = y, y + h - 1 do
    for ix = x, x + w - 1 do
      image:drawPixel(ix, iy, value)
    end
  end
end

-- A deliberately simple, readable idle pose.
rect(13, 6, 6, 6, SKIN)    -- head
rect(13, 5, 6, 1, DARK)    -- hair
rect(12, 12, 8, 9, CLOTH)  -- torso
rect(10, 13, 2, 6, SKIN)   -- left arm
rect(20, 13, 2, 6, SKIN)   -- right arm
rect(13, 21, 2, 6, DARK)   -- left leg
rect(17, 21, 2, 6, DARK)   -- right leg
rect(12, 27, 4, 2, DARK)   -- left foot
rect(16, 27, 4, 2, DARK)   -- right foot

sprite:newCel(layer, 1, image, Point(0, 0))
sprite.frames[1].duration = 0.1
sprite:newTag(1, 1).name = "idle"

sprite:saveAs(OUT)
print("wrote " .. OUT)
print("FIXTURE_DONE")
