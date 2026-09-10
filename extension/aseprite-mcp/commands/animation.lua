-- Animation inspection and tag commands (spec sections 13 and 14).

local DIRECTION_TO_ANIDIR = {
  forward = AniDir.FORWARD,
  reverse = AniDir.REVERSE,
  pingpong = AniDir.PING_PONG,
  pingpong_reverse = AniDir.PING_PONG_REVERSE,
}

local ANIDIR_TO_DIRECTION = {}
for name, value in pairs(DIRECTION_TO_ANIDIR) do
  ANIDIR_TO_DIRECTION[value] = name
end

local DEFAULT_MAX_PREVIEW_PIXELS = 4000000

return function(deps)
  local proto, doc, render = deps.proto, deps.doc, deps.render
  local fsio = deps.fsio
  local M = {}

  local function findTag(sprite, name)
    for _, tag in ipairs(sprite.tags) do
      if tag.name == name then return tag end
    end
    local names = {}
    for _, tag in ipairs(sprite.tags) do names[#names + 1] = tag.name end
    proto.failf(
      proto.ERROR.INVALID_PARAMS,
      "No tag named %q. Existing tags: %s",
      tostring(name), #names > 0 and table.concat(names, ", ") or "(none)"
    )
  end

  local function describeTag(tag)
    return {
      name = tag.name,
      from = tag.fromFrame.frameNumber,
      to = tag.toFrame.frameNumber,
      frames = tag.frames,
      direction = ANIDIR_TO_DIRECTION[tag.aniDir] or tostring(tag.aniDir),
      repeats = tag.repeats,
    }
  end

  --- Frame numbers covered by a tag, or every frame when no tag is given.
  local function frameRange(sprite, tagName)
    if tagName == nil then
      local all = {}
      for i = 1, #sprite.frames do all[#all + 1] = i end
      return all, nil
    end
    local tag = findTag(sprite, tagName)
    local frames = {}
    for i = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do frames[#frames + 1] = i end
    return frames, tag
  end

  --- Every tag covering a frame, not just the first.
  -- Tags overlap more often than you would expect: inserting or duplicating
  -- frames makes Aseprite extend a tag that spans the insertion point, so a
  -- one-frame "idle" tag quietly grows to cover a whole new animation. Reporting
  -- a single arbitrary match would tell the agent the wrong thing.
  local function tagsCovering(sprite, frameNumber)
    local names = {}
    for _, tag in ipairs(sprite.tags) do
      if frameNumber >= tag.fromFrame.frameNumber and frameNumber <= tag.toFrame.frameNumber then
        names[#names + 1] = tag.name
      end
    end
    return proto.array(names)
  end

  -- ------------------------------------------------------------------ inspection

  M["anim.info"] = function(params)
    local sprite = doc.activeSprite()
    local frames, tag = frameRange(sprite, params.tag)

    local durations, total = {}, 0
    for _, frameNumber in ipairs(frames) do
      local ms = doc.msFromSeconds(sprite.frames[frameNumber].duration)
      durations[#durations + 1] = ms
      total = total + ms
    end

    local info = {
      from = frames[1],
      to = frames[#frames],
      frameCount = #frames,
      durationsMs = proto.array(durations),
      totalDurationMs = total,
    }
    if tag then
      info.tag = tag.name
      info.direction = ANIDIR_TO_DIRECTION[tag.aniDir] or tostring(tag.aniDir)
      info.repeats = tag.repeats
    else
      info.tag = nil
      info.note = #sprite.tags > 0
        and "No tag given, so this covers every frame. Pass a tag to scope it."
        or nil
    end
    return info
  end

  M["render.contactSheet"] = function(params)
    local sprite = doc.activeSprite()
    local frames = frameRange(sprite, params.tag)
    local requested = params.scale or 4

    -- Fit the whole sheet, not just one cell, inside the pixel budget.
    local columns = params.columns or #frames
    if columns > #frames then columns = #frames end
    local rows = math.ceil(#frames / columns)
    local maxPixels = params.maxPixels or DEFAULT_MAX_PREVIEW_PIXELS
    local scale = requested
    while scale > 1
      and (columns * sprite.width * scale + columns + 1)
        * (rows * sprite.height * scale + rows + 1) > maxPixels do
      scale = scale - 1
    end

    local sheet, usedColumns, usedRows = render.contactSheet(sprite, frames, scale, columns)
    if type(params.outPath) ~= "string" or params.outPath == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "outPath is required for a render command.")
    end
    if not fsio.saveImage(sheet, params.outPath) then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Could not write %s. Aseprite may not have been granted file-system access "
          .. "for scripts; see docs/SETUP.md.", params.outPath
      )
    end

    local cells = {}
    for _, frameNumber in ipairs(frames) do
      cells[#cells + 1] = {
        frame = frameNumber,
        durationMs = doc.msFromSeconds(sprite.frames[frameNumber].duration),
        tags = tagsCovering(sprite, frameNumber),
      }
    end

    return {
      width = sprite.width,
      height = sprite.height,
      scale = scale,
      requestedScale = requested,
      scaleReduced = scale ~= requested or nil,
      columns = usedColumns,
      rows = usedRows,
      frameCount = #frames,
      tag = params.tag,
      cells = proto.array(cells),
      background = "checkerboard",
    }
  end

  M["render.onionSkin"] = function(params)
    local sprite = doc.activeSprite()
    local frameNumber = doc.resolveFrame(sprite, params.frame)
    local requested = params.scale or 8
    local maxPixels = params.maxPixels or DEFAULT_MAX_PREVIEW_PIXELS
    local scale = requested
    while scale > 1 and (sprite.width * scale) * (sprite.height * scale) > maxPixels do
      scale = scale - 1
    end

    local image, hasPrevious, hasNext = render.onionSkin(sprite, frameNumber, scale)
    if type(params.outPath) ~= "string" or params.outPath == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "outPath is required for a render command.")
    end
    if not fsio.saveImage(image, params.outPath) then
      proto.failf(
        proto.ERROR.LUA_ERROR,
        "Could not write %s. Aseprite may not have been granted file-system access "
          .. "for scripts; see docs/SETUP.md.", params.outPath
      )
    end

    return {
      frame = frameNumber,
      width = sprite.width,
      height = sprite.height,
      scale = scale,
      requestedScale = requested,
      scaleReduced = scale ~= requested or nil,
      hasPrevious = hasPrevious,
      hasNext = hasNext,
      background = "checkerboard",
    }
  end

  -- ------------------------------------------------------------------------ tags

  M["tag.list"] = function()
    local sprite = doc.activeSprite()
    local tags = {}
    for _, tag in ipairs(sprite.tags) do
      tags[#tags + 1] = describeTag(tag)
    end
    return { tags = proto.array(tags), count = #tags }
  end

  M["tag.create"] = function(params)
    local sprite = doc.activeSprite()
    local name = params.name
    if type(name) ~= "string" or name == "" then
      proto.fail(proto.ERROR.INVALID_PARAMS, "A tag name is required.")
    end
    for _, existing in ipairs(sprite.tags) do
      if existing.name == name then
        proto.failf(
          proto.ERROR.INVALID_PARAMS,
          "A tag named %q already exists (frames %d-%d). Use update_animation_tag.",
          name, existing.fromFrame.frameNumber, existing.toFrame.frameNumber
        )
      end
    end

    local from = doc.resolveFrame(sprite, params.from)
    local to = doc.resolveFrame(sprite, params.to)
    if from > to then
      proto.failf(proto.ERROR.INVALID_PARAMS, "from (%d) must not exceed to (%d).", from, to)
    end

    local created
    app.transaction("mcp: create tag", function()
      created = sprite:newTag(from, to)
      created.name = name
      if params.direction then
        created.aniDir = DIRECTION_TO_ANIDIR[params.direction] or AniDir.FORWARD
      end
      if params.repeats ~= nil then created.repeats = params.repeats end
    end)
    return describeTag(created)
  end

  M["tag.update"] = function(params)
    local sprite = doc.activeSprite()
    local tag = findTag(sprite, params.name)

    local from = params["from"] ~= nil and doc.resolveFrame(sprite, params["from"]) or nil
    local to = params["to"] ~= nil and doc.resolveFrame(sprite, params["to"]) or nil
    local newFrom = from or tag.fromFrame.frameNumber
    local newTo = to or tag.toFrame.frameNumber
    if newFrom > newTo then
      proto.failf(proto.ERROR.INVALID_PARAMS, "from (%d) must not exceed to (%d).", newFrom, newTo)
    end
    if params.direction ~= nil and DIRECTION_TO_ANIDIR[params.direction] == nil then
      proto.failf(proto.ERROR.INVALID_PARAMS, "Unknown direction %q.", tostring(params.direction))
    end

    app.transaction("mcp: update tag", function()
      -- fromFrame/toFrame are read-only, so a moved range means replacing the tag.
      if from or to then
        local name = params.newName or tag.name
        local aniDir = params.direction and DIRECTION_TO_ANIDIR[params.direction] or tag.aniDir
        local repeats = params.repeats ~= nil and params.repeats or tag.repeats
        sprite:deleteTag(tag)
        tag = sprite:newTag(newFrom, newTo)
        tag.name = name
        tag.aniDir = aniDir
        pcall(function() tag.repeats = repeats end)
      else
        if params.newName then tag.name = params.newName end
        if params.direction then tag.aniDir = DIRECTION_TO_ANIDIR[params.direction] end
        if params.repeats ~= nil then tag.repeats = params.repeats end
      end
    end)
    return describeTag(tag)
  end

  M["tag.delete"] = function(params)
    local sprite = doc.activeSprite()
    local tag = findTag(sprite, params.name)
    local summary = describeTag(tag)
    app.transaction("mcp: delete tag", function()
      sprite:deleteTag(tag)
    end)
    return { deleted = summary, tagCount = #sprite.tags }
  end

  return M
end
