-- Frame commands (spec section 10).
--
-- Two insertion quirks, both verified against Aseprite 1.3.18 rather than
-- assumed from the docs:
--
--   sprite:newFrame(n)      duplicates frame n and inserts the copy at n+1
--   sprite:newEmptyFrame(n) inserts an empty frame AT n, pushing later frames right
--
-- Neither returns a reliable frameNumber for the frame it created, so the new
-- index is computed rather than read back.
--
-- A rig names frames by number (its rest frame, and each pose's source), so
-- every insert and delete here renumbers it in the same transaction.

return function(deps)
  local proto, doc, rigstore = deps.proto, deps.doc, deps.rigstore
  local M = {}

  M["frame.select"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    app.frame = sprite.frames[frameNumber]
    return { frame = frameNumber }
  end

  M["frame.create"] = function(params)
    local sprite = doc.activeSprite()
    local position
    if params.after == nil then
      position = #sprite.frames + 1
    else
      position = doc.resolveFrame(sprite, params.after) + 1
    end

    app.transaction("mcp: create frame", function()
      sprite:newEmptyFrame(position)
      rigstore.onInsert(sprite, position)
    end)
    app.frame = sprite.frames[position]
    return {
      frame = position,
      durationMs = doc.msFromSeconds(sprite.frames[position].duration),
      frameCount = #sprite.frames,
    }
  end

  M["frame.duplicate"] = function(params)
    local sprite = doc.activeSprite()
    local source = doc.resolveFrame(sprite, params.frame)

    app.transaction("mcp: duplicate frame", function()
      sprite:newFrame(source)
      rigstore.onInsert(sprite, source + 1)
    end)

    local created = source + 1
    app.frame = sprite.frames[created]
    return {
      frame = created,
      copiedFrom = source,
      durationMs = doc.msFromSeconds(sprite.frames[created].duration),
      frameCount = #sprite.frames,
    }
  end

  M["frame.delete"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    if #sprite.frames == 1 then
      proto.fail(
        proto.ERROR.INVALID_FRAME,
        "Refusing to delete the only frame; a sprite must keep at least one."
      )
    end
    app.transaction("mcp: delete frame", function()
      sprite:deleteFrame(frameNumber)
      rigstore.onDelete(sprite, frameNumber)
    end)
    return { deleted = frameNumber, frameCount = #sprite.frames }
  end

  M["frame.setDuration"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local ms = params.durationMs
    if type(ms) ~= "number" or ms <= 0 then
      proto.failf(
        proto.ERROR.INVALID_PARAMS, "durationMs must be a positive number, got %s", tostring(ms)
      )
    end

    app.transaction("mcp: set frame duration", function()
      sprite.frames[frameNumber].duration = doc.secondsFromMs(ms)
    end)
    return {
      frame = frameNumber,
      durationMs = doc.msFromSeconds(sprite.frames[frameNumber].duration),
    }
  end

  return M
end
