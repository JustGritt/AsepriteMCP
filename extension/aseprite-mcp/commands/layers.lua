-- Layer commands (spec section 9).

return function(deps)
  local proto, doc = deps.proto, deps.doc
  local M = {}

  M["layer.list"] = function()
    local sprite = doc.activeSprite()
    local active = app.layer
    local layers = {}
    for _, entry in ipairs(doc.allLayers(sprite)) do
      local layer = entry.layer
      local kind = "image"
      if layer.isGroup then
        kind = "group"
      elseif layer.isTilemap then
        kind = "tilemap"
      end
      layers[#layers + 1] = {
        uuid = doc.layerId(layer),
        name = layer.name,
        type = kind,
        visible = layer.isVisible,
        editable = layer.isEditable,
        opacity = layer.isGroup and nil or layer.opacity,
        isBackground = layer.isBackground or false,
        depth = entry.depth,
        parent = entry.parent,
        active = (active ~= nil and layer == active),
      }
    end
    return { layers = proto.array(layers), count = #layers }
  end

  M["layer.select"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.resolveLayer(sprite, params.layer)
    app.layer = layer
    return { uuid = doc.layerId(layer), name = layer.name }
  end

  M["layer.create"] = function(params)
    local sprite = doc.activeSprite()
    local name = params.name
    if type(name) ~= "string" or name == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "A layer name is required.")
    end

    local created
    app.transaction("mcp: create layer", function()
      created = sprite:newLayer()
      created.name = name
    end)
    app.layer = created
    return {
      uuid = doc.layerId(created),
      name = created.name,
      stackIndex = created.stackIndex,
    }
  end

  M["layer.delete"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.resolveLayer(sprite, params.layer)
    if #sprite.layers == 1 and not layer.isGroup then
      proto.fail(
        proto.ERROR.INVALID_LAYER,
        "Refusing to delete the only top-level layer; a sprite must keep at least one."
      )
    end
    local name, uuid = layer.name, doc.layerId(layer)
    app.transaction("mcp: delete layer", function()
      sprite:deleteLayer(layer)
    end)
    return { deleted = name, uuid = uuid, layerCount = #doc.allLayers(sprite) }
  end

  M["layer.setVisibility"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.resolveLayer(sprite, params.layer)
    if type(params.visible) ~= "boolean" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "visible must be true or false.")
    end
    layer.isVisible = params.visible
    return { uuid = doc.layerId(layer), name = layer.name, visible = layer.isVisible }
  end

  return M
end
