-- Several editing commands in one transaction (issue #7).
--
-- Each command the agent sends is one model turn that re-reads the whole
-- context, so building a frame from duplicate + shift + draw used to cost three
-- or four turns. A batch runs them in one call and one app.transaction. Nested
-- transactions merge into the outer one, so the whole batch is one undo step,
-- and an error inside it rolls every command back, so a batch is all or nothing.

-- Only commands that edit the document. Renders and file access stay out: they
-- need their own outPath handling, and undo/redo cannot run inside a
-- transaction.
local ALLOWED_PREFIXES = { "draw.", "cel.", "frame.", "rig." }
local ALLOWED = {
  ["layer.select"] = true,
  ["layer.create"] = true,
  ["layer.delete"] = true,
  ["layer.setVisibility"] = true,
  ["tag.create"] = true,
  ["tag.update"] = true,
  ["tag.delete"] = true,
}

local function allowed(command)
  if ALLOWED[command] then return true end
  for _, prefix in ipairs(ALLOWED_PREFIXES) do
    if command:sub(1, #prefix) == prefix then return true end
  end
  return false
end

return function(deps, dispatch)
  local proto = deps.proto
  local M = {}

  M["batch.run"] = function(params)
    local ops = params.ops
    if not proto.isStructured(ops) or #ops == 0 then
      proto.fail(proto.ERROR.INVALID_PARAMS, "ops must be a non-empty array.")
    end
    for i, op in ipairs(ops) do
      local command = op.command
      if type(command) ~= "string" or not dispatch[command] or not allowed(command) then
        proto.failf(proto.ERROR.INVALID_PARAMS,
          "ops[%d]: %s cannot run inside a batch.", i - 1, tostring(command))
      end
    end

    local results, failedAt, failure = {}, nil, nil
    local ok, err = pcall(function()
      app.transaction("mcp: batch", function()
        for i, op in ipairs(ops) do
          local success, result = pcall(dispatch[op.command], op.params or {})
          if not success then
            failedAt, failure = i, result
            error(result, 0)
          end
          results[i] = result
        end
      end)
    end)

    if not ok then
      local reason = failure or err
      local code = type(reason) == "table" and reason.code or proto.ERROR.LUA_ERROR
      local message = type(reason) == "table" and reason.message or tostring(reason)
      proto.failf(code,
        "ops[%d] (%s) failed, so the whole batch was rolled back and nothing changed: %s",
        (failedAt or 1) - 1, failedAt and ops[failedAt].command or "?", message)
    end
    return { applied = #ops, undoSteps = 1, results = proto.array(results) }
  end

  return M
end
