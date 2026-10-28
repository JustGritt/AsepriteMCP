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
  M["sprite.info"] = function()
    local sprite = doc.activeSprite()
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

    return {
      filename = app.fs.fileName(sprite.filename),
      path = sprite.filename,
      width = sprite.width,
      height = sprite.height,
      colorMode = doc.colorModeName(sprite.colorMode),
      frameCount = #sprite.frames,
      layerCount = #doc.allLayers(sprite),
    }
  end

  M["sprite.save"] = function(params)
    local sprite = doc.activeSprite()
    local path = params.path

    if path == nil or path == "" then
      if sprite.filename == nil or sprite.filename == "" then
        proto.fail(
          proto.ERROR.INVALID_PARAMS,
          "This sprite has never been saved, so there is no file to save over. "
            .. "Pass a path inside an allowed directory."
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
