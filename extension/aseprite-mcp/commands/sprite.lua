-- Sprite-level commands (spec section 8).

return function(deps)
  local proto, doc = deps.proto, deps.doc
  local fsio, render, rigstore = deps.fsio, deps.render, deps.rigstore
  local M = {}

  --- Cheap liveness/status probe used by get_connection_status.
  M["app.status"] = function()
    local sprite = app.sprite
    return {
      documentOpen = sprite ~= nil,
      document = sprite and app.fs.fileName(sprite.filename) or nil,
      documentPath = sprite and sprite.filename or nil,
      openDocuments = #app.sprites,
    }
  end

  --- Everything the agent needs before editing, in one compact reply.
  -- This replaces separate layer, frame and tag listings: each listing was one
  -- more model turn re-reading the whole context. Fields at their usual value
  -- (visible, opaque, forward, looping) are left out rather than repeated.
  -- sprite.open and sprite.new return it too, so no read has to follow them.
  --- The rig, if the file has one, so a new session finds it without asking.
  local function rigSummary(sprite)
    local rig = rigstore.load(sprite)
    if not rig then return nil end
    return {
      rest = rig.rest,
      parts = proto.array(rig.parts),
      follows = next(rig.follows) and rig.follows or nil,
      outline = rig.outline and rig.outline.color or nil,
    }
  end

  local function overview(sprite)
    local active = app.layer

    local layers = {}
    for _, entry in ipairs(doc.allLayers(sprite)) do
      local layer = entry.layer
      layers[#layers + 1] = {
        id = doc.shortId(sprite, layer),
        name = layer.name,
        type = (layer.isGroup and "group") or (layer.isTilemap and "tilemap") or nil,
        hidden = (not layer.isVisible) or nil,
        locked = (not layer.isEditable) or nil,
        opacity = (not layer.isGroup and layer.opacity ~= 255) and layer.opacity or nil,
        background = layer.isBackground or nil,
        depth = entry.depth > 0 and entry.depth or nil,
        parent = entry.parent,
      }
    end

    local durations = {}
    for i, frame in ipairs(sprite.frames) do durations[i] = doc.msFromSeconds(frame.duration) end

    local tags = {}
    for _, tag in ipairs(sprite.tags) do
      local direction = doc.directionName(tag.aniDir)
      tags[#tags + 1] = {
        name = tag.name,
        from = tag.fromFrame.frameNumber,
        to = tag.toFrame.frameNumber,
        direction = direction ~= "forward" and direction or nil,
        repeats = tag.repeats ~= 0 and tag.repeats or nil,
      }
    end

    return {
      path = sprite.filename,
      width = sprite.width,
      height = sprite.height,
      colorMode = doc.colorModeName(sprite.colorMode),
      paletteSize = #sprite.palettes[1],
      activeFrame = app.frame and app.frame.frameNumber or nil,
      activeLayer = active and (doc.shortId(sprite, active) or active.name) or nil,
      layers = proto.array(layers),
      frameMs = proto.array(durations),
      tags = proto.array(tags),
      rig = rigSummary(sprite),
    }
  end

  M["sprite.info"] = function()
    return overview(doc.activeSprite())
  end

  local COLOR_MODES = { rgb = ColorMode.RGB, grayscale = ColorMode.GRAY, indexed = ColorMode.INDEXED }

  M["sprite.new"] = function(params)
    local width, height = params.width, params.height
    if type(width) ~= "number" or type(height) ~= "number" or width < 1 or height < 1 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "width and height must be positive whole numbers.")
    end
    local mode = COLOR_MODES[params.colorMode or "rgb"]
    if not mode then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "colorMode must be rgb, grayscale or indexed, got %q.", tostring(params.colorMode))
    end

    local sprite = Sprite(math.floor(width), math.floor(height), mode)
    pcall(function() app.sprite = sprite end)
    if params.path then
      if not fsio.saveSprite(sprite, params.path) then
        proto.failf(
          proto.ERROR.LUA_ERROR,
          "Created the sprite but could not write %s. Check that scripts have "
            .. "file-system access; see docs/SETUP.md.", params.path
        )
      end
    end
    return overview(sprite)
  end

  --- What two spellings of one path have in common. Windows ignores case.
  local function fileKey(path)
    local normal = app.fs.normalizePath(path)
    return app.os.windows and normal:lower() or normal
  end

  --- The tab already holding this file, preferring the one in front.
  local function openTab(path)
    local key = fileKey(path)
    local active = app.sprite
    if active and fileKey(active.filename) == key then return active end
    for _, sprite in ipairs(app.sprites) do
      if fileKey(sprite.filename) == key then return sprite end
    end
    return nil
  end

  M["sprite.open"] = function(params)
    local path = params.path
    if type(path) ~= "string" or path == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "A path is required.")
    end
    if not fsio.exists(path) then
      proto.failf(proto.ERROR.INVALID_PARAMS, "No such file: %s", path)
    end

    -- Opening it again would make a second tab with the file's pixels, and the
    -- agent would edit a different document from the one the user is looking at.
    -- The tab wins over the file, because it may hold the user's unsaved work.
    local tab = openTab(path)
    local sprite = tab or fsio.openSprite(path)
    if not sprite then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Aseprite could not open %s. It may be corrupt or in an unsupported format.", path
      )
    end
    -- Opening usually activates the document already; make it explicit so the
    -- next command cannot land on whatever was previously in front.
    pcall(function() app.sprite = sprite end)
    local reply = overview(sprite)
    if tab then
      reply.alreadyOpen = true
      reply.unsaved = tab.isModified or nil
    end
    return reply
  end

  M["sprite.save"] = function(params)
    local sprite = doc.activeSprite()
    local path = params.path

    if path == nil or path == "" then
      -- The server vetted expectedPath, not whichever tab is in front now. Saving
      -- without this check would let a tab switch redirect the write.
      local expected = params.expectedPath
      if expected == nil or expected == "" then
        proto.fail(proto.ERROR.INVALID_PARAMS, "sprite.save needs a path or an expectedPath.")
      end
      if sprite.filename ~= expected then
        proto.failf(
          proto.ERROR.INVALID_PARAMS,
          "The active document changed to %s during the save, so nothing was written. "
            .. "Check it is the one you meant, then save again.", sprite.filename
        )
      end
      path = sprite.filename
    end

    if not fsio.saveSprite(sprite, path) then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Aseprite reported no error but %s was not written. Check that scripts have "
          .. "file-system access; see docs/SETUP.md.", path
      )
    end
    return { path = sprite.filename, savedTo = path }
  end

  -- Past these, the numbers are a mistake in the frame size, not a real sheet.
  local MAX_SHEET_FRAMES = 1024
  local MAX_SHEET_EDGE = 8192

  M["sprite.importSheet"] = function(params)
    local frameW, frameH = params.frameWidth, params.frameHeight
    local x, y = params.x or 0, params.y or 0

    local source, palette = fsio.readPng(params.path)
    if not source then
      proto.failf(proto.ERROR.LUA_ERROR, "Could not read %s: %s", params.path, palette)
    end

    local spareW, spareH = source.width - x, source.height - y
    local fitColumns, fitRows = spareW // frameW, spareH // frameH
    if fitColumns < 1 or fitRows < 1 then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "A %dx%d frame at (%d,%d) does not fit in this %dx%d sheet.",
        frameW, frameH, x, y, source.width, source.height)
    end
    local columns, rows = params.columns or fitColumns, params.rows or fitRows
    if columns > fitColumns or rows > fitRows then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "%d columns x %d rows of %dx%d frames at (%d,%d) do not fit in this %dx%d sheet. "
          .. "At most %d x %d do.",
        columns, rows, frameW, frameH, x, y, source.width, source.height, fitColumns, fitRows)
    end
    local count = columns * rows
    if count > MAX_SHEET_FRAMES then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "That makes %d frames, and the limit is %d. Check the frame size.",
        count, MAX_SHEET_FRAMES)
    end

    -- A new document, not ImportSpriteSheet on an opened one: that keeps the
    -- PNG's filename, so a later save would write numbered PNGs beside it, and it
    -- always runs to the bottom of the sheet.
    local sprite = Sprite(frameW, frameH, ColorMode.RGB)
    pcall(function() app.sprite = sprite end)
    local layer = sprite.layers[1]
    local empty = {}
    -- After the document is active, so this is its one undo step.
    app.transaction("mcp: import sprite sheet", function()
      sprite:setPalette(palette)
      layer.name = "sheet"
      for _ = 2, count do sprite:newEmptyFrame() end
      for frame = 1, count do
        local col, row = (frame - 1) % columns, (frame - 1) // columns
        local cell = Image(source, Rectangle(x + col * frameW, y + row * frameH, frameW, frameH))
        if cell:isEmpty() then
          -- Stays in the order, because a game addresses frames by their position.
          empty[#empty + 1] = frame
        else
          sprite:newCel(layer, frame, cell, Point(0, 0))
        end
      end
    end)
    pcall(function()
      app.frame = sprite.frames[1]
      app.layer = layer
    end)

    local reply = overview(sprite)
    reply.sheet = { columns = columns, rows = rows, emptyFrames = proto.array(empty) }
    local leftW = not params.columns and spareW % frameW or 0
    local leftH = not params.rows and spareH % frameH or 0
    if leftW > 0 or leftH > 0 then
      reply.warning = string.format(
        "%dx%d frames left %d px across and %d px down unused. If the sheet is not one "
          .. "grid, import each area with x, y, columns and rows.",
        frameW, frameH, leftW, leftH)
    end
    return reply
  end

  --- Number of pixels that differ between two images of the same size.
  local function changedPixels(a, b)
    if a.bytes == b.bytes then return 0 end
    local count = 0
    for py = 0, a.height - 1 do
      for px = 0, a.width - 1 do
        if a:getPixel(px, py) ~= b:getPixel(px, py) then count = count + 1 end
      end
    end
    return count
  end

  M["sprite.exportSheet"] = function(params)
    local sprite = doc.activeSprite()

    local first, last = 1, #sprite.frames
    if params.tag then
      local tag = nil
      for _, candidate in ipairs(sprite.tags) do
        if candidate.name == params.tag then tag = candidate end
      end
      if not tag then
        proto.failf(proto.ERROR.INVALID_PARAMS, "No tag named %q in this sprite.", params.tag)
      end
      first, last = tag.fromFrame.frameNumber, tag.toFrame.frameNumber
    end
    local count = last - first + 1

    local columns = params.columns or count
    if columns < 1 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "columns must be at least 1.")
    end
    local rows = math.ceil(count / columns)
    local frameW, frameH = sprite.width, sprite.height
    local blockW, blockH = columns * frameW, rows * frameH
    local x, y = params.x or 0, params.y or 0

    local sheet
    if params.onto then
      local why
      sheet, why = fsio.readPng(params.onto)
      if not sheet then
        proto.failf(proto.ERROR.LUA_ERROR, "Could not read %s: %s", params.onto, why)
      end
      if x + blockW > sheet.width or y + blockH > sheet.height then
        proto.failf(proto.ERROR.INVALID_PARAMS,
          "%d frames in %d columns need %dx%d at (%d,%d), which does not fit in this "
            .. "%dx%d sheet.",
          count, columns, blockW, blockH, x, y, sheet.width, sheet.height)
      end
    else
      if blockW > MAX_SHEET_EDGE or blockH > MAX_SHEET_EDGE then
        proto.failf(proto.ERROR.INVALID_PARAMS,
          "That makes a %dx%d sheet, and the limit is %d per side. Set columns.",
          blockW, blockH, MAX_SHEET_EDGE)
      end
      sheet = Image(blockW, blockH, ColorMode.RGB)
      sheet:clear(app.pixelColor.rgba(0, 0, 0, 0))
    end

    local changed = 0
    for frame = first, last do
      local index = frame - first
      local cellX = x + (index % columns) * frameW
      local cellY = y + (index // columns) * frameH
      local cell = render.compositeFrame(sprite, frame)
      if params.onto then
        changed = changed + changedPixels(
          Image(sheet, Rectangle(cellX, cellY, frameW, frameH)), cell)
      end
      -- SRC replaces the cell. The default blends, so an erased pixel would keep
      -- what was under it and a partly transparent one would mix with it.
      sheet:drawImage(cell, Point(cellX, cellY), 255, BlendMode.SRC)
    end

    if not fsio.saveImage(sheet, params.path) then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Aseprite reported no error but %s was not written. Check that scripts have "
          .. "file-system access; see docs/SETUP.md.", params.path
      )
    end
    return {
      path = params.path,
      width = sheet.width,
      height = sheet.height,
      frames = count,
      columns = columns,
      rows = rows,
      changedPixels = params.onto and changed or nil,
    }
  end

  return M
end
