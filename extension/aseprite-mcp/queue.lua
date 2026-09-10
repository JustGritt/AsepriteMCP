-- The command pump.
--
-- This is the single most important piece of the extension. WebSocket callbacks
-- fire on the UI thread, but they can land while another command already holds
-- the document lock -- which upstream reports as either "another operation is
-- happening" or an outright crash (aseprite/aseprite#2980). So onreceive does
-- nothing but append the raw text here, and a Timer drains the queue and does
-- all app.* work from a safe point in the message loop.
--
-- The Timer earns its keep twice over: the same upstream issue notes that
-- Aseprite stops processing socket callbacks when the mouse leaves the window,
-- because nothing is waking the message loop. A running Timer keeps it awake, so
-- commands still arrive while the agent works and Aseprite sits unfocused.

local TICK_SECONDS = 1.0 / 60.0

-- Ceiling on how long one tick may spend running commands, so a burst of work
-- cannot make the editor feel frozen.
local TICK_BUDGET_SECONDS = 0.15

return function(deps)
  local proto, dispatch = deps.proto, deps.dispatch
  local trace = deps.trace
  local M = {}

  local pending = {}
  local timer = nil
  local sender = nil
  local onIdle = nil
  local stats = { handled = 0, failed = 0 }

  function M.setSender(fn) sender = fn end
  function M.setIdleHook(fn) onIdle = fn end
  function M.stats() return stats end
  function M.depth() return #pending end

  function M.push(raw)
    pending[#pending + 1] = raw
  end

  local function send(text)
    if sender then sender(text) end
  end

  --- Recognise the document-lock failure so it gets its own error code rather
  --- than being reported as a generic Lua error.
  local function classify(err)
    local mapped = proto.toError(err)
    if mapped.code == proto.ERROR.LUA_ERROR then
      local text = mapped.message:lower()
      if text:find("lock") or text:find("another command") or text:find("used by") then
        mapped.code = proto.ERROR.DOCUMENT_LOCKED
        mapped.message = mapped.message
          .. " (Aseprite was busy with another operation. Retry the command.)"
      end
    end
    return mapped
  end

  local function handle(raw)
    local decoded, message = pcall(json.decode, raw)
    if not decoded or not proto.isStructured(message) then
      -- No id means nothing to correlate a reply to; the server logs and drops.
      send(proto.errorMessage(0, {
        code = proto.ERROR.PROTOCOL_ERROR,
        message = "Could not decode request as JSON.",
      }))
      return
    end

    local id = message.id
    if type(id) ~= "number" then
      send(proto.errorMessage(0, {
        code = proto.ERROR.PROTOCOL_ERROR,
        message = "Request is missing a numeric id.",
      }))
      return
    end

    trace.writef("handling #%s %s", tostring(id), tostring(message.command))
    local handler = dispatch[message.command]
    if not handler then
      stats.failed = stats.failed + 1
      send(proto.errorMessage(id, {
        code = proto.ERROR.UNKNOWN_COMMAND,
        message = string.format("Unknown command %q.", tostring(message.command)),
      }))
      return
    end

    local ok, result = pcall(handler, message.params or {})
    if ok then
      stats.handled = stats.handled + 1
      local encoded = proto.successMessage(id, result)
      trace.writef("replying #%s (%d bytes)", tostring(id), #encoded)
      send(encoded)
      -- Make the edit visible immediately, which is the whole point of driving a
      -- live session rather than editing files on disk.
      pcall(app.refresh)
    else
      stats.failed = stats.failed + 1
      send(proto.errorMessage(id, classify(result)))
    end
  end

  local lastHeartbeat = 0

  -- Exposed so the Lua tests can drive a raw JSON string through the exact
  -- decode-dispatch-reply path the socket uses, rather than calling handlers
  -- directly and missing decoding bugs entirely.
  function M.handleRaw(raw)
    return handle(raw)
  end

  local function tick()
    local started = os.clock()
    if trace.isEnabled() then
      local now = os.time()
      if now - lastHeartbeat >= 5 then
        lastHeartbeat = now
        trace.writef("pump alive (queued=%d handled=%d failed=%d)",
          #pending, stats.handled, stats.failed)
      end
    end
    while #pending > 0 do
      local raw = table.remove(pending, 1)
      -- A failure inside handle() must never kill the timer, or the bridge goes
      -- permanently deaf with no visible cause.
      local ok, err = pcall(handle, raw)
      if not ok then
        trace.writef("pump error: %s", tostring(err))
        print("[aseprite-mcp] command pump error: " .. tostring(err))
      end
      if os.clock() - started > TICK_BUDGET_SECONDS then break end
    end
    if onIdle then
      -- Swallowed so a reconnect hiccup cannot kill the timer, but never
      -- silently: without this trace the bridge fails invisibly.
      local ok, err = pcall(onIdle)
      if not ok then trace.writef("idle hook error: %s", tostring(err)) end
    end
  end

  function M.start()
    if timer then return end
    timer = Timer{ interval = TICK_SECONDS, ontick = tick }
    timer:start()
    trace.write("pump started")
  end

  function M.stop()
    if timer then
      timer:stop()
      timer = nil
    end
    pending = {}
  end

  function M.isRunning()
    return timer ~= nil
  end

  return M
end
