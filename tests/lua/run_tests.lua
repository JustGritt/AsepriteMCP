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

--- Whole file as a string, to prove a file did or did not change.
local function fileBytes(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("a")
  file:close()
  return data
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

test("sprite.new creates, activates and optionally saves", function()
  local info = call("sprite.new", { width = 24, height = 12, colorMode = "indexed" })
  equals(info.width, 24, "width")
  equals(info.height, 12, "height")
  equals(info.colorMode, "indexed", "color mode")
  equals(#info.layers, 1, "one layer")
  equals(#info.frameMs, 1, "one frame")
  equals(app.sprite.width, 24, "the new sprite is the active one")
  app.sprite:close()

  local path = tempPath("new_saved.aseprite")
  local saved = call("sprite.new", { width = 8, height = 8, path = path })
  check(app.fs.isFile(path), "file written")
  equals(saved.path, path, "overview reports where it was saved")
  app.sprite:close()

  expectError("sprite.new", { width = 8, height = 8, colorMode = "cmyk" }, "INVALID_PARAMS",
    "unknown color mode")
  expectError("sprite.new", { width = 0, height = 8 }, "INVALID_PARAMS", "zero width")
end)

test("sprite.open replies with the same overview as sprite.info", function()
  local sprite = newSprite(8, 8)
  call("layer.create", { name = "Arm" })
  call("frame.create", {})
  local path = tempPath("overview.aseprite")
  call("sprite.save", { path = path })
  sprite:close()

  local opened = call("sprite.open", { path = path })
  local info = call("sprite.info")
  equals(#opened.layers, 2, "layers included")
  equals(#opened.frameMs, 2, "frames included")
  equals(opened.layers[1].id, info.layers[1].id, "same ids as sprite.info")
  equals(opened.activeLayer, info.activeLayer, "same active layer")
  equals(opened.filename, nil, "the old reply shape is gone")
  app.sprite:close()
end)

test("app.status lists the open documents", function()
  for _, s in ipairs(app.sprites) do s:close() end
  local a = newSprite(4, 4)
  local b = newSprite(4, 4)
  local status = call("app.status")
  equals(status.openDocuments, 2, "two documents")
  equals(#status.documents, 2, "both listed by name")
  equals(status.documents[2], app.fs.fileName(b.filename), "in open order")
  a:close()
  b:close()
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

  local overlong = call("draw.pixels", { pixels = {
    { x = 1, y = 1, color = "#ff0000ff" }, { x = 8, y = 1, erase = true },
  } })
  equals(overlong.skippedOffCanvas, 1, "an erase past the canvas edge is reported")
  check(overlong.warning ~= nil, "with a warning")

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

print("=== batch ===")
test("batch.run applies several commands as one undo step", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#ff0000ff" } } })
  local reply = call("batch.run", { ops = {
    { command = "frame.duplicate", params = { frame = 1 } },
    { command = "cel.shift", params = { dy = -1, frame = 2 } },
    { command = "draw.pixels", params = { frame = 2, pixels = { { x = 5, y = 5, color = "#00ff00ff" } } } },
  } })
  equals(reply.applied, 3, "three ops applied")
  equals(reply.results[1].frame, 2, "per-op results come back in order")
  equals(#sprite.frames, 2, "frame duplicated")
  equals(sprite.layers[1]:cel(2).position.y, 1, "copy shifted up")

  call("history.undo", {})
  equals(#sprite.frames, 1, "one undo reverses the whole batch")
  sprite:close()
end)

test("batch results carry what the server's summary reads", function()
  -- tools/batch.py replaces these results with a summary, and tests there use a
  -- fake extension. If a field is renamed here, this is what notices.
  local sprite = newSprite(8, 8)
  local r = call("batch.run", { ops = {
    { command = "layer.create", params = { name = "New" } },
    { command = "frame.create", params = {} },
    { command = "frame.duplicate", params = { frame = 1 } },
    { command = "draw.pixels", params = { frame = 1, pixels = { { x = 1, y = 1, color = "#ff0000ff" },
      { x = 99, y = 0, color = "#ff0000ff" } } } },
    { command = "draw.line", params = { frame = 1, x1 = 0, y1 = 0, x2 = 3, y2 = 0, color = "#00ff00ff" } },
    { command = "draw.fill", params = { frame = 1, x = 7, y = 7, color = "#0000ffff" } },
    { command = "draw.erase", params = { frame = 1, pixels = { { x = 1, y = 1 } } } },
    { command = "cel.replaceColor", params = { frames = { 1 }, from = "#00ff00ff", to = "#ffffffff" } },
    { command = "cel.replaceColor", params = { frames = { 1 }, from = "#123456ff", to = "#ffffffff" } },
    { command = "frame.delete", params = { frame = 3 } },
  } }).results

  equals(r[1].name, "New", "layer.create: name")
  check(type(r[1].id) == "string", "layer.create: id")
  equals(r[2].frame, 2, "frame.create: frame")
  equals(r[3].frame, 2, "frame.duplicate: frame")
  equals(r[3].frameCount, 3, "frame.duplicate: frameCount")
  equals(r[4].written, 1, "draw.pixels: written")
  equals(r[4].skippedOffCanvas, 1, "draw.pixels: skippedOffCanvas")
  check(type(r[4].warning) == "string", "draw.pixels: warning")
  equals(#r[4].changed, 4, "draw.pixels: changed is a box")
  equals(r[5].written, 4, "draw.line: written")
  equals(#r[5].changed, 4, "draw.line: changed is a box")
  check(r[6].filled > 0, "draw.fill: filled")
  equals(#r[6].changed, 4, "draw.fill: changed is a box")
  equals(r[7].erased, 1, "draw.erase: erased")
  equals(r[8].replaced, 4, "cel.replaceColor: replaced")
  equals(#r[8].changed, 4, "cel.replaceColor: changed is a box")
  check(type(r[9].note) == "string", "an op that did nothing says so in note")
  equals(r[10].frameCount, 2, "frame.delete: frameCount")
  sprite:close()
end)

test("batch.run is all or nothing", function()
  local sprite = newSprite(8, 8)
  expectError("batch.run", { ops = {
    { command = "frame.create", params = {} },
    { command = "frame.setDuration", params = { frame = 9, durationMs = 80 } },
  } }, "INVALID_FRAME", "the failing op's code is reported")
  equals(#sprite.frames, 1, "the frame created before the failure was rolled back")
  local ok, err = pcall(dispatch["batch.run"], { ops = {
    { command = "frame.create", params = {} },
    { command = "draw.pixels", params = { pixels = {} } },
  } })
  check(not ok and err.message:find("ops%[1%] %(draw.pixels%)") ~= nil, "message names the op")
  check(err.message:find("rolled back") ~= nil, "and says nothing changed")
  sprite:close()
end)

test("batch.run refuses commands that cannot nest", function()
  local sprite = newSprite(8, 8)
  for _, command in ipairs({ "history.undo", "render.canvas", "sprite.save", "batch.run", "nope" }) do
    expectError("batch.run", { ops = { { command = command, params = {} } } },
      "INVALID_PARAMS", command .. " is not batchable")
  end
  expectError("batch.run", { ops = {} }, "INVALID_PARAMS", "empty batch")
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

test("identical pixels render to identical png bytes", function()
  -- The server skips resending an image the agent already has by comparing
  -- PNG bytes, so it relies on this. Test-only file read; the extension itself
  -- reads nothing outside fsio.lua.
  local function bytes(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("a")
    file:close()
    return data
  end
  local sprite = newSprite(16, 16)
  call("draw.pixels", { pixels = { { x = 3, y = 4, color = "#ff8800ff" } } })
  local function render(name)
    local out = tempPath(name)
    call("render.canvas", { scale = 8, maxEdge = 768, outPath = out })
    return bytes(out)
  end
  local before = render("same1.png")
  equals(render("same2.png") == before, true, "the same render twice is byte-identical")
  call("draw.pixels", { pixels = { { x = 5, y = 5, color = "#00ff00ff" } } })
  equals(render("edited.png") ~= before, true, "an edit changes the bytes")
  app.undo()
  equals(render("undone.png") == before, true, "undoing it restores them")

  call("frame.duplicate", { frame = 1 })
  local sheet1, sheet2 = tempPath("sheet1.png"), tempPath("sheet2.png")
  call("render.contactSheet", { scale = 4, maxEdge = 1280, outPath = sheet1 })
  call("render.contactSheet", { scale = 4, maxEdge = 1280, outPath = sheet2 })
  equals(bytes(sheet1) == bytes(sheet2), true, "so is a contact sheet")
  sprite:close()
end)

print("=== frame comparison ===")
test("anim.compare reports what moved, as numbers", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = {
    { x = 2, y = 2, color = "#ff0000ff" }, { x = 3, y = 2, color = "#ff0000ff" },
  } })
  call("frame.duplicate", { frame = 1 })
  local same = call("anim.compare", { a = 1, b = 2 })
  equals(same.changedPixels, 0, "a duplicate is identical")
  equals(same.changed, nil, "no changed box")

  call("cel.shift", { dx = 1, frame = 2 })
  call("draw.pixels", { frame = 2, pixels = { { x = 3, y = 2, color = "#00ff00ff" } } })
  local diff = call("anim.compare", { a = 1, b = 2, diffMap = true })
  equals(diff.appeared, 1, "the pixel shifted onto empty space appeared")
  equals(diff.vanished, 1, "the pixel it left vanished")
  equals(diff.recolored, 1, "one pixel changed color")
  equals(diff.diff[1], "-*+", "diff map marks each kind")
  equals(diff.boundsB[1], 3, "frame b's bounds moved right")
  sprite:close()
end)

test("anim.bounds exposes drift across frames", function()
  local sprite = newSprite(8, 8)
  call("draw.clearCel", {})
  call("draw.pixels", { pixels = { { x = 2, y = 2, color = "#ffffffff" } } })
  call("frame.duplicate", { frame = 1 })
  call("cel.shift", { dy = 1, frame = 2 })
  call("frame.create", {})
  local result = call("anim.bounds", {})
  equals(result.frames[1].bounds[2], 2, "frame 1 at y=2")
  equals(result.frames[2].bounds[2], 3, "frame 2 drifted to y=3")
  equals(result.frames[3].empty, true, "empty frame flagged")
  equals(result.union[4], 2, "union spans both positions")
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

test("sprite.save refuses to pick its own target", function()
  -- The server vets the file before saving. A call that names nothing has been
  -- vetted by nobody, and would write wherever the active tab came from.
  local out = tempPath("bare.aseprite")
  local sprite = newSprite(8, 8)
  call("sprite.save", { path = out })
  local before = fileBytes(out)
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#ff0000ff" } } })
  expectError("sprite.save", {}, "INVALID_PARAMS", "no path and no expectedPath is refused")
  check(fileBytes(out) == before, "the file was not written")
  sprite:close()
end)

test("sprite.save with expectedPath only saves that document", function()
  local out = tempPath("expected.aseprite")
  local sprite = newSprite(8, 8)
  call("sprite.save", { path = out })
  local own = sprite.filename

  local result = call("sprite.save", { expectedPath = own })
  equals(result.savedTo, own, "saves over its own file when it still matches")

  -- The tab changed between the server's check and this command.
  local other = newSprite(4, 4)
  local before = fileBytes(out)
  expectError("sprite.save", { expectedPath = own }, "INVALID_PARAMS",
    "a different active document is refused")
  check(fileBytes(out) == before, "the checked file was not touched")
  other:close()
  sprite:close()
end)

print("=== sprite sheets ===")
local rgba = app.pixelColor.rgba
local fsio = core.fsio

-- A 3x2 grid of 2x2 cells. Every cell has its own color, except the empty one at
-- column 1, row 1, and a partly transparent pixel in the first cell of column 2.
local PARTIAL = rgba(200, 100, 50, 105)
local function cellColor(col, row) return rgba(10 * (col + 1), 20 * (row + 1), 30, 255) end

local function sheetImage()
  local image = Image(6, 4, ColorMode.RGB)
  image:clear(rgba(0, 0, 0, 0))
  for row = 0, 1 do
    for col = 0, 2 do
      if not (col == 1 and row == 1) then
        for y = 0, 1 do
          for x = 0, 1 do image:drawPixel(col * 2 + x, row * 2 + y, cellColor(col, row)) end
        end
      end
    end
  end
  image:drawPixel(4, 0, PARTIAL)
  return image
end

local function writeSheet(name)
  local path = tempPath(name)
  sheetImage():saveAs(path)
  return path
end

--- Close every document a test opened, so the next one starts clean.
local function closeAbove(count)
  while #app.sprites > count do app.sprites[#app.sprites]:close() end
end

test("fsio.readPng reads the disk and leaves open tabs alone", function()
  local path = writeSheet("sheet_tab.png")
  local base = #app.sprites
  local tab = app.open(path)
  local unsaved = rgba(1, 2, 3, 255)
  tab.cels[1].image:drawPixel(0, 0, unsaved)
  local other = newSprite(4, 4)
  local count = #app.sprites

  local image = fsio.readPng(path)
  equals(#app.sprites, count, "no document left behind, none closed")
  check(app.sprite == other, "the active document is unchanged")
  equals(image:getPixel(0, 0), cellColor(0, 0), "reads the file, not the tab's unsaved edit")
  equals(tab.cels[1].image:getPixel(0, 0), unsaved, "the tab keeps its edit")

  app.sprite = tab
  local again = fsio.readPng(path)
  check(again ~= nil, "also works when that tab is the active one")
  check(app.sprite == tab, "and that tab stays active")
  closeAbove(base)
end)

test("fsio.readPng reports what it cannot read", function()
  local image, why = fsio.readPng(tempPath("does_not_exist.png"))
  check(image == nil, "no image")
  check(type(why) == "string", "a reason")
end)

test("sprite.importSheet slices a sheet into a new document", function()
  local path = writeSheet("sheet_import.png")
  local bytes = fileBytes(path)
  local base = #app.sprites
  local before = newSprite(4, 4)
  local result = call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })

  equals(#result.frameMs, 6, "one frame per cell")
  equals(result.width, 2, "frame width")
  equals(result.height, 2, "frame height")
  equals(result.colorMode, "rgb", "rgb document")
  equals(result.activeFrame, 1, "starts on the first frame")
  equals(result.sheet.columns, 3, "columns run to the edge")
  equals(result.sheet.rows, 2, "rows run to the edge")
  equals(#result.sheet.emptyFrames, 1, "one empty cell")
  equals(result.sheet.emptyFrames[1], 5, "the empty cell keeps its place in the order")
  check(result.warning == nil, "an even grid gets no warning")

  local sprite = app.sprite
  check(sprite ~= before, "a new document is active")
  check(not app.fs.isFile(sprite.filename), "it has no file, so a save cannot land on the PNG")
  check(fileBytes(path) == bytes, "the PNG is not touched")
  check(#sprite.palettes[1] > 1, "the palette holds the sheet's colors")

  local layer = sprite.layers[1]
  equals(layer:cel(1).image:getPixel(0, 0), cellColor(0, 0), "frame 1 is column 0, row 0")
  equals(layer:cel(2).image:getPixel(0, 0), cellColor(1, 0), "frame 2 is column 1, row 0")
  equals(layer:cel(4).image:getPixel(0, 0), cellColor(0, 1), "frame 4 starts the next row")
  check(layer:cel(5) == nil, "the empty cell has no cel")
  equals(layer:cel(3).image:getPixel(0, 0), PARTIAL, "partial alpha arrives exactly")
  closeAbove(base)
end)

test("sprite.importSheet is one undo step", function()
  local path = writeSheet("sheet_undo.png")
  local base = #app.sprites
  call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })
  call("history.undo")
  equals(#app.sprite.frames, 1, "one undo takes it all back")
  call("history.redo")
  equals(#app.sprite.frames, 6, "one redo restores it")
  closeAbove(base)
end)

test("sprite.importSheet takes one area of a sheet", function()
  local path = writeSheet("sheet_area.png")
  local base = #app.sprites
  local result = call("sprite.importSheet", {
    path = path, frameWidth = 2, frameHeight = 2, x = 2, y = 2, columns = 2, rows = 1,
  })
  equals(#result.frameMs, 2, "only the cells asked for")
  equals(app.sprite.layers[1]:cel(2).image:getPixel(0, 0), cellColor(2, 1), "offset from x,y")
  equals(#result.sheet.emptyFrames, 1, "the empty cell is reported")
  closeAbove(base)
end)

test("sprite.importSheet refuses what does not fit, without leaving a document", function()
  local path = writeSheet("sheet_nofit.png")
  local count = #app.sprites
  expectError("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2, rows = 3 },
    "INVALID_PARAMS", "too many rows")
  expectError("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2, columns = 4 },
    "INVALID_PARAMS", "too many columns")
  expectError("sprite.importSheet", { path = path, frameWidth = 7, frameHeight = 2 },
    "INVALID_PARAMS", "a frame wider than the sheet")
  expectError("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2, x = 6 },
    "INVALID_PARAMS", "an origin past the edge")
  local big = tempPath("sheet_big.png")
  Image(64, 64, ColorMode.RGB):saveAs(big)
  expectError("sprite.importSheet", { path = big, frameWidth = 1, frameHeight = 1 },
    "INVALID_PARAMS", "more frames than any real sheet has")
  expectError("sprite.importSheet", { path = tempPath("missing_sheet.png"), frameWidth = 2,
    frameHeight = 2 }, "LUA_ERROR", "an unreadable file")
  equals(#app.sprites, count, "no document left behind")
end)

test("sprite.importSheet warns when frames do not divide the sheet", function()
  local path = writeSheet("sheet_uneven.png")
  local base = #app.sprites
  local uneven = call("sprite.importSheet", { path = path, frameWidth = 4, frameHeight = 3 })
  check(type(uneven.warning) == "string", "left-over pixels are flagged")
  local asked = call("sprite.importSheet", {
    path = path, frameWidth = 4, frameHeight = 3, columns = 1, rows = 1,
  })
  check(asked.warning == nil, "not when columns and rows were chosen on purpose")
  closeAbove(base)
end)

test("sprite.importSheet reads an indexed PNG as colors", function()
  local path = tempPath("sheet_indexed.png")
  local base = #app.sprites
  local indexed = newSprite(2, 1, ColorMode.INDEXED)
  local palette = Palette(2)
  palette:setColor(0, Color{ r = 0, g = 0, b = 0, a = 0 })
  palette:setColor(1, Color{ r = 255, g = 0, b = 0 })
  indexed:setPalette(palette)
  indexed.cels[1].image:drawPixel(1, 0, 1)
  indexed:saveAs(path)
  indexed:close()

  local result = call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 1 })
  equals(result.colorMode, "rgb", "the new document is rgb")
  local image = app.sprite.layers[1]:cel(1).image
  equals(image:getPixel(0, 0), rgba(0, 0, 0, 0), "the transparent index stays transparent")
  equals(image:getPixel(1, 0), rgba(255, 0, 0, 255), "the color index becomes its color")
  closeAbove(base)
end)

test("sprite.exportSheet round-trips a sheet exactly", function()
  local path = writeSheet("sheet_trip.png")
  local out = tempPath("sheet_trip_out.png")
  local base = #app.sprites
  call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })
  local result = call("sprite.exportSheet", { path = out, columns = 3 })
  equals(result.width, 6, "width")
  equals(result.height, 4, "height")
  equals(result.frames, 6, "frames")
  equals(result.rows, 2, "rows")
  check(result.changedPixels == nil, "nothing to compare against without onto")
  check(fsio.readPng(out).bytes == sheetImage().bytes, "every pixel matches, alpha included")
  closeAbove(base)
end)

test("sprite.exportSheet defaults to one row", function()
  local path = writeSheet("sheet_strip.png")
  local out = tempPath("sheet_strip_out.png")
  local base = #app.sprites
  call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })
  local result = call("sprite.exportSheet", { path = out })
  equals(result.columns, 6, "one column per frame")
  equals(result.width, 12, "strip width")
  equals(result.height, 2, "strip height")
  closeAbove(base)
end)

test("sprite.exportSheet leaves hidden layers out and the document alone", function()
  local path = writeSheet("sheet_hidden.png")
  local saved = tempPath("sheet_hidden.aseprite")
  local out = tempPath("sheet_hidden_out.png")
  local base = #app.sprites
  call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })
  local sprite = app.sprite
  local reference = sprite:newLayer()
  reference.name = "reference"
  local solid = Image(2, 2, ColorMode.RGB)
  solid:clear(rgba(0, 255, 0, 255))
  for frame = 1, 6 do sprite:newCel(reference, frame, solid, Point(0, 0)) end
  reference.isVisible = false
  call("sprite.save", { path = saved })

  call("sprite.exportSheet", { path = out, columns = 3 })
  check(fsio.readPng(out).bytes == sheetImage().bytes, "the hidden layer is not in the PNG")
  equals(sprite.filename, saved, "the document keeps its own file")
  check(not sprite.isModified, "exporting does not mark it modified")
  equals(#sprite.layers, 2, "layers stay separate")
  closeAbove(base)
end)

test("sprite.exportSheet takes one tag", function()
  local path = writeSheet("sheet_tag.png")
  local out = tempPath("sheet_tag_out.png")
  local base = #app.sprites
  call("sprite.importSheet", { path = path, frameWidth = 2, frameHeight = 2 })
  local tag = app.sprite:newTag(2, 3)
  tag.name = "pair"
  local result = call("sprite.exportSheet", { path = out, tag = "pair", columns = 2 })
  equals(result.frames, 2, "only the tag's frames")
  equals(result.width, 4, "width")
  local image = fsio.readPng(out)
  equals(image:getPixel(0, 0), cellColor(1, 0), "starts at the tag's first frame")
  expectError("sprite.exportSheet", { path = out, tag = "nope" }, "INVALID_PARAMS",
    "an unknown tag is refused")
  closeAbove(base)
end)

test("sprite.exportSheet onto replaces its cells and nothing else", function()
  local base = #app.sprites
  local sheet = writeSheet("sheet_onto.png")
  local out = tempPath("sheet_onto_out.png")
  local bytes = fileBytes(sheet)

  -- Mostly transparent on purpose: pasting must erase what was there, and a
  -- partly transparent pixel must land exactly rather than blend with it.
  local patch = newSprite(2, 2)
  patch.cels[1].image:drawPixel(1, 1, PARTIAL)

  local result = call("sprite.exportSheet", { path = out, onto = sheet, x = 2, y = 0 })
  equals(result.width, 6, "keeps the sheet's width")
  equals(result.height, 4, "keeps the sheet's height")
  equals(result.changedPixels, 4, "reports what changed")
  check(fileBytes(sheet) == bytes, "the sheet it started from is not touched")

  local expected = sheetImage()
  for y = 0, 1 do
    for x = 2, 3 do expected:drawPixel(x, y, rgba(0, 0, 0, 0)) end
  end
  expected:drawPixel(3, 1, PARTIAL)
  check(fsio.readPng(out).bytes == expected.bytes, "only that cell differs, and exactly")
  closeAbove(base)
end)

test("sprite.exportSheet onto leaves cells past the last frame alone", function()
  local base = #app.sprites
  local sheet = writeSheet("sheet_partial.png")
  local out = tempPath("sheet_partial_out.png")
  -- Columns 1 and 2: the sheet's own empty cell is frame 3, a filled one frame 4.
  -- A sheet can hold something in a cell that belongs to another grid, and
  -- dropping frame 4 has to mean that cell stays as it is.
  call("sprite.importSheet", {
    path = sheet, frameWidth = 2, frameHeight = 2, x = 2, columns = 2, rows = 2,
  })
  call("frame.delete", { frame = 4 })
  local sprite = app.sprite
  local solid = Image(2, 2, ColorMode.RGB)
  solid:clear(rgba(9, 9, 9, 255))
  for frame = 1, 3 do sprite:newCel(sprite.layers[1], frame, solid, Point(0, 0)) end

  local result = call("sprite.exportSheet", { path = out, onto = sheet, x = 2, columns = 2 })
  equals(result.rows, 2, "three frames in two columns take two rows")
  local image = fsio.readPng(out)
  equals(image:getPixel(2, 0), rgba(9, 9, 9, 255), "the first frame landed")
  equals(image:getPixel(4, 0), rgba(9, 9, 9, 255), "the second frame landed")
  equals(image:getPixel(2, 2), rgba(9, 9, 9, 255), "the third frame landed")
  equals(image:getPixel(4, 2), cellColor(2, 1), "the fourth cell kept what it had")
  equals(image:getPixel(0, 0), cellColor(0, 0), "a cell outside the block is untouched")
  closeAbove(base)
end)

test("sprite.exportSheet onto can update a file in place", function()
  local base = #app.sprites
  local sheet = writeSheet("sheet_inplace.png")
  local patch = newSprite(2, 2)
  patch.cels[1].image:clear(rgba(7, 7, 7, 255))
  equals(call("sprite.exportSheet", { path = sheet, onto = sheet }).changedPixels, 4,
    "the first paste changes the cell")
  equals(call("sprite.exportSheet", { path = sheet, onto = sheet }).changedPixels, 0,
    "pasting the same cell again changes nothing")
  equals(fsio.readPng(sheet):getPixel(0, 0), rgba(7, 7, 7, 255), "the file holds the new cell")
  closeAbove(base)
end)

test("sprite.exportSheet refuses a block that does not fit", function()
  local base = #app.sprites
  local sheet = writeSheet("sheet_tight.png")
  local out = tempPath("sheet_tight_out.png")
  newSprite(2, 2)
  expectError("sprite.exportSheet", { path = out, onto = sheet, x = 5 }, "INVALID_PARAMS",
    "past the right edge")
  expectError("sprite.exportSheet", { path = out, onto = sheet, y = 3 }, "INVALID_PARAMS",
    "past the bottom edge")
  expectError("sprite.exportSheet", { path = out, columns = 0 }, "INVALID_PARAMS",
    "columns must be positive")
  check(not app.fs.isFile(out), "nothing was written")
  closeAbove(base)
end)

print("=== opening an open file ===")
test("sprite.open switches to a tab that already holds the file", function()
  local base = #app.sprites
  local path = writeSheet("open_tab.png")
  local first = call("sprite.open", { path = path })
  check(first.alreadyOpen == nil, "the first open is a plain open")
  local tab = app.sprite
  local other = newSprite(4, 4)
  local count = #app.sprites

  local second = call("sprite.open", { path = path })
  equals(#app.sprites, count, "no second document")
  check(app.sprite == tab, "that tab is active again")
  check(app.sprite ~= other, "and not the one in front before")
  equals(second.alreadyOpen, true, "the reply says so")
  check(second.unsaved == nil, "and has nothing unsaved to report")
  closeAbove(base)
end)

test("sprite.open keeps a tab's unsaved edits and says they are there", function()
  local base = #app.sprites
  local path = writeSheet("open_unsaved.png")
  call("sprite.open", { path = path })
  call("draw.pixels", { pixels = { { x = 0, y = 0, color = "#010203ff" } } })
  newSprite(4, 4)

  local reply = call("sprite.open", { path = path })
  equals(reply.unsaved, true, "the reply flags the edits")
  equals(app.sprite.cels[1].image:getPixel(0, 0), rgba(1, 2, 3, 255), "the tab wins over the file")
  closeAbove(base)
end)

test("sprite.open finds a tab however the path is spelled", function()
  local base = #app.sprites
  local path = writeSheet("open_spelled.png")
  call("sprite.open", { path = path })
  local tab = app.sprite
  local count = #app.sprites
  newSprite(4, 4)
  count = count + 1

  local slashes = path:gsub("\\", "/")
  equals(call("sprite.open", { path = slashes }).alreadyOpen, true, "other slashes")
  check(app.sprite == tab, "other slashes reach the tab")
  newSprite(4, 4)
  count = count + 1
  -- Up and back into the same folder: a ".." through a folder that does not
  -- exist only resolves on Windows, which simplifies the path as text first.
  local dir = app.fs.filePath(path)
  local dotted = app.fs.joinPath(dir, "..", app.fs.fileName(dir), app.fs.fileName(path))
  equals(call("sprite.open", { path = dotted }).alreadyOpen, true, "a .. in the path")
  check(app.sprite == tab, "a .. reaches the tab")
  if app.os.windows then
    newSprite(4, 4)
    count = count + 1
    equals(call("sprite.open", { path = path:upper() }).alreadyOpen, true, "other case on Windows")
    check(app.sprite == tab, "other case reaches the tab")
  end
  equals(#app.sprites, count, "none of them made a second document")
  closeAbove(base)
end)

test("sprite.open does not take an unsaved sprite's name for a file", function()
  local base = #app.sprites
  local unsaved = newSprite(4, 4)
  local path = writeSheet("Sprite.png")
  local reply = call("sprite.open", { path = path })
  check(reply.alreadyOpen == nil, "a new document, not the sprite named Sprite")
  check(app.sprite ~= unsaved, "and it is active")
  closeAbove(base)
end)

test("sprite.open opens a numbered PNG by itself", function()
  local base = #app.sprites
  local first, second = tempPath("numbered1.png"), tempPath("numbered2.png")
  sheetImage():saveAs(first)
  sheetImage():saveAs(second)
  local reply = call("sprite.open", { path = first })
  equals(#reply.frameMs, 1, "one frame, not a sequence")
  equals(reply.width, 6, "the file's width")
  equals(app.fs.fileName(app.sprite.filename), app.fs.fileName(first), "under its own name")
  check(reply.paletteSize > 1, "with the file's colors in the palette")
  check(not app.sprite.isModified, "and nothing to save yet")
  local pixels = Image(6, 4, ColorMode.RGB)
  pixels:clear(rgba(0, 0, 0, 0))
  pixels:drawSprite(app.sprite, 1)
  check(pixels.bytes == sheetImage().bytes, "with the file's exact pixels")
  closeAbove(base)
end)

test("sprite.open still loads every frame of a numbered .aseprite", function()
  local base = #app.sprites
  local first, second = tempPath("numbered1.aseprite"), tempPath("numbered2.aseprite")
  for _, path in ipairs({ first, second }) do
    local sprite = newSprite(4, 4)
    sprite:newEmptyFrame()
    sprite:saveAs(path)
    sprite:close()
  end
  equals(#call("sprite.open", { path = first }).frameMs, 2, "its own two frames")
  closeAbove(base)
end)

test("unknown command is rejected by name", function()
  check(dispatch["does.not.exist"] == nil, "unknown command is absent from the dispatch table")
end)

print("=== rig ===")

local SKIN, OLIVE, BOOT, SHADE, GOLD, INK =
  "#e3b98fff", "#8c9657ff", "#6b5a44ff", "#4d4032ff", "#e6b84aff", "#20222cff"

--- The hex color of one pixel of one layer, or nil where it is transparent.
local function px(sprite, layerName, frame, x, y)
  local layer = doc.resolveLayer(sprite, layerName)
  local cel = layer:cel(frame)
  if not cel then return nil end
  local lx, ly = x - cel.position.x, y - cel.position.y
  if lx < 0 or ly < 0 or lx >= cel.image.width or ly >= cel.image.height then return nil end
  local value = cel.image:getPixel(lx, ly)
  if app.pixelColor.rgbaA(value) == 0 then return nil end
  return core.color.pixelToHex(sprite, value)
end

local FIGURE = { ".hh.", ".hh.", "tttt", "tttt", "tttt", "tttt", "f.n.", "f.n.", "f.n." }
local LABELS = { { "h", "head" }, { "t", "torso" }, { "n", "leg_near" }, { "f", "leg_far" } }

--- A 16x16 figure on one `body` layer: a head, a torso and two legs, at x 5-8,
-- y 2-10, with a hat on its own layer. Split into parts unless told not to.
local function figure(split)
  local sprite = newSprite(16, 16)
  sprite.layers[1].name = "body"
  local pixels = {}
  local colors = { h = SKIN, t = OLIVE, n = BOOT, f = SHADE }
  for j, row in ipairs(FIGURE) do
    for i = 1, #row do
      local c = row:sub(i, i)
      if c ~= "." then pixels[#pixels + 1] = { x = 4 + i, y = 1 + j, color = colors[c] } end
    end
  end
  call("draw.pixels", { layer = "body", pixels = pixels })
  call("layer.create", { name = "hat" })
  call("draw.pixels", { layer = "hat", pixels = {
    { x = 6, y = 1, color = GOLD }, { x = 7, y = 1, color = GOLD } } })
  if split ~= false then
    call("cel.split", { layer = "body", x = 5, y = 2, rows = FIGURE, parts = LABELS })
  end
  return sprite
end

local function rigged(outline)
  local sprite = figure()
  call("rig.define", {
    parts = { "leg_far", "torso", "leg_near", "head", "hat" },
    follows = { hat = "head" },
    outline = outline,
  })
  call("frame.create", {})
  call("frame.create", {})
  return sprite
end

local function stackNames(sprite)
  local names = {}
  for i, layer in ipairs(sprite.layers) do names[i] = layer.name end
  return table.concat(names, ",")
end

test("cel.split moves labelled pixels into new layers above the source", function()
  local sprite = figure(false)
  local result = call("cel.split", { layer = "body", x = 5, y = 2, rows = FIGURE, parts = LABELS })
  equals(result.moved.head, 4, "head pixels moved")
  equals(result.moved.torso, 16, "torso pixels moved")
  equals(result.left, 0, "nothing left on body")
  equals(#result.created, 4, "four layers created")
  equals(stackNames(sprite), "body,head,torso,leg_near,leg_far,hat",
    "created directly above the source, in the order listed")
  equals(px(sprite, "leg_near", 1, 7, 9), BOOT, "a leg pixel landed on its layer")
  equals(px(sprite, "body", 1, 7, 9), nil, "and left the source")

  local again = call("cel.split", { layer = "torso", x = 5, y = 4, rows = { "x..." },
    parts = { { "x", "arm" } } })
  equals(again.moved.arm, 1, "an existing part can be split further")
  local miss = call("cel.split", { layer = "torso", x = 0, y = 0, rows = { "x" },
    parts = { { "x", "arm" } } })
  equals(miss.labelledTransparent, 1, "a label on a transparent pixel is counted")
  equals(miss.labelledTransparentAt[1][1], 0, "and located")
  expectError("cel.split", { layer = "torso", x = 5, y = 5, rows = { "q" },
    parts = { { "x", "arm" } } }, "INVALID_PARAMS", "an unmapped character")
  expectError("cel.split", { layer = "torso", x = 5, y = 5, rows = { "x" },
    parts = { { "x", "torso" } } }, "INVALID_PARAMS", "splitting a layer into itself")
  sprite:close()
end)

test("rig.define stacks the parts, creates the missing ones and is stored", function()
  local sprite = figure()
  local result = call("rig.define", {
    parts = { "leg_far", "torso", "leg_near", "head", "cape", "hat" },
    follows = { hat = "head" },
    outline = { color = INK, parts = { "leg_far", "torso", "leg_near", "head" } },
  })
  equals(result.rest, 1, "rest frame defaults to 1")
  equals(result.created[1], "outline", "outline layer created")
  equals(result.created[2], "cape", "missing part created")
  equals(result.outline, INK, "outline color reported")
  check(type(result.restOutline) == "number" and result.restOutline > 0, "rest outline drawn")
  equals(stackNames(sprite), "body,outline,leg_far,torso,leg_near,head,cape,hat",
    "contiguous, bottom to top, outline lowest")
  local info = call("sprite.info")
  equals(info.rig.rest, 1, "sprite.info reports the rig")
  equals(info.rig.follows.hat, "head", "with its followers")
  equals(#info.rig.parts, 6, "and its parts")

  expectError("rig.define", { parts = { "head", "head" } }, "INVALID_PARAMS", "duplicate part")
  expectError("rig.define", { parts = { "head" }, follows = { hat = "head" } }, "INVALID_PARAMS",
    "a follower outside parts")
  expectError("rig.define", { parts = { "head", "hat" }, follows = { hat = "head", head = "hat" } },
    "INVALID_PARAMS", "follows loops")
  expectError("rig.define", { parts = { "head" }, outline = { color = INK, parts = { "torso" } } },
    "INVALID_PARAMS", "outline part outside parts")
  sprite:close()
end)

test("rig.pose builds from the rest frame, not the previous pose", function()
  local sprite = rigged()
  local first = call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  equals(first.frame, 2, "posed frame reported")
  equals(#first.posed, 5, "every part placed on a fresh frame")
  call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  equals(doc.resolveLayer(sprite, "torso"):cel(2).position.y, 5, "the same pose twice moves once")
  equals(px(sprite, "head", 2, 6, 2), SKIN, "unlisted parts sit at rest")

  local again = call("rig.pose", { frame = 2, parts = { head = { dx = 1 } } })
  equals(doc.resolveLayer(sprite, "torso"):cel(2).position.y, 5, "a listed-only update keeps the torso")
  equals(#again.posed, 2, "only the head and its follower were rewritten")
  equals(px(sprite, "hat", 2, 8, 1), GOLD, "the hat followed the head")

  call("rig.pose", { frame = 2, parts = { head = { dx = 2 } } })
  equals(px(sprite, "hat", 2, 9, 1), GOLD, "and follows it again when the head moves on")
  call("rig.pose", { frame = 2, parts = { hat = { dy = -1 } } })
  equals(px(sprite, "hat", 2, 9, 0), GOLD, "a follower's own offset is relative to its leader")

  expectError("rig.pose", { frame = 1, parts = {} }, "INVALID_FRAME", "the rest frame cannot be posed")
  expectError("rig.pose", { frame = 2, parts = { tail = { dx = 1 } } }, "INVALID_PARAMS", "unknown part")
  expectError("rig.pose", { frame = 2, parts = { head = { frame = 2 } } }, "INVALID_PARAMS",
    "a part cannot copy itself")
  sprite:close()
end)

test("rig.pose takes drawings from other frames and parts, recolored", function()
  local sprite = rigged()
  -- A new leg drawing on frame 2, drawn by hand: the passing leg.
  call("rig.pose", { frame = 2, parts = { leg_near = { hide = true } } })
  call("draw.pixels", { layer = "leg_near", frame = 2, pixels = {
    { x = 6, y = 8, color = BOOT }, { x = 6, y = 9, color = BOOT } } })
  local result = call("rig.pose", { frame = 3, parts = {
    leg_far = { frame = 2, layer = "leg_near", recolor = { [BOOT] = SHADE }, dx = -1 },
    leg_near = { frame = 2 },
  } })
  equals(px(sprite, "leg_far", 3, 5, 9), SHADE, "the far leg took the near leg's drawing, recolored")
  equals(px(sprite, "leg_near", 3, 6, 9), BOOT, "the near leg reused frame 2's drawing")
  equals(result.kept, nil, "nothing was kept on a fresh frame")

  local repose = call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  equals(repose.kept[1], "leg_near", "a hand-drawn part is kept when the frame is re-posed")
  equals(px(sprite, "leg_near", 2, 6, 8), BOOT, "with its pixels intact")
  local refreshed = call("rig.refresh", { force = true })
  equals(refreshed.kept, nil, "a drawing made over a hidden part is a source, not an edit")
  equals(px(sprite, "leg_near", 2, 6, 8), BOOT, "and even force leaves it alone")
  equals(px(sprite, "leg_far", 3, 5, 9), SHADE, "while the frame built from it is rebuilt")
  sprite:close()
end)

test("hidden parts stay hidden and duplicated frames start at rest", function()
  local sprite = rigged()
  call("rig.pose", { frame = 2, parts = { leg_far = { hide = true }, torso = { dy = 1 } } })
  call("rig.pose", { frame = 2, parts = { head = { dy = 1 } } })
  equals(px(sprite, "leg_far", 2, 5, 9), nil, "still hidden after another pose")
  call("frame.duplicate", { frame = 1 })
  local fresh = call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  equals(fresh.kept, nil, "copies of the rest frame are not mistaken for hand edits")
  equals(px(sprite, "hat", 2, 6, 1), GOLD, "and take the rest pose")
  sprite:close()
end)

test("rig.refresh rebuilds every pose after the rest drawing changes", function()
  local sprite = rigged()
  call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  call("rig.pose", { frame = 3, parts = { torso = { frame = 2, dx = 1 } } })
  call("draw.pixels", { layer = "torso", frame = 1, pixels = { { x = 5, y = 4, color = GOLD } } })
  local result = call("rig.refresh", {})
  check(result.updated >= 2, "posed cels were rebuilt: " .. tostring(result.updated))
  equals(px(sprite, "torso", 2, 5, 5), GOLD, "frame 2 shows the new rest drawing, still lowered")
  equals(px(sprite, "torso", 3, 6, 5), GOLD, "frame 3, chained through frame 2, too")

  call("draw.pixels", { layer = "head", frame = 2, pixels = { { x = 8, y = 2, color = INK } } })
  call("draw.pixels", { layer = "head", frame = 1, pixels = { { x = 6, y = 2, color = GOLD } } })
  local kept = call("rig.refresh", {})
  equals(kept.kept[1], "head@2", "a hand-edited posed cel is reported and kept")
  equals(px(sprite, "head", 2, 8, 2), INK, "its edit survives")
  call("rig.refresh", { force = true })
  equals(px(sprite, "head", 2, 8, 2), nil, "force rebuilds it from its recipe")
  equals(px(sprite, "head", 2, 6, 2), GOLD, "from the current rest drawing")
  sprite:close()
end)

test("the outline is redrawn around the silhouette on each pose", function()
  local sprite = rigged({ color = INK, parts = { "leg_far", "torso", "leg_near", "head" }, floor = 10 })
  equals(px(sprite, "outline", 1, 4, 5), INK, "left of the torso")
  equals(px(sprite, "outline", 1, 6, 1), INK, "above the head, under the hat")
  equals(px(sprite, "outline", 1, 5, 11), nil, "nothing below the floor")
  local result = call("rig.pose", { frame = 2, parts = { torso = { dx = -1 } } })
  check(type(result.outline) == "number" and result.outline > 0, "outline count reported")
  equals(px(sprite, "outline", 2, 3, 5), INK, "the outline moved with the torso")
  equals(px(sprite, "outline", 2, 4, 5), nil, "and left no ink inside the figure")

  call("draw.pixels", { layer = "outline", frame = 2, pixels = { { x = 0, y = 0, color = INK } } })
  local again = call("rig.pose", { frame = 2, parts = { torso = { dx = 0 } } })
  equals(again.outline, "kept", "a hand-edited outline is kept")
  sprite:close()
end)

test("a hand-drawn outline identical to the generated one is adopted", function()
  local sprite = figure()
  -- Draw the outline by hand first, exactly as the rig would.
  call("rig.define", { parts = { "leg_far", "torso", "leg_near", "head" },
    outline = { color = INK } })
  local generated = {}
  for y = 0, 15 do for x = 0, 15 do
    if px(sprite, "outline", 1, x, y) then generated[#generated + 1] = { x = x, y = y, color = INK } end
  end end
  call("draw.clearCel", { layer = "outline", frame = 1 })
  call("draw.pixels", { layer = "outline", frame = 1, pixels = generated })
  local adopted = call("rig.refresh", {})
  equals(adopted.outlinesKept, nil, "an identical hand outline is adopted, not reported")
  call("draw.pixels", { layer = "outline", frame = 1, pixels = { { x = 0, y = 0, color = INK } } })
  equals(call("rig.refresh", {}).outlinesKept[1], 1, "a different one is kept and reported")
  sprite:close()
end)

test("rig.pose reports the box and parts that came apart", function()
  local sprite = rigged()
  local result = call("rig.pose", { frame = 2, parts = { leg_near = { dx = 5 } } })
  equals(result.detached[1], "leg_near", "a leg moved off the body is detached")
  equals(result.box[1], 5, "box left")
  equals(result.box[2], 1, "box top, the hat included")
  local attached = call("rig.pose", { frame = 3, parts = { torso = { dy = 1 } } })
  equals(attached.detached, nil, "overlapping parts are attached")
  sprite:close()
end)

test("frame inserts and deletes renumber the rig", function()
  local sprite = rigged()
  call("rig.pose", { frame = 3, parts = { torso = { frame = 2 } } })
  call("frame.create", { after = 1 })
  local rec = doc.resolveLayer(sprite, "torso"):cel(4).properties("aseprite-mcp").pose
  equals(rec.src, 3, "the source frame moved with the insert")
  call("frame.delete", { frame = 2 })
  rec = doc.resolveLayer(sprite, "torso"):cel(3).properties("aseprite-mcp").pose
  equals(rec.src, 2, "and back with the delete")
  call("frame.delete", { frame = 1 })
  equals(call("sprite.info").rig.rest, 0, "deleting the rest frame clears it")
  expectError("rig.pose", { frame = 1, parts = {} }, "INVALID_FRAME",
    "and posing asks for define_rig again")
  sprite:close()
end)

test("inspect.region byLayer labels the anatomy", function()
  local sprite = rigged()
  local region = call("inspect.region", { x = 5, y = 1, width = 4, height = 10, frame = 1,
    byLayer = true })
  equals(region.source, "layers", "labelled by layer")
  equals(region.rows[1], ".HH.", "the hat shows over the head")
  equals(region.rows[2], ".hh.", "head")
  equals(region.rows[4], "tttt", "torso")
  equals(region.rows[8], "f.n.", "far and near legs, by their last word")
  equals(region.legend.n, "leg_near", "legend names the layers")
  equals(region.legend.H, "hat", "the higher of two initials takes the capital")
  expectError("inspect.region", { x = 0, y = 0, width = 1, height = 1, byLayer = true,
    layer = "head" }, "INVALID_PARAMS", "byLayer takes no layer")
  sprite:close()
end)

test("a walk in one batch is one undo step", function()
  local sprite = rigged()
  call("batch.run", { ops = {
    { command = "frame.create", params = {} },
    { command = "rig.pose", params = { frame = 2, parts = { torso = { dy = 1 }, head = { dy = 1 } } } },
    { command = "rig.pose", params = { frame = 4, parts = { leg_near = { dx = 1 } } } },
  } })
  equals(#sprite.frames, 4, "frame created inside the batch")
  equals(px(sprite, "hat", 2, 6, 2), GOLD, "hat followed inside the batch")
  call("history.undo", {})
  equals(#sprite.frames, 3, "one undo removes the frame")
  equals(doc.resolveLayer(sprite, "torso"):cel(2), nil, "and the poses")
  sprite:close()
end)

test("a rig survives save and reopen", function()
  local sprite = rigged({ color = INK })
  call("rig.pose", { frame = 2, parts = { torso = { dy = 1 } } })
  local path = tempPath("rig.aseprite")
  call("sprite.save", { path = path })
  sprite:close()
  local opened = call("sprite.open", { path = path })
  equals(opened.rig.parts[1], "leg_far", "rig read back")
  local result = call("rig.refresh", {})
  equals(result.kept, nil, "no posed cel looks hand-edited after a reload")
  equals(result.outlinesKept, nil, "nor any outline")
  app.sprite:close()
end)

print("=== rig templates ===")

--- The rigged figure with an idle (1-2) and a walk (3-5) whose passing leg is
-- drawn by hand on frame 4 and reused, recolored, on frame 5.
local function templateSource(follows)
  local sprite = figure()
  call("rig.define", {
    parts = { "leg_far", "torso", "leg_near", "head", "hat" },
    follows = follows == false and nil or { hat = "head" },
    outline = { color = INK, parts = { "leg_far", "torso", "leg_near", "head" } },
  })
  for _ = 1, 4 do call("frame.create", {}) end
  call("rig.pose", { frame = 2, parts = { torso = { dy = 1 }, head = { dy = 1 },
    hat = follows == false and { dy = 1 } or nil } })
  call("rig.pose", { frame = 3, parts = {} })
  call("rig.pose", { frame = 4, parts = { leg_near = { hide = true }, torso = { dy = -1 },
    head = { dy = -1 }, hat = follows == false and { dy = -1 } or nil } })
  call("draw.pixels", { layer = "leg_near", frame = 4, pixels = {
    { x = 6, y = 8, color = BOOT }, { x = 6, y = 9, color = BOOT } } })
  -- A hand drawing changes the silhouette; the outline follows on the next
  -- pose or refresh of that frame, as an agent would do.
  call("rig.refresh", { frames = { 4 } })
  call("rig.pose", { frame = 5, parts = { leg_near = { frame = 4 },
    leg_far = { frame = 4, layer = "leg_near", recolor = { [BOOT] = SHADE }, dx = -1 } } })
  call("tag.create", { name = "idle", from = 1, to = 2 })
  call("tag.create", { name = "walk", from = 3, to = 5, direction = "pingpong" })
  for f, ms in ipairs({ 300, 300, 80, 80, 80 }) do
    call("frame.setDuration", { frame = f, durationMs = ms })
  end
  return sprite
end

--- The same figure, rest frame only. `torsoMark` adds a pixel to its torso, so
-- its rest drawing no longer matches the template's.
local function templateTarget(torsoMark, follows)
  local sprite = figure()
  if torsoMark then
    call("draw.pixels", { layer = "torso", frame = 1, pixels = { { x = 5, y = 4, color = GOLD } } })
  end
  call("rig.define", {
    parts = { "leg_far", "torso", "leg_near", "head", "hat" },
    follows = follows == false and nil or { hat = "head" },
    outline = { color = INK, parts = { "leg_far", "torso", "leg_near", "head" } },
  })
  return sprite
end

local function composite(sprite, f)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:clear(0)
  image:drawSprite(sprite, f)
  return image
end

local function exportFrom(sprite, tags)
  app.sprite = sprite
  return call("rig.exportPoses", { tags = tags }).template
end

local function importInto(sprite, template, extra)
  app.sprite = sprite
  local params = { template = template }
  for k, v in pairs(extra or {}) do params[k] = v end
  return call("rig.importPoses", params)
end

test("rig.exportPoses stores the layout, the poses and the hand drawings", function()
  local source = templateSource()
  local reply = call("rig.exportPoses", {})
  local t = reply.template
  equals(reply.frames, 5, "every tagged frame")
  equals(reply.drawn, 1, "one hand-drawn part")
  equals(t.format, "aseprite-mcp-poses", "format named")
  equals(t.rest, 1, "rest frame")
  equals(t.frames[1].rest, true, "the rest frame is marked, not posed")
  equals(t.frames[2].parts.torso.dy, 1, "idle drops the torso")
  equals(t.frames[2].parts.hat.dy, 1, "a follower is stored where it ended up")
  check(t.frames[4].parts.leg_near.drawn ~= nil, "the passing leg is stored as a drawing")
  equals(t.frames[4].parts.leg_near.drawn.rows[1], "a", "as rows")
  equals(t.frames[4].parts.leg_near.drawn.legend.a, BOOT, "with a legend")
  local far = t.frames[5].parts.leg_far
  equals(far.frame, 4, "a source frame stays a frame number")
  equals(far.layer, "leg_near", "with its source part")
  equals(far.recolor[BOOT], SHADE, "and its recolor")
  equals(t.tags[2].direction, "pingpong", "tag direction kept")
  check(t.restHashes.torso ~= nil, "rest drawings fingerprinted")
  expectError("rig.exportPoses", { tags = { "run" } }, "INVALID_PARAMS", "unknown tag")
  source:close()
end)

test("rig.importPoses rebuilds the animation pixel for pixel on the same body", function()
  local source = templateSource()
  local template = exportFrom(source)
  local target = templateTarget()
  local reply = importInto(target, template)
  equals(#target.frames, 5, "four frames added to the rest frame")
  equals(reply.tags[1].from, 1, "idle starts on the target's own rest frame")
  equals(reply.tags[2].from, 3, "walk follows it")
  equals(reply.copied[1], "leg_near@4", "the passing leg was copied: same leg at rest")
  equals(reply.toDraw, nil, "nothing left to draw")
  for f = 1, 5 do
    check(composite(target, f):isEqual(composite(source, f)), "frame " .. f .. " matches")
  end
  equals(target.tags[2].aniDir, AniDir.PING_PONG, "tag direction")
  equals(doc.msFromSeconds(target.frames[4].duration), 80, "durations")
  expectError("rig.importPoses", { template = template }, "INVALID_PARAMS", "a tag clash")
  call("history.undo", {})
  equals(#target.frames, 1, "one undo removes the whole import")
  equals(#target.tags, 0, "and its tags")
  source:close()
  target:close()
end)

test("a part that differs keeps its own drawing and its hand drawings are listed", function()
  local source = templateSource()
  local template = exportFrom(source)
  local target = templateTarget(true)
  local reply = importInto(target, template)
  equals(px(target, "torso", 2, 5, 5), GOLD, "the target's own torso, lowered by the idle")
  equals(px(target, "leg_near", 4, 6, 9), BOOT, "the shared leg drawing was copied")
  source:close()
  target:close()

  local skipSource = templateSource()
  local skipTarget = templateTarget()
  local skipped = importInto(skipTarget, exportFrom(skipSource), { drawings = "skip" })
  equals(skipped.toDraw[1], "leg_near@4", "skip leaves the passing leg to draw")
  equals(px(skipTarget, "leg_near", 4, 6, 9), nil, "hidden until drawn")
  call("draw.pixels", { layer = "leg_near", frame = 4, pixels = { { x = 6, y = 9, color = BOOT } } })
  call("rig.refresh", {})
  equals(px(skipTarget, "leg_near", 5, 6, 9), BOOT, "drawing it reaches the frames that reuse it")
  skipSource:close()
  skipTarget:close()
end)

test("templates survive a different rig: follows, extra and missing parts", function()
  local source = templateSource(false)
  local template = exportFrom(source)
  local target = templateTarget(false, true)
  importInto(target, template)
  for f = 1, 5 do
    check(composite(target, f):isEqual(composite(source, f)),
      "frame " .. f .. " matches though only the target's hat follows its head")
  end
  source:close()
  target:close()

  local other = templateSource()
  local t = exportFrom(other)
  local cape = figure()
  call("rig.define", { parts = { "leg_far", "torso", "leg_near", "head", "cape" } })
  local reply = importInto(cape, t, { tags = { "idle" } })
  equals(reply.ignoredParts[1], "hat", "a template part the target lacks is reported")
  equals(reply.restPoseParts[1], "cape", "a target part the template lacks stays at rest")
  other:close()
  cape:close()
end)

test("references outside the chosen tags are refused, at both ends", function()
  local source = templateSource()
  call("rig.pose", { frame = 5, parts = { torso = { frame = 2 } } })
  expectError("rig.exportPoses", { tags = { "walk" } }, "INVALID_PARAMS",
    "walk takes a drawing from idle")
  local full = call("rig.exportPoses", {}).template
  local target = templateTarget()
  app.sprite = target
  expectError("rig.importPoses", { template = full, tags = { "walk" } }, "INVALID_PARAMS",
    "importing walk without idle")
  expectError("rig.importPoses", { template = full, tags = { "jump" } }, "INVALID_PARAMS",
    "unknown tag")
  expectError("rig.importPoses", { template = { format = "other" } }, "INVALID_PARAMS",
    "not a template")
  source:close()
  target:close()
end)

print("=== wire path ===")
test("empty arrays encode as [] on the wire", function()
  -- Caught live: the encoder spaces the placeholder differently from the
  -- pattern that rewrites it, so empty lists reached the server as objects.
  local proto = core.proto
  local text = proto.encode({ tags = proto.array({}), nested = { list = proto.array({}) } })
  check(text:find("__emptyArray") == nil, "no placeholder leaks: " .. text)
  local decoded = json.decode(text)
  equals(#decoded.tags, 0, "tags decode as an empty list")
  check(text:find('"tags":%s*%[%]') ~= nil, "tags is []")
  local sprite = newSprite(4, 4)
  local wire = proto.successMessage(1, call("sprite.info"))
  check(wire:find("__emptyArray") == nil, "a real sprite.info reply has no placeholder")
  sprite:close()
end)

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

--- A command as the socket delivers it. Numbers decode to floats there, which a
--- direct handler call with integers never shows.
local function sendCommand(command, params)
  return sendRaw(json.encode({ id = 20, command = command, params = params }))
end

test("sprite sheets survive the wire path", function()
  local base = #app.sprites
  local sheet = writeSheet("wire_sheet.png")
  local out = tempPath("wire_out.png")

  local imported = sendCommand("sprite.importSheet", {
    path = sheet, frameWidth = 2, frameHeight = 2, x = 0, y = 0,
  })
  equals(imported.ok, true, "import accepted decoded params")
  equals(#imported.result.frameMs, 6, "one frame per cell")
  equals(imported.result.sheet.columns, 3, "columns")
  equals(imported.result.sheet.emptyFrames[1], 5, "the empty cell")
  equals(app.sprite.layers[1]:cel(6).image:getPixel(0, 0), cellColor(2, 1), "the last cell")

  local exported = sendCommand("sprite.exportSheet", { path = out, columns = 3 })
  equals(exported.ok, true, "export accepted decoded params")
  equals(exported.result.rows, 2, "rows")
  check(fsio.readPng(out).bytes == sheetImage().bytes, "the round trip is exact")

  local pasted = sendCommand("sprite.exportSheet", {
    path = out, onto = out, columns = 3, x = 0, y = 0,
  })
  equals(pasted.ok, true, "export onto accepted decoded params")
  equals(pasted.result.changedPixels, 0, "pasting the same frames changes nothing")

  local area = sendCommand("sprite.importSheet", {
    path = sheet, frameWidth = 2, frameHeight = 2, x = 2, y = 2, columns = 2, rows = 1,
  })
  equals(area.ok, true, "an area accepted decoded params")
  equals(#area.result.frameMs, 2, "only that area")
  equals(app.sprite.layers[1]:cel(2).image:getPixel(0, 0), cellColor(2, 1), "offset from x,y")

  local pastedArea = sendCommand("sprite.exportSheet", {
    path = out, onto = sheet, columns = 2, x = 2, y = 2,
  })
  equals(pastedArea.ok, true, "a block at x,y accepted decoded params")
  equals(pastedArea.result.changedPixels, 0, "and landed on its own cells")
  closeAbove(base)
end)

test("a sheet error reads well over the wire path", function()
  -- %d in these messages takes decoded numbers, which are floats.
  local base = #app.sprites
  local sheet = writeSheet("wire_nofit.png")
  local reply = sendCommand("sprite.importSheet", {
    path = sheet, frameWidth = 2, frameHeight = 2, columns = 9,
  })
  equals(reply.ok, false, "too many columns is refused")
  check(reply.error.message:find("At most 3 x 2", 1, true) ~= nil, "names what fits: " .. reply.error.message)
  closeAbove(base)
end)

test("opening an open file survives the wire path", function()
  local base = #app.sprites
  local path = writeSheet("wire_open.png")
  local first = sendCommand("sprite.open", { path = path })
  equals(first.ok, true, "the first open works")
  newSprite(4, 4)
  local second = sendCommand("sprite.open", { path = path })
  equals(second.ok, true, "the second open works")
  equals(second.result.alreadyOpen, true, "and says it found the tab")
  closeAbove(base)
end)

test("a pathless save survives the wire path", function()
  local out = tempPath("wire_expected.aseprite")
  local sprite = newSprite(8, 8)
  call("sprite.save", { path = out })
  local own = sprite.filename
  local reply = sendCommand("sprite.save", { expectedPath = own })
  equals(reply.ok, true, "a matching expectedPath saves")
  equals(reply.result.savedTo, own, "to the document's own file")
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

test("instance: one id per process, sent in the status", function()
  local id = ws.instanceId()
  check(type(id) == "string" and id:match("^%x%x%x%x%x%x$") ~= nil, "six hex characters: " .. tostring(id))
  equals(ws.instanceId(), id, "stable across calls")
  equals(ws.status().instance, id, "reported in the status the dialog reads")
  local other = dofile(app.fs.joinPath(EXT_DIR, "ws.lua"))({ queue = queue, trace = noTrace })
  check(other.instanceId() ~= id, "another module instance gets another id")
end)

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

test("view model: the instance row names this window", function()
  equals(vm({ instance = "a1b2c3" }).instanceText, "a1b2c3", "the id alone")
  equals(vm({ instance = "a1b2c3", instanceName = "knight" }).instanceText, "knight (a1b2c3)",
    "a name from ASEPRITE_MCP_INSTANCE leads")
  equals(dialog.displayText(vm({ instance = "a1b2c3" })).instance, "a1b2c3", "shown as is")
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
