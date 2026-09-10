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

  M["sprite.info"] = function()
    local sprite = doc.activeSprite()
    local activeLayer = app.layer
    return {
      filename = app.fs.fileName(sprite.filename),
      path = sprite.filename,
      width = sprite.width,
      height = sprite.height,
      colorMode = doc.colorModeName(sprite.colorMode),
      frameCount = #sprite.frames,
      layerCount = #doc.allLayers(sprite),
      tagCount = #sprite.tags,
      paletteSize = #sprite.palettes[1],
      activeFrame = app.frame and app.frame.frameNumber or nil,
      activeLayer = activeLayer and activeLayer.name or nil,
      activeLayerId = activeLayer and doc.layerId(activeLayer) or nil,
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
