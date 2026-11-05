-- Sprite-level commands (spec section 8).

return function(deps)
  local proto, doc = deps.proto, deps.doc
  local fsio = deps.fsio
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

  M["sprite.open"] = function(params)
    local path = params.path
    if type(path) ~= "string" or path == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "A path is required.")
    end
    if not fsio.exists(path) then
      proto.failf(proto.ERROR.INVALID_PARAMS, "No such file: %s", path)
    end

    local sprite = fsio.openSprite(path)
    if not sprite then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Aseprite could not open %s. It may be corrupt or in an unsupported format.", path
      )
    end
    -- app.open usually activates the document already; make it explicit so the
    -- next command cannot land on whatever was previously in front.
    pcall(function() app.sprite = sprite end)
    return overview(sprite)
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

  return M
end
