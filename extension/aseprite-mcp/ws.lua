-- WebSocket client.
--
-- Aseprite can only act as a WebSocket *client*, so the MCP server binds the
-- socket and we dial out to it.
--
-- Where the server is comes from the environment and a fixed default, never from
-- a file. An earlier version discovered the port by reading a JSON file the
-- server wrote, which failed in a way worth recording: Aseprite gates script
-- file access behind a Security modal, and app.fs.isFile simply returns false
-- for a path that has not been granted -- no prompt, no error. The bridge could
-- therefore never connect on a fresh install, and the only symptom was silence.
-- Connecting needs no filesystem access at all now, so the one prompt a user
-- sees is the one for previews, at the moment a preview is actually rendered.

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 32145
local PROTOCOL_VERSION = 1

-- If the socket has still not opened after this long, rebuild it. The client has
-- its own reconnect backoff; this only covers the case where it gave up.
local RECONNECT_AFTER_SECONDS = 15

return function(deps)
  local queue = deps.queue
  local trace = deps.trace
  local M = {}

  local socket = nil
  local connected = false
  local lastError = nil
  local target = nil
  local lastAttempt = nil

  local function env(name, fallback)
    local value = os.getenv and os.getenv(name)
    if value == nil or value == "" then return fallback end
    return value
  end

  local function readTarget()
    return {
      host = env("ASEPRITE_MCP_HOST", DEFAULT_HOST),
      port = tonumber(env("ASEPRITE_MCP_PORT", tostring(DEFAULT_PORT))) or DEFAULT_PORT,
      -- Empty unless the user opted into token auth on both sides.
      token = env("ASEPRITE_MCP_TOKEN", ""),
    }
  end

  local function sendHello()
    if not socket then return end
    local capabilities = {}
    -- Probed from the API version rather than by creating a throwaway Sprite:
    -- document work must never happen inside a socket callback, and in the GUI
    -- closing such a sprite can raise a modal that wedges the bridge. layerId()
    -- still degrades to nil at runtime if uuid turns out to be absent.
    if app.apiVersion >= 27 then capabilities[#capabilities + 1] = "layer.uuid" end

    socket:sendText(json.encode({
      type = "hello",
      token = target and target.token or "",
      protocolVersion = PROTOCOL_VERSION,
      asepriteVersion = tostring(app.version),
      apiVersion = app.apiVersion,
      capabilities = capabilities,
    }))
  end

  local function onReceive(messageType, data)
    trace.writef("ws event type=%s len=%s",
      tostring(messageType), data and tostring(#tostring(data)) or "nil")
    if messageType == WebSocketMessageType.OPEN then
      connected = true
      lastError = nil
      trace.write("socket open; sending hello")
      sendHello()
    elseif messageType == WebSocketMessageType.TEXT then
      -- Deliberately does nothing but enqueue: see queue.lua for why touching
      -- app.* from this callback is unsafe.
      queue.push(data)
    elseif messageType == WebSocketMessageType.CLOSE then
      if connected then trace.write("socket closed") end
      connected = false
    end
  end

  local function disconnect()
    if socket then
      pcall(function() socket:close() end)
      socket = nil
    end
    connected = false
  end

  local function openSocket()
    disconnect()
    target = readTarget()
    lastAttempt = os.time()
    local url = string.format("ws://%s:%d/", target.host, target.port)
    local ok, err = pcall(function()
      socket = WebSocket{
        url = url,
        onreceive = onReceive,
        deflate = false,
        minreconnectwait = 0.5,
        maxreconnectwait = 5.0,
      }
      socket:connect()
    end)
    if ok then
      trace.writef("dialling %s", url)
    else
      lastError = tostring(err)
      socket = nil
      trace.writef("could not dial %s: %s", url, lastError)
    end
  end

  M.connect = openSocket

  --- Called from the pump each tick. Cheap: the client reconnects on its own, so
  --- this only rebuilds the socket if it has stayed down for a long stretch.
  function M.poll()
    if socket == nil then
      openSocket()
      return
    end
    if not connected and os.time() - (lastAttempt or 0) >= RECONNECT_AFTER_SECONDS then
      trace.write("still not connected; rebuilding the socket")
      openSocket()
    end
  end

  function M.send(text)
    if socket and connected then
      pcall(function() socket:sendText(text) end)
    end
  end

  function M.disconnect() disconnect() end

  function M.status()
    return {
      connected = connected,
      host = target and target.host or DEFAULT_HOST,
      port = target and target.port or DEFAULT_PORT,
      usingToken = (target and target.token or "") ~= "",
      lastError = lastError,
    }
  end

  return M
end
