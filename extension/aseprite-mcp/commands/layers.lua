-- Layer commands (spec section 9).

return function(deps)
  local proto, doc = deps.proto, deps.doc
  local M = {}

  M["layer.select"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.resolveLayer(sprite, params.layer)
    app.layer = layer
    return { id = doc.shortId(sprite, layer), name = layer.name }
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
      id = doc.shortId(sprite, created),
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
    local name = layer.name
    app.transaction("mcp: delete layer", function()
      sprite:deleteLayer(layer)
    end)
    return { deleted = name, layerCount = #doc.allLayers(sprite) }
  end

  M["layer.setVisibility"] = function(params)
    local sprite = doc.activeSprite()
    local layer = doc.resolveLayer(sprite, params.layer)
    if type(params.visible) ~= "boolean" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "visible must be true or false.")
    end
    layer.isVisible = params.visible
    return { id = doc.shortId(sprite, layer), name = layer.name, visible = layer.isVisible }
  end

  return M
end
