-- Headless tests for the Aseprite extension command handlers.
--
-- Run with:
--   Aseprite.exe -b --script tests/lua/run_tests.lua
--
-- Batch mode is used here only to test Lua logic against the real engine. It is
-- not an editing fallback: spec section 2.1 rules that out.

local TEST_DIR = app.fs.filePath(debug.getinfo(1, "S").source:sub(2))
local REPO_ROOT = app.fs.normalizePath(app.fs.joinPath(TEST_DIR, "..", ".."))
local EXT_DIR = app.fs.joinPath(REPO_ROOT, "extension", "aseprite-mcp")

local core = dofile(app.fs.joinPath(EXT_DIR, "bootstrap.lua"))()
local dispatch = core.dispatch
local doc = core.doc

-- ---------------------------------------------------------------- tiny framework

local passed, failed = 0, 0
local failures = {}
local currentTest = "?"

local function fail(message)
  failed = failed + 1
  failures[#failures + 1] = currentTest .. ": " .. message
  print("  FAIL " .. currentTest .. ": " .. message)
end

local function ok(message)
  passed = passed + 1
  if os.getenv("MCP_TEST_VERBOSE") then print("  ok   " .. currentTest .. ": " .. message) end
end

local function check(condition, message)
  if condition then ok(message) else fail(message) end
end

local function equals(actual, expected, message)
  if actual == expected then
    ok(message)
  else
    fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
  end
end

local function test(name, fn)
  currentTest = name
  local success, err = pcall(fn)
  if not success then
    fail("threw: " .. (type(err) == "table" and (err.code or "?") .. " " .. tostring(err.message)
      or tostring(err)))
  end
end

--- Call a command, expecting it to succeed.
local function call(command, params)
  local handler = dispatch[command]
  if not handler then error("no such command: " .. command) end
  return handler(params or {})
end

--- Call a command, expecting it to raise the given error code.
local function expectError(command, params, code, message)
  local handler = dispatch[command]
  if not handler then
    fail("no such command: " .. command)
    return
  end
  local success, err = pcall(handler, params or {})
  if success then
    fail(message .. " (expected error " .. code .. ", but it succeeded)")
  elseif type(err) == "table" and err.code == code then
    ok(message)
  else
    local actual = type(err) == "table" and tostring(err.code) or tostring(err)
    fail(message .. " (expected " .. code .. ", got " .. actual .. ")")
  end
end

local function newSprite(w, h, mode)
  local sprite = Sprite(w or 8, h or 8, mode or ColorMode.RGB)
  app.sprite = sprite
  app.frame = sprite.frames[1]
  app.layer = sprite.layers[1]
  return sprite
end

local tempFiles = {}
local function tempPath(name)
  local path = app.fs.joinPath(app.fs.tempPath, "aseprite_mcp_test_" .. name)
  tempFiles[#tempFiles + 1] = path
  return path
end

-- ------------------------------------------------------------------------ tests

print("=== sprite ===")
test("sprite.info reports geometry", function()
  local sprite = newSprite(16, 12)
  local info = call("sprite.info")
  equals(info.width, 16, "width")
  equals(info.height, 12, "height")
  equals(info.colorMode, "rgb", "color mode")
  equals(#info.frameMs, 1, "frame count")
  equals(#info.layers, 1, "layer count")
  equals(#info.tags, 0, "no tags")
  sprite:close()
end)

test("sprite.info is the whole overview, compactly", function()
  local sprite = newSprite(8, 8)
  local top = call("layer.create", { name = "Arm" })
  call("layer.setVisibility", { layer = top.id, visible = false })
  call("frame.create", {})
  call("frame.setDuration", { frame = 2, durationMs = 120 })
  call("tag.create", { name = "idle", from = 1, to = 2, direction = "pingpong" })

  local info = call("sprite.info")
  equals(#info.layers, 2, "both layers listed")
  equals(info.layers[1].name, "Arm", "top of the stack first")
  equals(#info.layers[1].id, 8, "ids are 8 characters")
  equals(info.layers[1].hidden, true, "hidden layer flagged")
  equals(info.layers[2].hidden, nil, "visible layers carry no flag")
  equals(info.layers[2].type, nil, "image layers carry no type")
  equals(info.activeLayer, top.id, "active layer reported by id")
  equals(info.frameMs[2], 120, "per-frame durations")
  equals(info.tags[1].direction, "pingpong", "non-default direction kept")
  equals(info.tags[1].repeats, nil, "default repeats left out")
  sprite:close()
end)

test("app.status without a document", function()
  for _, s in ipairs(app.sprites) do s:close() end
  local status = call("app.status")
  equals(status.documentOpen, false, "no document open")
end)

test("commands fail cleanly with no sprite", function()
  for _, s in ipairs(app.sprites) do s:close() end
  expectError("sprite.info", {}, "NO_ACTIVE_SPRITE", "sprite.info without a document")
end)

print("=== layers ===")
test("layer create, select, delete", function()
  local sprite = newSprite()
  local created = call("layer.create", { name = "Character" })
  check(created.id ~= nil, "new layer has an id")
  equals(created.name, "Character", "new layer name")
  equals(#call("sprite.info").layers, 2, "two layers after create")

  local selected = call("layer.select", { layer = created.id })
  equals(selected.name, "Character", "select by short id")

  local uuid = tostring(sprite.layers[2].uuid)
  equals(call("layer.select", { layer = uuid }).name, "Character", "select by full uuid")
  equals(call("layer.select", { layer = uuid:sub(1, 6) }).name, "Character",
    "select by a 6-character prefix")
  expectError("layer.select", { layer = uuid:sub(1, 5) }, "INVALID_LAYER",
    "five characters is too short to be an id")

  local byName = call("layer.select", { layer = "Character" })
  equals(byName.name, "Character", "select by name")

  local visibility = call("layer.setVisibility", { layer = created.id, visible = false })
  equals(visibility.visible, false, "hide layer")

  call("layer.delete", { layer = created.id })
  equals(#call("sprite.info").layers, 1, "one layer after delete")
  sprite:close()
end)

test("layer errors", function()
  local sprite = newSprite()
  expectError("layer.select", { layer = "nope" }, "INVALID_LAYER", "unknown layer name")
  expectError("layer.delete", { layer = sprite.layers[1].name }, "INVALID_LAYER",
    "refuses to delete the only layer")
  sprite:close()
end)

print("=== frames ===")
test("frame duration round-trips in milliseconds", function()
  local sprite = newSprite()
  call("frame.setDuration", { frame = 1, durationMs = 80 })
  -- The real assertion: Aseprite stores seconds, the API speaks milliseconds.
  local stored = sprite.frames[1].duration
  check(math.abs(stored - 0.08) < 1e-6, "stored as 0.08 seconds, not 80")
  equals(call("sprite.info").frameMs[1], 80, "reads back as 80ms")
  sprite:close()
end)

test("frame.create inserts after the given frame", function()
  local sprite = newSprite()
  call("frame.setDuration", { frame = 1, durationMs = 11 })
  local created = call("frame.create", { after = 1 })
  equals(created.frame, 2, "new frame index")
  equals(#sprite.frames, 2, "frame count")
  equals(created.frameCount, 2, "reported frame count")
  sprite:close()
end)

test("frame.create with no argument appends", function()
  local sprite = newSprite()
  call("frame.create", {})
  call("frame.create", {})
  equals(#sprite.frames, 3, "appended two frames")
  equals(call("frame.create", {}).frame, 4, "appends at the end")
  sprite:close()
end)

test("frame.duplicate copies content to frame+1", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#ff0000ff" } } })
  call("frame.setDuration", { frame = 1, durationMs = 40 })

  local dup = call("frame.duplicate", { frame = 1 })
  equals(dup.frame, 2, "duplicate lands at frame+1")
  equals(dup.copiedFrom, 1, "reports the source frame")
  equals(#sprite.frames, 2, "frame count")
  equals(dup.durationMs, 40, "duration copied")

  local cel = sprite.layers[1]:cel(2)
  check(cel ~= nil, "duplicate has a cel")
  local region = call("inspect.region", { x = 0, y = 0, width = 4, height = 4, frame = 2 })
  check(region.distinctColors >= 1, "duplicated frame has pixels")
  sprite:close()
end)

test("frame.delete and guards", function()
  local sprite = newSprite()
  call("frame.create", {})
  equals(call("frame.delete", { frame = 2 }).frameCount, 1, "deleted a frame")
  expectError("frame.delete", { frame = 1 }, "INVALID_FRAME", "refuses to delete the only frame")
  expectError("frame.select", { frame = 99 }, "INVALID_FRAME", "out-of-range frame")
  expectError("frame.select", { frame = 0 }, "INVALID_FRAME", "frame 0 is invalid")
  expectError("frame.setDuration", { frame = 1, durationMs = -5 }, "INVALID_PARAMS",
    "negative duration")
  sprite:close()
end)

print("=== drawing ===")
test("draw.pixels writes and expands the cel", function()
  local sprite = newSprite(16, 16)
  -- A freshly created Aseprite sprite already has a full-canvas cel, which would
  -- mask the expansion logic entirely. Start from an empty cel instead.
  call("draw.clearCel", {})

  local first = call("draw.pixels", { pixels = { { x = 4, y = 4, color = "#e6a15c" } } })
  equals(first.written, 1, "wrote one pixel")
  equals(sprite.layers[1]:cel(1).bounds.width, 1, "cel starts 1px wide")

  local second = call("draw.pixels", { pixels = { { x = 9, y = 4, color = "#e6a15c" } } })
  equals(second.written, 1, "wrote a second pixel")
  equals(sprite.layers[1]:cel(1).bounds.width, 6, "cel grew to span both pixels")
  equals(sprite.layers[1]:cel(1).bounds.x, 4, "cel origin stayed at the first pixel")
  -- changed is the box of what this call wrote, not of the whole cel.
  equals(second.changed[1], 9, "changed box starts at the new pixel")
  equals(second.changed[3], 1, "changed box is one pixel wide")

  -- The original pixel must survive the expansion.
  local region = call("inspect.region", { x = 4, y = 4, width = 6, height = 1 })
  equals(region.rows[1]:sub(1, 1), region.rows[1]:sub(6, 6), "both ends are the same color")
  check(region.rows[1]:sub(1, 1) ~= ".", "first pixel still present after expansion")
  sprite:close()
end)

test("draw.pixels clips off-canvas pixels", function()
  local sprite = newSprite(8, 8)
  local result = call("draw.pixels", {
    pixels = {
      { x = 1, y = 1, color = "#ffffff" },
      { x = 99, y = 1, color = "#ffffff" },
      { x = -3, y = 0, color = "#ffffff" },
    },
  })
  equals(result.written, 1, "wrote the in-bounds pixel")
  equals(result.skippedOffCanvas, 2, "skipped both out-of-bounds pixels")
  check(result.warning ~= nil, "warned about skipped pixels")
  sprite:close()
end)

test("draw.pixels erase points clear in the same call", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = {
    { x = 1, y = 1, color = "#ff0000ff" }, { x = 2, y = 1, color = "#ff0000ff" },
  } })
  local result = call("draw.pixels", { pixels = {
    { x = 1, y = 1, erase = true },
    { x = 6, y = 6, erase = true },  -- outside the cel: a no-op, must not grow it
    { x = 3, y = 1, color = "#00ff00ff" },
  } })
  equals(result.erased, 1, "only the in-cel erase counts")
  equals(result.written, 1, "one painted pixel")
  local bounds = sprite.layers[1]:cel(1).bounds
  equals(bounds.y + bounds.height, 2, "an erase outside the cel did not grow it")
  local region = call("inspect.region", { x = 1, y = 1, width = 3, height = 1 })
  equals(region.rows[1]:sub(1, 1), ".", "erased pixel is transparent")
  check(region.rows[1]:sub(3, 3) ~= ".", "painted pixel is present")

  local nothing = call("draw.pixels", { pixels = { { x = 7, y = 7, erase = true } } })
  equals(nothing.written, 0, "nothing written")
  check(nothing.note ~= nil, "explains that nothing changed")
  sprite:close()
end)

test("get_region rows written back with erase reproduce the region", function()
  -- The server's draw_rows decodes rows and legend into draw.pixels points the
  -- same way; replaying that here proves the read and write formats meet.
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = {
    { x = 1, y = 1, color = "#ff0000ff" }, { x = 2, y = 1, color = "#00ff00ff" },
    { x = 2, y = 2, color = "#0000ff80" },
  } })
  local before = call("inspect.region", { x = 0, y = 0, width = 4, height = 4 })

  call("draw.pixels", { pixels = {
    { x = 0, y = 0, color = "#ffffffff" }, { x = 1, y = 1, color = "#ffffffff" },
  } })
  local points = {}
  for row = 1, #before.rows do
    for col = 1, #before.rows[row] do
      local char = before.rows[row]:sub(col, col)
      if char == "." then
        points[#points + 1] = { x = col - 1, y = row - 1, erase = true }
      elseif char ~= " " then
        points[#points + 1] = { x = col - 1, y = row - 1, color = before.legend[char] }
      end
    end
  end
  call("draw.pixels", { pixels = points })

  local after = call("inspect.region", { x = 0, y = 0, width = 4, height = 4 })
  for row = 1, #before.rows do
    equals(after.rows[row], before.rows[row], "row " .. row .. " round-trips")
  end
  sprite:close()
end)

test("draw.pixels with a batch-level color", function()
  local sprite = newSprite(8, 8)
  local result = call("draw.pixels", {
    pixels = { { x = 0, y = 0, color = "#00ff00ff" }, { x = 1, y = 1, color = "#00ff00ff" } },
  })
  equals(result.written, 2, "wrote both pixels")
  sprite:close()
end)

test("draw.erase only affects existing pixels", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = { { x = 3, y = 3, color = "#ffffff" } } })
  local erased = call("draw.erase", { pixels = { { x = 3, y = 3 } } })
  equals(erased.erased, 1, "erased the pixel")

  -- Outside the 1x1 cel, so there is nothing there to erase.
  local none = call("draw.erase", { pixels = { { x = 7, y = 7 } } })
  equals(none.erased, 0, "erasing outside the cel is a no-op")
  check(none.note ~= nil, "explains that nothing was erased")

  -- And with no cel at all.
  call("draw.clearCel", {})
  equals(call("draw.erase", { pixels = { { x = 3, y = 3 } } }).erased, 0,
    "erasing with no cel is a no-op")
  sprite:close()
end)

test("draw.line draws a full run", function()
  local sprite = newSprite(16, 16)
  local line = call("draw.line", { x1 = 0, y1 = 0, x2 = 5, y2 = 0, color = "#ff00ff" })
  equals(line.written, 6, "six pixels along the run, all written")
  equals(line.changed[3], 6, "changed box spans the run")

  local region = call("inspect.region", { x = 0, y = 0, width = 6, height = 1 })
  equals(region.rows[1]:find("%.") , nil, "no gaps in the line")
  sprite:close()
end)

test("draw.fill floods a region", function()
  local sprite = newSprite(8, 8)
  local filled = call("draw.fill", { x = 0, y = 0, color = "#123456ff" })
  equals(filled.filled, 64, "filled the whole empty canvas")

  local again = call("draw.fill", { x = 0, y = 0, color = "#123456ff" })
  equals(again.filled, 0, "filling with the same color is a no-op")
  check(again.note ~= nil, "explains the no-op")

  expectError("draw.fill", { x = 99, y = 0, color = "#ffffff" }, "INVALID_PARAMS",
    "fill origin off canvas")
  sprite:close()
end)

test("draw.fill respects boundaries", function()
  local sprite = newSprite(8, 1)
  -- Wall at x=3 splits the row.
  call("draw.pixels", { pixels = { { x = 3, y = 0, color = "#ffffffff" } } })
  local filled = call("draw.fill", { x = 0, y = 0, color = "#ff0000ff" })
  equals(filled.filled, 3, "filled only up to the wall")
  sprite:close()
end)

test("draw.clearCel", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ffffff" } } })
  equals(call("draw.clearCel", {}).cleared, true, "cleared the cel")
  equals(call("draw.clearCel", {}).cleared, false, "clearing twice is a no-op")
  sprite:close()
end)

print("=== cels ===")
test("cel.shift moves pixels without redrawing", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#ff0000ff" } } })
  local result = call("cel.shift", { dx = 1, dy = -1 })
  equals(result.position[1], 3, "moved right")
  equals(result.position[2], 1, "moved up")
  local region = call("inspect.region", { x = 3, y = 1, width = 1, height = 1 })
  check(region.rows[1] ~= ".", "pixel is at its new place")
  call("history.undo", {})
  equals(sprite.layers[1]:cel(1).position.x, 2, "one undo reverses the shift")
  sprite:close()
end)

test("cel.shift refuses the background layer and empty cels", function()
  local sprite = newSprite(8, 8)
  app.command.BackgroundFromLayer()
  expectError("cel.shift", { dx = 1 }, "INVALID_LAYER", "background cannot move")
  sprite:close()
  local other = newSprite(8, 8)
  call("draw.clearCel", {})
  expectError("cel.shift", { dx = 1 }, "INVALID_PARAMS", "nothing to shift")
  other:close()
end)

test("cel.flip mirrors within the canvas", function()
  local sprite = newSprite(8, 4)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = {
    { x = 1, y = 1, color = "#ff0000ff" }, { x = 2, y = 1, color = "#00ff00ff" },
  } })
  call("cel.flip", { direction = "horizontal" })
  local row = call("inspect.region", { x = 0, y = 1, width = 8, height = 1 }).rows[1]
  equals(row:sub(1, 5), ".....", "left side is now empty")
  check(row:sub(6, 6) ~= "." and row:sub(7, 7) ~= ".", "pixels mirrored to the right")
  check(row:sub(6, 6) ~= row:sub(7, 7), "and their order reversed")
  call("cel.flip", { direction = "vertical" })
  local below = call("inspect.region", { x = 0, y = 2, width = 8, height = 1 }).rows[1]
  check(below:sub(6, 6) ~= ".", "vertical flip moved the row from y=1 to y=2")
  sprite:close()
end)

test("cel.copy duplicates a cel onto another frame and layer", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 4, y = 4, color = "#ffffffff" } } })
  call("frame.create", {})
  local top = call("layer.create", { name = "Shadow" })
  local result = call("cel.copy", {
    fromLayer = sprite.layers[1].name, fromFrame = 1, toLayer = top.id, toFrame = 2,
  })
  equals(result.to.layer, "Shadow", "copied to the other layer")
  local region = call("inspect.region", { x = 4, y = 4, width = 1, height = 1, frame = 2, layer = top.id })
  check(region.rows[1] ~= ".", "pixel arrived in frame 2")
  expectError("cel.copy", { fromFrame = 1, toFrame = 1 }, "INVALID_PARAMS",
    "copying a cel onto itself is rejected")
  sprite:close()
end)

test("cel.replaceColor recolors across frames in one step", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = {
    { x = 1, y = 1, color = "#0000ffff" }, { x = 2, y = 1, color = "#0000ffff" },
    { x = 3, y = 1, color = "#00ff00ff" },
  } })
  call("frame.duplicate", { frame = 1 })
  local result = call("cel.replaceColor", { from = "#0000ffff", to = "#ff0000ff", frames = "all" })
  equals(result.replaced, 4, "two pixels in each of two frames")
  equals(result.frames, 2, "both frames touched")
  equals(result.changed[3], 2, "changed box covers the recolored run")
  local region = call("inspect.region", { x = 1, y = 1, width = 3, height = 1, frame = 2 })
  equals(region.legend[region.rows[1]:sub(1, 1)], "#ff0000ff", "frame 2 recolored")
  equals(region.legend[region.rows[1]:sub(3, 3)], "#00ff00ff", "other colors untouched")
  call("history.undo", {})
  local undone = call("inspect.region", { x = 1, y = 1, width = 1, height = 1, frame = 2 })
  equals(undone.legend[undone.rows[1]], "#0000ffff", "one undo reverses every frame")

  local scoped = call("cel.replaceColor", {
    from = "#0000ffff", to = "#ff0000ff", region = { x = 2, y = 0, width = 4, height = 4 },
  })
  equals(scoped.replaced, 1, "region limits the swap")
  local none = call("cel.replaceColor", { from = "#123456ff", to = "#ff0000ff" })
  equals(none.replaced, 0, "no match")
  check(none.note ~= nil, "and says so")
  sprite:close()
end)

print("=== indexed color ===")
test("indexed sprites snap to the palette", function()
  local sprite = newSprite(8, 8, ColorMode.INDEXED)
  local palette = sprite.palettes[1]
  palette:resize(4)
  palette:setColor(0, Color{ r = 0, g = 0, b = 0, a = 0 })
  palette:setColor(1, Color{ r = 255, g = 0, b = 0, a = 255 })
  palette:setColor(2, Color{ r = 0, g = 255, b = 0, a = 255 })
  palette:setColor(3, Color{ r = 0, g = 0, b = 255, a = 255 })

  local exact = call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ff0000ff" } } })
  check(exact.paletteNotes == nil, "exact palette color needs no note")

  local snapped = call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#fa0505ff" } } })
  check(snapped.paletteNotes ~= nil, "off-palette color reports a snap")

  local byIndex = call("draw.pixels", { pixels = { { x = 3, y = 3, index = 2 } } })
  equals(byIndex.written, 1, "wrote by palette index")

  expectError("draw.pixels", { pixels = { { x = 0, y = 0, index = 99 } } }, "INVALID_PARAMS",
    "palette index out of range")

  local pal = call("inspect.palette")
  equals(#pal.colors, 4, "palette size")
  equals(pal.colorMode, "indexed", "color mode reported")
  equals(pal.colors[2], "#ff0000", "opaque entries omit alpha")
  sprite:close()
end)

test("palette index rejected on rgb sprites", function()
  local sprite = newSprite(4, 4, ColorMode.RGB)
  expectError("draw.pixels", { pixels = { { x = 0, y = 0, index = 1 } } },
    "UNSUPPORTED_COLOR_MODE", "index on an rgb sprite")
  sprite:close()
end)

print("=== inspection ===")
test("inspect.region produces a character map", function()
  local sprite = newSprite(4, 2)
  call("draw.pixels", { pixels = { { x = 0, y = 0, color = "#ff0000ff" } } })
  local region = call("inspect.region", { x = 0, y = 0, width = 4, height = 2 })
  equals(#region.rows, 2, "two rows")
  equals(#region.rows[1], 4, "four columns")
  equals(region.rows[2], "....", "empty row is all dots")
  equals(region.legend["."], nil, "dot is documented once, not repeated per reply")
  equals(region.reading, nil, "no per-reply reading boilerplate")
  equals(region.distinctColors, 1, "one distinct color")
  local symbol = region.rows[1]:sub(1, 1)
  equals(region.legend[symbol], "#ff0000ff", "legend maps the drawn color")
  sprite:close()
end)

test("inspect.region marks pixels outside the canvas", function()
  local sprite = newSprite(2, 2)
  local region = call("inspect.region", { x = 1, y = 1, width = 3, height = 3 })
  equals(region.clippedToCanvas, true, "reports clipping")
  equals(region.rows[1]:sub(2, 2), " ", "off-canvas reads as a space")
  sprite:close()
end)

print("=== rendering ===")
test("render.canvas writes a png", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#ff8800ff" } } })
  local out = tempPath("canvas.png")
  local result = call("render.canvas", { scale = 4, outPath = out })
  check(app.fs.isFile(out), "png written")
  check(app.fs.fileSize(out) > 0, "png is not empty")
  equals(result.scale, 4, "scale honoured")
  equals(result.width, 8, "source width reported")
  sprite:close()
end)

test("render.canvas clamps an oversized scale", function()
  local sprite = newSprite(64, 64)
  local out = tempPath("canvas_big.png")
  local result = call("render.canvas", { scale = 32, outPath = out, maxPixels = 200000 })
  check(result.scale < 32, "scale was reduced")
  equals(result.scaleReduced, true, "reduction is reported")
  sprite:close()
end)

test("render.canvas respects the long-edge cap", function()
  local sprite = newSprite(128, 64)
  local result = call("render.canvas", { scale = 8, maxEdge = 768, outPath = tempPath("capped.png") })
  equals(result.scale, 6, "largest whole scale whose long edge fits 768")
  equals(result.scaleReduced, true, "reduction is reported")
  local small = newSprite(32, 32)
  local kept = call("render.canvas", { scale = 8, maxEdge = 768, outPath = tempPath("small.png") })
  equals(kept.scale, 8, "small sprites keep the requested scale")
  small:close()
  sprite:close()
end)

test("render.canvas zooms into a region", function()
  local sprite = newSprite(32, 32)
  call("draw.pixels", { pixels = { { x = 10, y = 10, color = "#ff8800ff" } } })
  local out = tempPath("zoom.png")
  local result = call("render.canvas", {
    scale = 16, maxEdge = 768, region = { x = 8, y = 8, width = 4, height = 4 }, outPath = out,
  })
  equals(result.region[3], 4, "region width reported")
  equals(result.scale, 16, "a small region keeps a high scale")
  check(result.empty == nil, "the region holds the drawn pixel")
  local png = Image{ fromFile = out }
  equals(png.width, 64, "output is the region at 16x")

  local clipped = call("render.canvas", {
    scale = 2, region = { x = 30, y = 30, width = 10, height = 10 }, outPath = tempPath("clip.png"),
  })
  equals(clipped.region[3], 2, "region is clamped to the canvas")
  expectError("render.canvas", {
    scale = 2, region = { x = 40, y = 40, width = 4, height = 4 }, outPath = tempPath("off.png"),
  }, "INVALID_PARAMS", "a region entirely off the canvas is rejected")
  sprite:close()
end)

test("render.canvas of an indexed sprite", function()
  -- The interesting case: image:saveAs needs a palette for indexed images, which
  -- is why previews composite into RGB first.
  local sprite = newSprite(8, 8, ColorMode.INDEXED)
  local out = tempPath("indexed.png")
  call("render.canvas", { scale = 2, outPath = out })
  check(app.fs.isFile(out), "indexed sprite rendered without a palette error")
  sprite:close()
end)

test("render.layer isolates one layer", function()
  local sprite = newSprite(8, 8)
  local top = call("layer.create", { name = "Top" })
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#00ff00ff" } }, layer = top.id })
  local out = tempPath("layer.png")
  local result = call("render.layer", { layer = top.id, scale = 2, outPath = out })
  equals(result.layer, "Top", "rendered the requested layer")
  check(app.fs.isFile(out), "layer png written")

  local empty = call("render.layer", {
    layer = sprite.layers[1].name, scale = 2, outPath = tempPath("layer_empty.png") })
  equals(empty.empty, true, "empty layer reported as empty")
  sprite:close()
end)

test("render.contactSheet labels every frame", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ffffffff" } } })
  call("frame.duplicate", { frame = 1 })
  call("frame.duplicate", { frame = 2 })
  call("frame.setDuration", { frame = 3, durationMs = 120 })

  local out = tempPath("sheet.png")
  local result = call("render.contactSheet", { scale = 3, outPath = out })
  check(app.fs.isFile(out), "contact sheet written")
  equals(result.frameCount, 3, "three frames")
  equals(#result.cells, 3, "three cells described")
  equals(result.cells[3].durationMs, 120, "per-cell duration reported")
  equals(result.columns, 2, "near-square grid by default")
  equals(result.rows, 2, "three frames wrap onto a second row")
  sprite:close()
end)

test("render.contactSheet fits the long-edge cap", function()
  local sprite = newSprite(64, 64)
  for i = 1, 8 do call("frame.duplicate", { frame = i }) end
  local result = call("render.contactSheet", { scale = 8, maxEdge = 1280, outPath = tempPath("cap.png") })
  equals(result.columns, 3, "nine frames make a 3x3 grid")
  local png = Image{ fromFile = tempPath("cap.png") }
  check(png.width <= 1280 and png.height <= 1280, "sheet fits the cap")
  check(result.scale >= 6, "and uses the largest scale that fits")
  sprite:close()
end)

test("contact sheet cells report every overlapping tag", function()
  -- Inserting frames makes Aseprite widen a tag that spans the insertion point,
  -- so overlapping tags are normal rather than exotic. Reporting only the first
  -- would tell the agent the wrong thing about what it is looking at.
  local sprite = newSprite(8, 8)
  call("frame.create", {})
  call("frame.create", {})
  call("tag.create", { name = "whole", from = 1, to = 3 })
  call("tag.create", { name = "tail", from = 2, to = 3 })

  local result = call("render.contactSheet", { scale = 2, outPath = tempPath("tags.png") })
  equals(#result.cells[1].tags, 1, "frame 1 is covered by one tag")
  equals(result.cells[1].tags[1], "whole", "frame 1 tag name")
  equals(#result.cells[2].tags, 2, "frame 2 is covered by both tags")
  equals(result.cells[2].tags[2], "tail", "the second overlapping tag is reported")
  sprite:close()
end)

test("render.onionSkin reports neighbours", function()
  local sprite = newSprite(8, 8)
  call("frame.duplicate", { frame = 1 })
  call("frame.duplicate", { frame = 2 })

  local middle = call("render.onionSkin", { frame = 2, scale = 2, outPath = tempPath("onion.png") })
  equals(middle.hasPrevious, true, "middle frame has a previous")
  equals(middle.hasNext, true, "middle frame has a next")

  local first = call("render.onionSkin", { frame = 1, scale = 2, outPath = tempPath("onion1.png") })
  equals(first.hasPrevious, false, "first frame has no previous")
  sprite:close()
end)

print("=== tags ===")
test("tag lifecycle", function()
  local sprite = newSprite(8, 8)
  for _ = 1, 5 do call("frame.create", {}) end

  local created = call("tag.create", { name = "attack", from = 1, to = 6, direction = "pingpong" })
  equals(created.name, "attack", "tag name")
  equals(created.from, 1, "tag start")
  equals(created.to, 6, "tag end")
  equals(created.direction, "pingpong", "tag direction")

  equals(#call("sprite.info").tags, 1, "one tag listed")

  local renamed = call("tag.update", { name = "attack", newName = "slash" })
  equals(renamed.name, "slash", "renamed in place")

  local moved = call("tag.update", { name = "slash", from = 2, to = 4 })
  equals(moved.from, 2, "range start moved")
  equals(moved.to, 4, "range end moved")
  equals(moved.name, "slash", "name survived the range change")

  local info = call("anim.info", { tag = "slash" })
  equals(info.frameCount, 3, "tag covers three frames")
  equals(#info.durationsMs, 3, "one duration per frame")

  expectError("tag.create", { name = "slash", from = 1, to = 2 }, "INVALID_PARAMS",
    "duplicate tag name")
  expectError("tag.update", { name = "missing" }, "INVALID_PARAMS", "unknown tag")
  expectError("tag.create", { name = "bad", from = 4, to = 2 }, "INVALID_PARAMS",
    "reversed range")

  call("tag.delete", { name = "slash" })
  equals(#call("sprite.info").tags, 0, "tag deleted")
  sprite:close()
end)

test("anim.info without a tag covers everything", function()
  local sprite = newSprite(8, 8)
  call("frame.create", {})
  local info = call("anim.info", {})
  equals(info.frameCount, 2, "covers both frames")
  equals(info.from, 1, "starts at frame 1")
  sprite:close()
end)

print("=== history ===")
test("undo reverses exactly one command", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ffffffff" } } })
  call("layer.create", { name = "Extra" })
  equals(#call("sprite.info").layers, 2, "layer added")

  call("history.undo")
  equals(#call("sprite.info").layers, 1, "undo removed the layer only")

  local region = call("inspect.region", { x = 1, y = 1, width = 1, height = 1 })
  check(region.rows[1] ~= ".", "the earlier pixel survived the undo")

  call("history.redo")
  equals(#call("sprite.info").layers, 2, "redo restored the layer")
  sprite:close()
end)

print("=== save ===")
test("sprite.save writes a file", function()
  local sprite = newSprite(8, 8)
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ffffffff" } } })
  local out = tempPath("saved.aseprite")
  local result = call("sprite.save", { path = out })
  check(app.fs.isFile(out), "file written")
  equals(result.savedTo, out, "reports where it saved")
  sprite:close()

  local reopened = call("sprite.open", { path = out })
  equals(reopened.width, 8, "reopened sprite has the right size")
  app.sprite:close()
end)

test("unknown command is rejected by name", function()
  check(dispatch["does.not.exist"] == nil, "unknown command is absent from the dispatch table")
end)

print("=== wire path ===")
-- Everything above calls handlers directly, which cannot catch a decoding bug.
-- These drive a raw JSON string through the exact decode-dispatch-reply path the
-- socket uses. That gap is how a type(x) == "table" guard shipped that rejected
-- every real message: json.decode returns userdata, not a table, so the bridge
-- connected happily and then ignored every request.
local sent = {}
local queue = dofile(app.fs.joinPath(EXT_DIR, "queue.lua"))({
  proto = core.proto,
  dispatch = dispatch,
  trace = { write = function() end, writef = function() end, isEnabled = function() return false end },
})
queue.setSender(function(text) sent[#sent + 1] = text end)

local function sendRaw(raw)
  sent = {}
  queue.handleRaw(raw)
  if #sent == 0 then return nil end
  return json.decode(sent[#sent])
end

test("json.decode returns userdata, not a table", function()
  local decoded = json.decode('{"a":1}')
  equals(type(decoded), "userdata", "decoded JSON is userdata")
  check(core.proto.isStructured(decoded), "isStructured accepts it")
  check(core.proto.isStructured({}), "isStructured accepts a real table")
  check(not core.proto.isStructured("x"), "isStructured rejects a string")
  check(not core.proto.isStructured(nil), "isStructured rejects nil")
end)

test("a raw request is decoded, dispatched and answered", function()
  local sprite = newSprite(8, 8)
  local reply = sendRaw('{"id":7,"command":"sprite.info","params":{}}')
  check(reply ~= nil, "a reply was sent")
  equals(reply.id, 7, "reply carries the request id")
  equals(reply.ok, true, "reply is a success")
  equals(reply.result.width, 8, "reply carries real data")
  sprite:close()
end)

test("a raw request with array params survives decoding", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  local reply = sendRaw(
    '{"id":8,"command":"draw.pixels","params":{"pixels":[{"x":1,"y":1,"color":"#ff0000ff"},'
      .. '{"x":2,"y":2,"color":"#ff0000ff"}]}}')
  equals(reply.ok, true, "draw.pixels accepted a decoded array")
  equals(reply.result.written, 2, "both pixels written")
  sprite:close()
end)

test("errors travel back over the wire path", function()
  local sprite = newSprite(8, 8)
  local reply = sendRaw('{"id":9,"command":"frame.select","params":{"frame":99}}')
  equals(reply.ok, false, "reply is a failure")
  equals(reply.error.code, "INVALID_FRAME", "error code preserved")
  equals(reply.id, 9, "error reply carries the request id")
  sprite:close()
end)

test("unknown command answers over the wire path", function()
  local sprite = newSprite(8, 8)
  local reply = sendRaw('{"id":10,"command":"nope.nope","params":{}}')
  equals(reply.ok, false, "unknown command is a failure")
  equals(reply.error.code, "UNKNOWN_COMMAND", "unknown command code")
  sprite:close()
end)

test("malformed json still produces a reply", function()
  local reply = sendRaw("<not json>")
  check(reply ~= nil, "a reply was still sent")
  equals(reply.ok, false, "malformed input is a failure")
  equals(reply.error.code, "PROTOCOL_ERROR", "protocol error code")
end)

test("a request without a numeric id is rejected", function()
  local reply = sendRaw('{"command":"sprite.info"}')
  equals(reply.ok, false, "missing id is a failure")
  equals(reply.error.code, "PROTOCOL_ERROR", "protocol error code")
end)

test("ids survive the json round trip as integers", function()
  local sprite = newSprite(4, 4)
  -- json.decode yields floats (1.0); json.encode must write them back as 1, or
  -- the server drops the reply as an unmatched id.
  local reply = sendRaw('{"id":123,"command":"sprite.info","params":{}}')
  check(sent[#sent]:find('"id": 123') ~= nil or sent[#sent]:find('"id":123') ~= nil,
    "id is encoded as an integer, not 123.0")
  equals(reply.id, 123, "id round-trips")
  sprite:close()
end)

print("=== connection ===")
-- The precedence chain and the status readout, tested without a socket or a
-- Dialog. Both modules keep a pure core for exactly this: Dialog{} returns nil
-- under -b, and Lua cannot *write* environment variables, so a resolver that
-- read os.getenv itself could only ever be exercised on one axis.
local noTrace = {
  write = function() end,
  writef = function() end,
  isEnabled = function() return false end,
}
local ws = dofile(app.fs.joinPath(EXT_DIR, "ws.lua"))({ queue = queue, trace = noTrace })
local dialog = dofile(app.fs.joinPath(EXT_DIR, "dialog.lua"))({ trace = noTrace })

test("resolve: the built-in default when nothing else is set", function()
  local t = ws.resolve(nil, nil, nil, nil)
  equals(t.host, "127.0.0.1", "default host")
  equals(t.port, 32145, "default port")
  equals(t.hostSource, "default", "host source")
  equals(t.portSource, "default", "port source")
end)

test("resolve: the environment beats the default", function()
  local t = ws.resolve(nil, nil, "10.0.0.4", "32200")
  equals(t.host, "10.0.0.4", "env host wins")
  equals(t.port, 32200, "env port wins")
  equals(t.hostSource, "environment", "host source")
  equals(t.portSource, "environment", "port source")
end)

test("resolve: a preference beats the environment", function()
  local t = ws.resolve("192.168.1.5", 40000, "10.0.0.4", "32200")
  equals(t.host, "192.168.1.5", "override host wins")
  equals(t.port, 40000, "override port wins")
  equals(t.hostSource, "preference", "host source")
  equals(t.portSource, "preference", "port source")
  equals(t.envHost, "10.0.0.4", "the shadowed env host is still reported")
  equals(t.envPort, "32200", "and the shadowed env port")
end)

test("resolve: host and port fall through independently", function()
  local t = ws.resolve(nil, 40000, "10.0.0.4", nil)
  equals(t.host, "10.0.0.4", "host came from the environment")
  equals(t.hostSource, "environment", "host source")
  equals(t.port, 40000, "port came from the preference")
  equals(t.portSource, "preference", "port source")
end)

test("resolve: an unset preference falls back to the environment, not the default", function()
  -- The whole reason host and port are never seeded at first run. If "unset"
  -- and "set to the default value" were the same state, writing the defaults in
  -- once would shadow ASEPRITE_MCP_PORT forever, on a machine where it used to
  -- work. See docs/HANDOFF.md.
  local t = ws.resolve(nil, nil, "10.0.0.4", "32200")
  check(t.port ~= 32145, "the default did not win over a set variable")
  equals(t.portSource, "environment", "port source")
end)

test("resolve: an unusable env port is not reported as a plain default", function()
  local t = ws.resolve(nil, nil, nil, "abc")
  equals(t.port, 32145, "the default value is used")
  equals(t.portSource, "environment-invalid", "but the variable is known to be set")
  equals(t.envPort, "abc", "and what it held")
end)

test("setTarget: an empty value clears a slot rather than setting it", function()
  check(ws.setTarget{ host = "1.2.3.4", port = 40000 }, "a good target is accepted")
  equals(ws.status().hostSource, "preference", "the override is in force")
  equals(ws.status().port, 40000, "and applied")
  check(ws.setTarget{ host = "", port = nil }, "empty and nil clear")
  -- Not "default": this machine may have ASEPRITE_MCP_HOST set, and falling
  -- through to it is the point.
  check(ws.status().hostSource ~= "preference", "host fell back out of preference")
  check(ws.status().portSource ~= "preference", "port fell back out of preference")
end)

test("setTarget: refuses a fractional port rather than truncating it", function()
  local ok, err = ws.setTarget{ port = 32145.5 }
  check(not ok, "a fractional port is refused")
  check(err ~= nil and err:find("whole") ~= nil, "and says why: " .. tostring(err))
  -- Guards the reason this check exists. Stock Lua 5.4 raises for %d on a float
  -- with a fraction; Aseprite's build truncates instead, so without an explicit
  -- refusal a hand-edited __pref.lua would dial a port nobody wrote and nothing
  -- would connect the symptom back to the file. If a future Aseprite starts
  -- raising, this line fails and the comments above need revisiting.
  equals(string.format("%d", 32145.5), "32145", "this Lua truncates rather than raising")
end)

test("setTarget: refuses out-of-range ports, and reads 0 as empty", function()
  check(not ws.setTarget{ port = 70000 }, "70000 is refused")
  check(not ws.setTarget{ port = -1 }, "-1 is refused")
  local ok, err = ws.setTarget{ port = 0 }
  check(not ok, "0 is refused")
  -- Aseprite's number widget hands back 0 for an empty field *and* for
  -- unparseable text, so 0 is what the dialog actually has to defend against
  -- and it deserves the message that fits what the user sees.
  check(err ~= nil and err:find("empty") ~= nil, "0 reads as empty: " .. tostring(err))
end)

test("setTarget: a refused value leaves the previous one in place", function()
  check(ws.setTarget{ port = 40000 }, "set a good port")
  check(not ws.setTarget{ port = 99999 }, "then a bad one")
  equals(ws.status().port, 40000, "the good one survives")
  ws.setTarget{}
end)

--- Build a plausible ws.status() return. `false` means "not given": the active
--- target mirrors the resolved one unless a test says otherwise.
local function statusTable(overrides)
  local base = {
    enabled = true,
    connected = true,
    host = "127.0.0.1",
    port = 32145,
    hostSource = "default",
    portSource = "default",
    envHost = nil,
    envPort = nil,
    activeHost = false,
    activePort = false,
    usingToken = false,
    lastError = nil,
    lastAttempt = 100,
  }
  for key, value in pairs(overrides or {}) do base[key] = value end
  if base.activeHost == false then base.activeHost = base.host end
  if base.activePort == false then base.activePort = base.port end
  return base
end

local function vm(overrides, stats, canWrite, now)
  return dialog.viewModel(
    statusTable(overrides),
    stats or { handled = 0, failed = 0 },
    canWrite == nil and true or canWrite,
    now or 100)
end

test("view model: three connection states, not two", function()
  equals(vm({ enabled = true, connected = true }).statusText, "Connected", "connected")
  check(vm({ enabled = true, connected = true }).statusOk, "connected reads ok")
  equals(vm({ enabled = true, connected = false }).statusText, "Connecting...", "dialling")
  check(not vm({ enabled = true, connected = false }).statusOk, "dialling does not")
  equals(vm({ enabled = false, connected = false }).statusText, "Disconnected", "switched off")
end)

test("view model: the toggle caption follows enabled, not connected", function()
  equals(vm({ enabled = true, connected = false }).toggleText, "Disconnect", "enabled but dialling")
  equals(vm({ enabled = false, connected = false }).toggleText, "Connect", "switched off")
end)

test("view model: a silently failed dial still gets an explanation", function()
  -- The common failure -- no server listening -- leaves lastError nil, because
  -- WebSocket{} construction succeeds and the dial fails asynchronously, where
  -- onreceive only ever sees OPEN/TEXT/CLOSE. Without this the dialog would
  -- report "Connecting..." forever and say nothing about why.
  equals(vm({ connected = false, lastAttempt = 100 }, nil, true, 102).statusHint, "",
    "silent during the grace period")
  local late = vm({ connected = false, lastAttempt = 100 }, nil, true, 110)
  check(late.statusHint:find("No server at 127.0.0.1:32145") ~= nil,
    "then names the address: " .. late.statusHint)
  equals(vm({ connected = true, lastAttempt = 100 }, nil, true, 110).statusHint, "",
    "and never while connected")
  equals(vm({ enabled = false, connected = false, lastAttempt = 100 }, nil, true, 110).statusHint,
    "", "nor when nothing is trying")
end)

test("view model: file trust carries its remedy only when it is missing", function()
  local trusted = vm({}, nil, true)
  equals(trusted.filesText, "Trusted", "trusted")
  equals(trusted.filesHint, "", "and says nothing more")
  local denied = vm({}, nil, false)
  equals(denied.filesText, "Not trusted", "not trusted")
  check(not denied.filesOk, "and is not ok")
  check(denied.filesHint:find("SETUP") ~= nil,
    "and points somewhere: " .. denied.filesHint)
end)

test("view model: a preference shadowing the environment is annotated", function()
  equals(vm({}).serverNote, "", "nothing to say when no variable is set")
  equals(vm({ portSource = "environment", envPort = "32145" }).serverNote, "",
    "nor when the variable itself won")
  equals(vm({ portSource = "preference", port = 40000, envPort = "32200" }).serverNote,
    "env: 32200 - overridden", "names the value being shadowed")
  equals(vm({ portSource = "preference", port = 32200, envPort = "32200" }).serverNote,
    "", "but not when the two agree")
  equals(vm({ hostSource = "preference", host = "1.2.3.4", envHost = "10.0.0.4" }).serverNote,
    "env: 10.0.0.4 - overridden", "the same for the host")
  equals(vm({ portSource = "environment-invalid", envPort = "abc" }).serverNote,
    "env: abc - not a number, ignored", "an unusable variable says so rather than vanishing")
end)

test("view model: a resolved target the socket is not on yet", function()
  local note = vm({ connected = true, port = 40000, activePort = 32145 }).serverNote
  check(note:find("press Reconnect") ~= nil, "asks for it to be applied: " .. note)
end)

test("view model: the handled counter", function()
  equals(vm({}, { handled = 1, failed = 0 }).handledText, "1 command (0 failed)", "singular")
  equals(vm({}, { handled = 214, failed = 3 }).handledText, "214 commands (3 failed)", "plural")
end)

test("view model: errors are truncated, and dropped once connected", function()
  local long = string.rep("z", 200)
  local shown = vm({ connected = false, lastError = long })
  -- The window is pinned to the size it has at show{}, so anything longer would
  -- be clipped at an arbitrary point. Better to choose where the cut lands.
  check(#shown.errorText <= 58, "truncated to the pinned width, got " .. #shown.errorText)
  equals(shown.errorText:sub(-3), "...", "and marked as truncated")
  equals(vm({ connected = true, lastError = long }).errorText, "",
    "a stale error beside a live connection would read as a current one")
  equals(vm({ enabled = false, connected = false, lastError = long }).errorText, "",
    "and beside a deliberate Disconnect it would read as a failure")
end)

test("view model: the token row stays visible even though the field is not", function()
  equals(vm({ usingToken = false }).tokenText, "off", "off")
  equals(vm({ usingToken = true }).tokenText, "on (environment)", "on")
end)

test("display text: the status markers are decided in exactly one place", function()
  local texts = dialog.displayText(vm({ enabled = true, connected = true }))
  check(texts.status:find("Connected") ~= nil, "carries the text")
  check(texts.status ~= "Connected", "and a marker in front of it")
  equals(texts.toggle, "Disconnect", "a button caption is left as a plain string")
  equals(texts.handled, "0 commands (0 failed)", "and so is the counter")
end)

-- ----------------------------------------------------------------------- teardown

for _, path in ipairs(tempFiles) do os.remove(path) end

print("")
print(string.format("passed: %d, failed: %d", passed, failed))
if failed > 0 then
  print("FAILURES:")
  for _, message in ipairs(failures) do print("  - " .. message) end
  print("LUA_TESTS_FAILED")
else
  print("LUA_TESTS_PASSED")
end
