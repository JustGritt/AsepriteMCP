-- WebSocket client.
--
-- Aseprite can only act as a WebSocket *client*, so the MCP server binds the
-- socket and we dial out to it.
--
-- Where the server is comes from a preference, the environment and a fixed
-- default, never from a file. An earlier version discovered the port by reading
-- a JSON file the server wrote, which failed in a way worth recording: Aseprite
-- gates script file access behind a Security modal, and app.fs.isFile simply
-- returns false for a path that has not been granted -- no prompt, no error. The
-- bridge could therefore never connect on a fresh install, and the only symptom
-- was silence. Connecting needs no filesystem access at all now, so the one
-- prompt a user sees is the one for previews, at the moment a preview is
-- actually rendered.

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
  local lastAttempt = nil
  -- The target actually dialled, which is not the resolved target between a
  -- setTarget and the reconnect that applies it.
  local target = nil
  local enabled = true

  -- Precedence: explicit override (from plugin.preferences, set through the
  -- connect dialog), then the environment, then the built-in default. An empty
  -- override is NOT the same as one holding the default value, so nothing here
  -- ever seeds it -- see docs/HANDOFF.md for the symptom that causes.
  local override = { host = nil, port = nil }

  local function env(name)
    local value = os.getenv and os.getenv(name)
    if value == nil or value == "" then return nil end
    return value
  end

  --- Coerce a port to a whole number in range, or nil plus a reason.
  --
  -- The fraction check is doing real work, and not the work you would expect.
  -- Stock Lua 5.4 raises "number has no integer representation" for %d on a
  -- float with a fractional part; Aseprite's build does not. Measured on
  -- 1.3.18.3: math.tointeger(32145.5) is 32145 and string.format("%d", 32145.5)
  -- is "32145" -- both truncate, silently. So a 32145.5 in a hand-edited
  -- __pref.lua would dial a port nobody wrote, with nothing anywhere connecting
  -- the symptom back to the file. Refusing it is the only way that surfaces.
  --
  -- The same truncation is why this cannot lean on math.tointeger alone.
  local function toPort(value)
    local n = tonumber(value)
    if n == nil then return nil, "not a number" end
    -- Also catches nan and the infinities, whose remainder is nan.
    if n % 1 ~= 0 then return nil, "not a whole number" end
    n = math.tointeger(n) or n
    -- Aseprite's number widget hands back 0 for an empty field *and* for
    -- unparseable text, verified on 1.3.18.3 -- the field can read "abc" while
    -- dlg.data.port is 0. So 0 gets the message that fits what the user sees,
    -- not the arithmetic one.
    if n == 0 then return nil, "empty or not a number" end
    if n < 1 or n > 65535 then return nil, "outside 1-65535" end
    return n
  end

  --- Resolve the target from all four inputs.
  --
  -- Pure on purpose, and exposed for the tests: Lua cannot *write* environment
  -- variables, so a resolver that read os.getenv itself could only ever be
  -- exercised on the override-vs-default axis.
  function M.resolve(overrideHost, overridePort, envHost, envPort)
    local host, hostSource = DEFAULT_HOST, "default"
    if overrideHost ~= nil and overrideHost ~= "" then
      host, hostSource = overrideHost, "preference"
    elseif envHost ~= nil and envHost ~= "" then
      host, hostSource = envHost, "environment"
    end

    local port, portSource = DEFAULT_PORT, "default"
    if overridePort ~= nil then
      port, portSource = overridePort, "preference"
    elseif envPort ~= nil and envPort ~= "" then
      local parsed = toPort(envPort)
      if parsed then
        port, portSource = parsed, "environment"
      else
        -- Set but unusable. Reporting plain "default" here is exactly what makes
        -- someone ask why their ASEPRITE_MCP_PORT did nothing, so it gets its
        -- own state and the dialog says so.
        portSource = "environment-invalid"
      end
    end

    return {
      host = host,
      port = port,
      hostSource = hostSource,
      portSource = portSource,
      envHost = envHost,
      envPort = envPort,
    }
  end

  local function resolveTarget()
    local resolved = M.resolve(override.host, override.port,
      env("ASEPRITE_MCP_HOST"), env("ASEPRITE_MCP_PORT"))
    -- Empty unless the user opted into token auth on both sides. Environment
    -- only by design: a field in the dialog invites a mismatch with the server,
    -- which presents as a socket that opens and immediately closes again.
    resolved.token = env("ASEPRITE_MCP_TOKEN") or ""
    return resolved
  end

  --- Install the explicit override, which outranks the environment.
  ---
  --- Returns ok, err. nil or "" clears a slot rather than setting it, because an
  --- unset preference has to fall through to the environment. Validation lives
  --- here and not only in the dialog: the other caller is init(plugin) reading
  --- plugin.preferences, and those live in __pref.lua, a plain Lua file that
  --- both Aseprite and humans write.
  function M.setTarget(t)
    t = t or {}

    local host = t.host
    if host == "" then host = nil end
    if host ~= nil and type(host) ~= "string" then
      return false, "host must be text"
    end

    local port = nil
    if t.port ~= nil and t.port ~= "" then
      local parsed, why = toPort(t.port)
      if not parsed then
        return false, "port is " .. why
      end
      port = parsed
    end

    override.host, override.port = host, port
    return true
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
    target = resolveTarget()
    lastAttempt = os.time()
    -- Cleared here rather than only on OPEN, or the dialog reads "Connecting"
    -- beside an error from ten minutes ago for the whole dial.
    lastError = nil
    local ok, err = pcall(function()
      -- Formatted inside the pcall rather than above it. It costs nothing, and
      -- anything that throws out here escapes poll() and is re-thrown by the
      -- pump on every tick, forever, with tracing off by default.
      local url = string.format("ws://%s:%d/", target.host, target.port)
      trace.writef("dialling %s", url)
      socket = WebSocket{
        url = url,
        onreceive = onReceive,
        deflate = false,
        minreconnectwait = 0.5,
        maxreconnectwait = 5.0,
      }
      socket:connect()
    end)
    if not ok then
      lastError = tostring(err)
      socket = nil
      trace.writef("could not dial %s:%s: %s",
        tostring(target.host), tostring(target.port), lastError)
    end
  end

  M.connect = openSocket

  --- Whether the bridge should be dialling at all.
  ---
  --- Disconnect flips this rather than stopping the pump. The pump owns the only
  --- Timer in the extension, so stopping it also stops the dialog's refresh and
  --- drops anything already queued without a reply; see syncPump in main.lua.
  function M.setEnabled(value)
    enabled = value and true or false
    if not enabled then disconnect() end
  end

  function M.isEnabled() return enabled end

  --- Called from the pump each tick. Cheap: the client reconnects on its own, so
  --- this only rebuilds the socket if it has stayed down for a long stretch.
  function M.poll()
    if not enabled then return end
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
    local resolved = resolveTarget()
    return {
      enabled = enabled,
      connected = connected,
      host = resolved.host,
      port = resolved.port,
      hostSource = resolved.hostSource,
      portSource = resolved.portSource,
      envHost = resolved.envHost,
      envPort = resolved.envPort,
      -- Where the live socket is pointed, so the dialog can say when a resolved
      -- change has not been applied yet.
      activeHost = target and target.host or nil,
      activePort = target and target.port or nil,
      usingToken = resolved.token ~= "",
      lastError = lastError,
      lastAttempt = lastAttempt,
    }
  end

  return M
end
