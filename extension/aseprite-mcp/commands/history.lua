-- Undo and redo (spec section 15).
--
-- These drive the native document history. Because every mutating command runs
-- inside exactly one app.transaction, one undo reverses one MCP call.

return function(deps)
  local doc = deps.doc
  local M = {}

  M["history.undo"] = function()
    local sprite = doc.activeSprite()
    app.undo()
    app.refresh()
    return {
      undone = true,
      frameCount = #sprite.frames,
      layerCount = #doc.allLayers(sprite),
      note = "Aseprite does not report whether anything was actually on the undo "
        .. "stack. Preview the result to confirm the document is as you expect.",
    }
  end

  M["history.redo"] = function()
    local sprite = doc.activeSprite()
    app.redo()
    app.refresh()
    return {
      redone = true,
      frameCount = #sprite.frames,
      layerCount = #doc.allLayers(sprite),
    }
  end

  return M
end
