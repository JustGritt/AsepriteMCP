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

return function(deps)
  local proto, doc = deps.proto, deps.doc
  local M = {}

  local function tagsCovering(sprite, frameNumber)
    local names = {}
    for _, tag in ipairs(sprite.tags) do
      if frameNumber >= tag.fromFrame.frameNumber and frameNumber <= tag.toFrame.frameNumber then
        names[#names + 1] = tag.name
      end
    end
    return proto.array(names)
  end

  M["frame.list"] = function()
    local sprite = doc.activeSprite()
    local frames = {}
    for i, frame in ipairs(sprite.frames) do
      frames[#frames + 1] = {
        index = i,
        durationMs = doc.msFromSeconds(frame.duration),
        tags = tagsCovering(sprite, i),
      }
    end
    return {
      frames = proto.array(frames),
      count = #frames,
      activeFrame = app.frame and app.frame.frameNumber or nil,
    }
  end

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
