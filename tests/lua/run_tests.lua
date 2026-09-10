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
  equals(info.frameCount, 1, "frame count")
  equals(info.layerCount, 1, "layer count")
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
test("layer create, list, select, delete", function()
  local sprite = newSprite()
  local created = call("layer.create", { name = "Character" })
  check(created.uuid ~= nil, "new layer has a uuid")
  equals(created.name, "Character", "new layer name")

  local list = call("layer.list")
  equals(list.count, 2, "two layers after create")

  local selected = call("layer.select", { layer = created.uuid })
  equals(selected.name, "Character", "select by uuid")

  local byName = call("layer.select", { layer = "Character" })
  equals(byName.name, "Character", "select by name")

  local visibility = call("layer.setVisibility", { layer = created.uuid, visible = false })
  equals(visibility.visible, false, "hide layer")

  call("layer.delete", { layer = created.uuid })
  equals(call("layer.list").count, 1, "one layer after delete")
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
  equals(call("frame.list").frames[1].durationMs, 80, "reads back as 80ms")
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
  equals(first.celBounds.width, 1, "cel starts 1px wide")

  local second = call("draw.pixels", { pixels = { { x = 9, y = 4, color = "#e6a15c" } } })
  equals(second.written, 1, "wrote a second pixel")
  equals(second.celBounds.width, 6, "cel grew to span both pixels")
  equals(second.celBounds.x, 4, "cel origin stayed at the first pixel")

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
  equals(line.length, 6, "six pixels along the run")
  equals(line.written, 6, "all written")

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
  equals(pal.size, 4, "palette size")
  equals(pal.colorMode, "indexed", "color mode reported")
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
  equals(region.legend["."], "#00000000", "dot means transparent")
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
  call("draw.pixels", { pixels = { { x = 1, y = 1, color = "#00ff00ff" } }, layer = top.uuid })
  local out = tempPath("layer.png")
  local result = call("render.layer", { layer = top.uuid, scale = 2, outPath = out })
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
  equals(result.columns, 3, "single row by default")
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

  equals(call("tag.list").count, 1, "one tag listed")

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
  equals(call("tag.list").count, 0, "tag deleted")
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
  equals(call("layer.list").count, 2, "layer added")

  call("history.undo")
  equals(call("layer.list").count, 1, "undo removed the layer only")

  local region = call("inspect.region", { x = 1, y = 1, width = 1, height = 1 })
  check(region.rows[1] ~= ".", "the earlier pixel survived the undo")

  call("history.redo")
  equals(call("layer.list").count, 2, "redo restored the layer")
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
