-- Character rigs: part layers, a rest frame, and a pose per frame.
--
-- Built because animating small characters by editing the previous frame
-- drifted, and because at 18-24 px the model cannot tell which pixels are the
-- arm. With a rig, every frame is a pose of the rest frame: each part is a copy
-- of a source cel (its own rest cel unless told otherwise), moved, optionally
-- recolored, or hidden. The recipe is stored on the cel, so the whole animation
-- can be rebuilt after the rest drawing changes. docs/ANIMATION.md has the design.

return function(deps)
  local proto, doc, color, store = deps.proto, deps.doc, deps.color, deps.rigstore
  local EXT = store.EXT
  local M = {}

  -- ------------------------------------------------------------------ helpers

  local function requireRig(sprite)
    local rig = store.load(sprite)
    if not rig then
      proto.fail(proto.ERROR.INVALID_PARAMS,
        "This sprite has no rig. Call define_rig with its part layers first.")
    end
    if type(rig.rest) ~= "number" or rig.rest < 1 or rig.rest > #sprite.frames then
      proto.failf(proto.ERROR.INVALID_FRAME,
        "The rig's rest frame no longer exists. Call define_rig again with rest_frame.")
    end
    return rig
  end

  local function imageLayer(sprite, name)
    return doc.requireImageLayer(doc.resolveLayer(sprite, name))
  end

  local function isPart(rig, name)
    for _, part in ipairs(rig.parts) do
      if part == name then return true end
    end
    return false
  end

  --- Leaders before followers, so a follower can read its leader's offset.
  local function dependencyOrder(rig)
    local order, placed = {}, {}
    local function place(name, depth)
      if placed[name] then return end
      if depth > #rig.parts then return end -- define refuses cycles; belt and braces
      local leader = rig.follows[name]
      if leader then place(leader, depth + 1) end
      placed[name] = true
      order[#order + 1] = name
    end
    for _, name in ipairs(rig.parts) do place(name, 0) end
    return order
  end

  local function blankCel(sprite, layer, frame)
    local image = Image(1, 1, sprite.colorMode)
    image:clear(color.transparentValue(sprite))
    return sprite:newCel(layer, frame, image, Point(0, 0))
  end

  --- Build a part's cel on `frame` from its recipe and record the recipe.
  -- Returns the cel and whether its source was missing.
  local function writePart(sprite, layer, frame, rec)
    local cel, missing
    if rec.hide then
      cel = blankCel(sprite, layer, frame)
    else
      local source = rec.from and imageLayer(sprite, rec.from) or layer
      local srcCel = (rec.src >= 1 and rec.src <= #sprite.frames) and source:cel(rec.src) or nil
      if not srcCel then
        missing = true
        cel = blankCel(sprite, layer, frame)
      else
        local image = Image(srcCel.image)
        if rec.recolor then
          local map = {}
          for from, to in pairs(rec.recolor) do
            local fromValue = color.toPixelValue(sprite, { color = from })
            map[fromValue] = color.toPixelValue(sprite, { color = to })
          end
          for it in image:pixels() do
            local swap = map[it()]
            if swap ~= nil then it(swap) end
          end
        end
        local position = Point(srcCel.position.x + (rec.dx or 0), srcCel.position.y + (rec.dy or 0))
        cel = sprite:newCel(layer, frame, image, position)
      end
    end
    local record = {}
    for k, v in pairs(rec) do record[k] = v end
    record.hash = store.hashCel(sprite, cel)
    cel.properties(EXT).pose = record
    return cel, missing
  end

  --- What is on a part's cel, for a pose call that does not list the part.
  --   empty   nothing, or nothing opaque
  --   copy    an unrecorded copy of the rest cel, as duplicate_frame leaves
  --   posed   written by the rig and untouched since (returns the recipe)
  --   edited  written by the rig, then changed by hand
  --   drawn   drawn by hand, never posed
  local function classify(sprite, layer, frame, rest)
    local cel = layer:cel(frame)
    if not cel then return "empty" end
    local hash = store.hashCel(sprite, cel)
    local rec = cel.properties(EXT).pose
    if rec then
      if rec.hash == hash then return "posed", rec end
      -- Drawn over a hidden part: a new drawing, which nothing derived.
      if rec.hide then return "drawn" end
      return "edited", rec
    end
    if hash == store.EMPTY_HASH then return "empty" end
    if frame ~= rest and hash == store.hashCel(sprite, layer:cel(rest)) then return "copy" end
    return "drawn"
  end

  --- Redraw the outline layer on one frame around the silhouette parts.
  -- Returns the number of outline pixels, or "kept" for a hand-edited cel.
  local function redrawOutline(sprite, rig, frame, force)
    local spec = rig.outline
    local layer = imageLayer(sprite, spec.layer)
    local cel = layer:cel(frame)
    -- A hand-drawn outline is kept, unless it is exactly what would be drawn
    -- anyway, as a split of a clean drawing usually gives: then it is adopted.
    local handDrawn = nil
    if cel and not force then
      local hash = store.hashCel(sprite, cel)
      local rec = cel.properties(EXT).outline
      if rec then
        if rec.hash ~= hash then return "kept" end
      elseif hash ~= store.EMPTY_HASH then
        local isRestCopy = frame ~= rig.rest
          and hash == store.hashCel(sprite, layer:cel(rig.rest))
        if not isRestCopy then handDrawn = hash end
      end
    end

    local W, H = sprite.width, sprite.height
    local mask = {}
    for _, name in ipairs(spec.parts or rig.parts) do
      local part = imageLayer(sprite, name)
      local partCel = part:cel(frame)
      if partCel then
        local px, py = partCel.position.x, partCel.position.y
        for it in partCel.image:pixels() do
          local x, y = it.x + px, it.y + py
          if x >= 0 and y >= 0 and x < W and y < H and store.isOpaque(sprite, it()) then
            mask[y * W + x] = true
          end
        end
      end
    end

    local points, minX, minY, maxX, maxY = {}, math.huge, math.huge, -1, -1
    local seen = {}
    local floor = spec.floor
    for key in pairs(mask) do
      local x, y = key % W, key // W
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local nx, ny = x + d[1], y + d[2]
        local nkey = ny * W + nx
        if nx >= 0 and ny >= 0 and nx < W and ny < H and not mask[nkey] and not seen[nkey]
          and (floor == nil or ny <= floor) then
          seen[nkey] = true
          points[#points + 1] = { nx, ny }
          if nx < minX then minX = nx end
          if ny < minY then minY = ny end
          if nx > maxX then maxX = nx end
          if ny > maxY then maxY = ny end
        end
      end
    end

    if #points == 0 then
      if handDrawn then return "kept" end
      if cel then sprite:deleteCel(cel) end
      return 0
    end
    local ink = color.toPixelValue(sprite, { color = spec.color })
    local image = Image(maxX - minX + 1, maxY - minY + 1, sprite.colorMode)
    image:clear(color.transparentValue(sprite))
    for _, p in ipairs(points) do image:drawPixel(p[1] - minX, p[2] - minY, ink) end
    if handDrawn then
      if store.hashImage(sprite, image, minX, minY) ~= handDrawn then return "kept" end
      cel.properties(EXT).outline = { hash = handDrawn }
      return #points
    end
    local written = sprite:newCel(layer, frame, image, Point(minX, minY))
    written.properties(EXT).outline = { hash = store.hashCel(sprite, written) }
    return #points
  end

  --- The figure's box on a frame, and the parts that touch no other part.
  -- Touching is 8-connected, overlap included, so a hat over a head and a leg
  -- under a hip both count as attached.
  local function inspectFrame(sprite, rig, frame)
    local occupancy, opaqueParts = {}, {}
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local function cover(cel)
      local px, py = cel.position.x, cel.position.y
      local pixels = {}
      for it in cel.image:pixels() do
        if store.isOpaque(sprite, it()) then
          local x, y = it.x + px, it.y + py
          pixels[#pixels + 1] = { x, y }
          if x < minX then minX = x end
          if y < minY then minY = y end
          if x > maxX then maxX = x end
          if y > maxY then maxY = y end
        end
      end
      return pixels
    end
    local function key(x, y) return (y + 4096) * 16384 + (x + 4096) end

    for i, name in ipairs(rig.parts) do
      local cel = imageLayer(sprite, name):cel(frame)
      local pixels = cel and cover(cel) or {}
      if #pixels > 0 then
        local bit = 1 << (i - 1)
        opaqueParts[#opaqueParts + 1] = { name = name, pixels = pixels, bit = bit }
        for _, p in ipairs(pixels) do
          local k = key(p[1], p[2])
          occupancy[k] = (occupancy[k] or 0) | bit
        end
      end
    end
    if rig.outline then
      local cel = imageLayer(sprite, rig.outline.layer):cel(frame)
      if cel then cover(cel) end
    end

    local detached = {}
    if #opaqueParts > 1 then
      for _, part in ipairs(opaqueParts) do
        local attached = false
        for _, p in ipairs(part.pixels) do
          for dy = -1, 1 do
            for dx = -1, 1 do
              local other = occupancy[key(p[1] + dx, p[2] + dy)]
              if other and (other & ~part.bit) ~= 0 then attached = true break end
            end
            if attached then break end
          end
          if attached then break end
        end
        if not attached then detached[#detached + 1] = part.name end
      end
    end

    local box = nil
    if maxX >= minX then
      box = proto.array({ minX, minY, maxX - minX + 1, maxY - minY + 1 })
    end
    return box, detached
  end

  --- Validate a part spec from the agent into a recipe (without the leader's
  -- offset, which the caller adds).
  local function recipeFrom(sprite, rig, partName, frame, spec)
    local rec = { src = rig.rest, dx = 0, dy = 0 }
    if spec.dx ~= nil then rec.dx = math.floor(spec.dx) end
    if spec.dy ~= nil then rec.dy = math.floor(spec.dy) end
    if spec.frame ~= nil then rec.src = doc.resolveFrame(sprite, spec.frame) end
    if spec.layer ~= nil then
      local source = imageLayer(sprite, spec.layer)
      if source.name ~= partName then rec.from = source.name end
    end
    if spec.hide then rec.hide = true end
    if spec.recolor ~= nil then
      if not proto.isStructured(spec.recolor) then
        proto.failf(proto.ERROR.INVALID_PARAMS, "%s: recolor must map colors to colors.", partName)
      end
      local map, any = {}, false
      for from, to in pairs(spec.recolor) do
        color.parseHex(from)
        color.parseHex(to)
        map[from] = to
        any = true
      end
      if any then rec.recolor = map end
    end
    if not rec.hide and rec.src == frame and rec.from == nil then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "%s on frame %d cannot take its drawing from itself. Name another frame or layer.",
        partName, frame)
    end
    return rec
  end

  -- ----------------------------------------------------------------- commands

  M["rig.define"] = function(params)
    local sprite = doc.activeSprite()
    local parts = params.parts
    if not proto.isStructured(parts) or #parts == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "parts must list at least one part layer name.")
    end
    local names, seen = {}, {}
    for i = 1, #parts do
      local name = parts[i]
      if type(name) ~= "string" or name == "" then
        proto.failf(proto.ERROR.INVALID_PARAMS, "parts[%d] must be a layer name.", i - 1)
      end
      if seen[name] then
        proto.failf(proto.ERROR.INVALID_PARAMS, "%q is listed twice in parts.", name)
      end
      if name == store.OUTLINE_LAYER and params.outline ~= nil then
        proto.failf(proto.ERROR.INVALID_PARAMS,
          "%q is the layer the rig draws the outline on, so it cannot also be a part.", name)
      end
      seen[name] = true
      names[#names + 1] = name
    end

    local rest = doc.resolveFrame(sprite, params.rest or 1)

    local follows = {}
    if params.follows ~= nil then
      if not proto.isStructured(params.follows) then
        proto.fail(proto.ERROR.INVALID_PARAMS, "follows must map a part to the part it follows.")
      end
      for follower, leader in pairs(params.follows) do
        if not seen[follower] or not seen[leader] then
          proto.failf(proto.ERROR.INVALID_PARAMS,
            "follows %q -> %q: both must be in parts.", tostring(follower), tostring(leader))
        end
        if follower == leader then
          proto.failf(proto.ERROR.INVALID_PARAMS, "%q cannot follow itself.", follower)
        end
        follows[follower] = leader
      end
      for start in pairs(follows) do
        local at, steps = start, 0
        while follows[at] do
          at, steps = follows[at], steps + 1
          if steps > #names then
            proto.failf(proto.ERROR.INVALID_PARAMS, "follows loops back to %q.", start)
          end
        end
      end
    end

    local outline = nil
    if params.outline ~= nil then
      local spec = params.outline
      color.parseHex(spec.color)
      local silhouette = nil
      if spec.parts ~= nil then
        silhouette = {}
        for i = 1, #spec.parts do
          if not seen[spec.parts[i]] then
            proto.failf(proto.ERROR.INVALID_PARAMS,
              "outline part %q is not in parts.", tostring(spec.parts[i]))
          end
          silhouette[#silhouette + 1] = spec.parts[i]
        end
      end
      outline = {
        color = spec.color,
        layer = store.OUTLINE_LAYER,
        parts = silhouette,
        floor = spec.floor ~= nil and math.floor(spec.floor) or nil,
      }
    end

    -- Find each layer by exact name. Parts are top-level image layers: the rig
    -- stacks them, and importers differ in how they treat groups.
    local byName = {}
    for _, entry in ipairs(doc.allLayers(sprite)) do
      local list = byName[entry.layer.name] or {}
      list[#list + 1] = entry
      byName[entry.layer.name] = list
    end
    local stack = {}
    if outline then stack[1] = outline.layer end
    for _, name in ipairs(names) do stack[#stack + 1] = name end

    local created = {}
    local rig = { rest = rest, parts = names, follows = follows, outline = outline }
    local restOutline = nil
    app.transaction("mcp: define rig", function()
      local members = {}
      for _, name in ipairs(stack) do
        local found = byName[name]
        local layer
        if found and #found > 1 then
          proto.failf(proto.ERROR.INVALID_LAYER,
            "%d layers are named %q. Rename one so each part has its own layer.", #found, name)
        elseif found then
          layer = found[1].layer
          if found[1].depth > 0 then
            proto.failf(proto.ERROR.INVALID_LAYER,
              "%q is inside a group. Rig parts must be top-level layers.", name)
          end
          doc.requireImageLayer(layer)
          if layer.isBackground then
            proto.failf(proto.ERROR.INVALID_LAYER,
              "%q is the background layer, which cannot move. Use a normal layer.", name)
          end
        else
          layer = sprite:newLayer()
          layer.name = name
          created[#created + 1] = name
        end
        members[#members + 1] = layer
      end

      -- Stack the members contiguously, bottom to top, from the lowest one.
      local anchor = math.huge
      for _, layer in ipairs(members) do
        if layer.stackIndex < anchor then anchor = layer.stackIndex end
      end
      for i, layer in ipairs(members) do layer.stackIndex = anchor + i - 1 end

      store.save(sprite, rig)
      if outline then restOutline = redrawOutline(sprite, rig, rest, false) end
    end)

    local followList = nil
    if next(follows) then followList = follows end
    return {
      rest = rest,
      parts = proto.array(names),
      follows = followList,
      outline = outline and outline.color or nil,
      created = #created > 0 and proto.array(created) or nil,
      restOutline = restOutline,
    }
  end

  M["rig.pose"] = function(params)
    local sprite = doc.activeSprite()
    local rig = requireRig(sprite)
    local frame = doc.resolveFrame(sprite, params.frame)
    if frame == rig.rest then
      proto.failf(proto.ERROR.INVALID_FRAME,
        "Frame %d is the rest frame. Draw on it directly, then refresh_rig.", frame)
    end

    local specs = {}
    if params.parts ~= nil then
      if not proto.isStructured(params.parts) then
        proto.fail(proto.ERROR.INVALID_PARAMS, "parts must map part names to poses.")
      end
      for name, spec in pairs(params.parts) do
        if not isPart(rig, name) then
          proto.failf(proto.ERROR.INVALID_PARAMS,
            "%q is not a rig part. Parts: %s", tostring(name), table.concat(rig.parts, ", "))
        end
        specs[name] = recipeFrom(sprite, rig, name, frame, spec)
      end
    end

    local posed, kept, missing = {}, {}, {}
    local offsets = {}
    local outlineResult
    app.transaction("mcp: pose frame", function()
      for _, name in ipairs(dependencyOrder(rig)) do
        local layer = imageLayer(sprite, name)
        local leader = rig.follows[name]
        local lead = leader and offsets[leader] or nil
        local rec = specs[name]
        local write = nil

        if rec then
          if lead then
            rec.dx, rec.dy = rec.dx + lead[1], rec.dy + lead[2]
            rec.lead = proto.array({ lead[1], lead[2] })
          end
          write = rec
        else
          local state, old = classify(sprite, layer, frame, rig.rest)
          if state == "empty" or state == "copy" then
            write = { src = rig.rest, dx = lead and lead[1] or 0, dy = lead and lead[2] or 0 }
            if lead then write.lead = proto.array({ lead[1], lead[2] }) end
          elseif state == "posed" and lead then
            local oldLead = old.lead or { 0, 0 }
            if oldLead[1] ~= lead[1] or oldLead[2] ~= lead[2] then
              write = {}
              for k, v in pairs(old) do write[k] = v end
              write.hash = nil
              write.dx = (old.dx or 0) - oldLead[1] + lead[1]
              write.dy = (old.dy or 0) - oldLead[2] + lead[2]
              write.lead = proto.array({ lead[1], lead[2] })
            end
            offsets[name] = { old.dx or 0, old.dy or 0 }
          elseif state == "posed" then
            offsets[name] = { old.dx or 0, old.dy or 0 }
          else
            kept[#kept + 1] = name
            offsets[name] = old and { old.dx or 0, old.dy or 0 } or { 0, 0 }
          end
        end

        if write then
          local _, wasMissing = writePart(sprite, layer, frame, write)
          if wasMissing then missing[#missing + 1] = name end
          posed[#posed + 1] = name
          offsets[name] = { write.dx or 0, write.dy or 0 }
        end
      end
      if rig.outline then outlineResult = redrawOutline(sprite, rig, frame, false) end
    end)

    local box, detached = inspectFrame(sprite, rig, frame)
    return {
      frame = frame,
      posed = proto.array(posed),
      kept = #kept > 0 and proto.array(kept) or nil,
      emptySource = #missing > 0 and proto.array(missing) or nil,
      outline = outlineResult,
      box = box,
      detached = #detached > 0 and proto.array(detached) or nil,
    }
  end

  M["rig.refresh"] = function(params)
    local sprite = doc.activeSprite()
    local rig = requireRig(sprite)
    local force = params.force == true

    local frames = {}
    if params.frames ~= nil then
      if not proto.isStructured(params.frames) then
        proto.fail(proto.ERROR.INVALID_PARAMS, "frames must be a list of frame numbers.")
      end
      for i = 1, #params.frames do frames[#frames + 1] = doc.resolveFrame(sprite, params.frames[i]) end
    else
      for i = 1, #sprite.frames do frames[#frames + 1] = i end
    end

    local done, visiting = {}, {}
    local updated, kept, missing, cycles = 0, {}, {}, {}
    local outlines, outlinesKept = 0, {}

    local function refreshCel(layer, frame)
      local key = layer.name .. "@" .. frame
      if done[key] then return end
      if visiting[key] then
        cycles[#cycles + 1] = key
        return
      end
      local cel = layer:cel(frame)
      local rec = cel and cel.properties(EXT).pose or nil
      if not rec then
        done[key] = true
        return
      end
      local before = store.hashCel(sprite, cel)
      if rec.hash ~= before and rec.hide then
        -- Drawn over a hidden part: a new drawing and a source, never derived,
        -- so there is nothing to rebuild and nothing to warn about.
        done[key] = true
        return
      end
      if rec.hash ~= before and not force then
        kept[#kept + 1] = key
        done[key] = true
        return
      end
      if not rec.hide then
        if rec.src < 1 or rec.src > #sprite.frames then
          missing[#missing + 1] = key
          done[key] = true
          return
        end
        visiting[key] = true
        local source = rec.from and imageLayer(sprite, rec.from) or layer
        refreshCel(source, rec.src)
        visiting[key] = nil
      end
      local copy = {}
      for k, v in pairs(rec) do copy[k] = v end
      copy.hash = nil
      local written, wasMissing = writePart(sprite, layer, frame, copy)
      if wasMissing then missing[#missing + 1] = key end
      if store.hashCel(sprite, written) ~= before then updated = updated + 1 end
      done[key] = true
    end

    app.transaction("mcp: refresh rig", function()
      for _, frame in ipairs(frames) do
        for _, name in ipairs(dependencyOrder(rig)) do
          refreshCel(imageLayer(sprite, name), frame)
        end
      end
      if rig.outline then
        for _, frame in ipairs(frames) do
          local result = redrawOutline(sprite, rig, frame, force)
          if result == "kept" then
            outlinesKept[#outlinesKept + 1] = frame
          else
            outlines = outlines + 1
          end
        end
      end
    end)

    return {
      frames = #frames,
      updated = updated,
      kept = #kept > 0 and proto.array(kept) or nil,
      missing = #missing > 0 and proto.array(missing) or nil,
      cycles = #cycles > 0 and proto.array(cycles) or nil,
      outlines = rig.outline and outlines or nil,
      outlinesKept = #outlinesKept > 0 and proto.array(outlinesKept) or nil,
    }
  end

  --- Move labelled pixels out of one layer into others (part layers).
  M["cel.split"] = function(params)
    local sprite = doc.activeSprite()
    local source = imageLayer(sprite, params.layer)
    local frame = doc.resolveFrame(sprite, params.frame)
    local cel = source:cel(frame)
    if not cel then
      proto.failf(proto.ERROR.INVALID_PARAMS,
        "Layer %q has no cel in frame %d, so there is nothing to split.", source.name, frame)
    end
    local rows, labels = params.rows, params.parts
    if not proto.isStructured(rows) or #rows == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "rows must hold at least one row.")
    end
    if not proto.isStructured(labels) or #labels == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "parts must map at least one character to a layer.")
    end

    local x0, y0 = math.floor(params.x), math.floor(params.y)
    local transparent = color.transparentValue(sprite)
    local byName, sourceTopLevel = {}, false
    for _, entry in ipairs(doc.allLayers(sprite)) do
      if byName[entry.layer.name] == nil then byName[entry.layer.name] = entry.layer end
      if entry.layer == source then sourceTopLevel = entry.depth == 0 end
    end

    local created, moved = {}, {}
    local skipped, skippedAt = 0, {}
    app.transaction("mcp: split layer", function()
      local targets, order = {}, {}
      for i = 1, #labels do
        local pair = labels[i]
        local char, name = pair[1], pair[2]
        local layer = byName[name]
        if layer then
          doc.requireImageLayer(layer)
          if layer == source then
            proto.failf(proto.ERROR.INVALID_PARAMS,
              "%q is the layer being split. Label pixels that stay with '.'.", name)
          end
        else
          layer = sprite:newLayer()
          layer.name = name
          byName[name] = layer
          created[#created + 1] = name
          -- Directly above the source, in the order listed. A source inside a
          -- group leaves the new layer on top, where newLayer put it.
          if sourceTopLevel then layer.stackIndex = source.stackIndex + #created end
        end
        targets[char] = layer
        order[#order + 1] = char
      end

      local image, bx, by = cel.image, cel.position.x, cel.position.y
      local writes, erase = {}, {}
      for j = 1, #rows do
        local row = rows[j]
        for i = 1, #row do
          local char = row:sub(i, i)
          if char ~= "." and char ~= " " then
            local target = targets[char]
            if not target then
              proto.failf(proto.ERROR.INVALID_PARAMS,
                "rows[%d] uses %q, which parts does not map to a layer.", j - 1, char)
            end
            local x, y = x0 + i - 1, y0 + j - 1
            local lx, ly = x - bx, y - by
            local value = nil
            if lx >= 0 and ly >= 0 and lx < image.width and ly < image.height then
              value = image:getPixel(lx, ly)
            end
            if value ~= nil and store.isOpaque(sprite, value) then
              local list = writes[char] or {}
              list[#list + 1] = { x = x, y = y, value = value }
              writes[char] = list
              erase[#erase + 1] = { x = x, y = y }
            else
              skipped = skipped + 1
              if #skippedAt < 6 then skippedAt[#skippedAt + 1] = proto.array({ x, y }) end
            end
          end
        end
      end

      for _, char in ipairs(order) do
        local list = writes[char]
        if list and #list > 0 then
          doc.writePixels(sprite, targets[char], frame, list, transparent)
          local name = targets[char].name
          moved[name] = (moved[name] or 0) + #list
        end
      end
      if #erase > 0 then doc.erasePixels(sprite, source, frame, erase, transparent) end
    end)

    local left = 0
    local remaining = source:cel(frame)
    if remaining then
      for it in remaining.image:pixels() do
        if store.isOpaque(sprite, it()) then left = left + 1 end
      end
    end
    return {
      frame = frame,
      moved = moved,
      created = #created > 0 and proto.array(created) or nil,
      left = left,
      -- A label on a transparent pixel is almost always a row shifted by one,
      -- which also means an opaque neighbour went to the wrong part. Where it
      -- happened is what makes that cheap to fix.
      labelledTransparent = skipped > 0 and skipped or nil,
      labelledTransparentAt = skipped > 0 and proto.array(skippedAt) or nil,
    }
  end

  return M
end
