-- Aseprite MCP Bridge.
--
-- Connects this Aseprite session to a local MCP server so an agent can inspect
-- and edit the active document. The server binds the socket; we dial out to it,
-- because the Aseprite WebSocket API is client-only.

local SCRIPT_DIR = app.fs.filePath(debug.getinfo(1, "S").source:sub(2))

local core = dofile(app.fs.joinPath(SCRIPT_DIR, "bootstrap.lua"))()
local trace = dofile(app.fs.joinPath(SCRIPT_DIR, "trace.lua"))({ fsio = core.fsio })
local queue = dofile(app.fs.joinPath(SCRIPT_DIR, "queue.lua"))({
  proto = core.proto,
  dispatch = core.dispatch,
  trace = trace,
})
local ws = dofile(app.fs.joinPath(SCRIPT_DIR, "ws.lua"))({ queue = queue, trace = trace })

-- Settle file access now, at load, rather than from inside the pump. A Security
-- modal raised from a Timer callback never paints and hangs the bridge.
local canWriteFiles = core.fsio.primeAccess()

trace.writef("extension loaded (apiVersion=%s, commands=%d, canWriteFiles=%s)",
  tostring(app.apiVersion),
  (function() local n = 0 for _ in pairs(core.dispatch) do n = n + 1 end return n end)(),
  tostring(canWriteFiles))

queue.setSender(ws.send)
-- Discovery polling rides on the pump tick, so there is exactly one timer.
queue.setIdleHook(ws.poll)

-- Deliberately silent on the happy path: Aseprite opens its Console window the
-- first time a script prints, and doing that on every editor launch would be
-- obnoxious. Errors still print, and "MCP Bridge: Status" reports the details.
local function start()
  if not queue.isRunning() then
    queue.start()
  end
end

local function stop()
  ws.disconnect()
  queue.stop()
end

local function statusText()
  local status = ws.status()
  local stats = queue.stats()
  local lines = {
    "Running: " .. tostring(queue.isRunning()),
    "Connected: " .. tostring(status.connected),
    "Can write files: " .. tostring(core.fsio.canWrite()),
    "Server: ws://" .. status.host .. ":" .. status.port,
    "Token auth: " .. tostring(status.usingToken),
    "Commands handled: " .. stats.handled .. " (failed: " .. stats.failed .. ")",
  }
  if status.lastError then
    lines[#lines + 1] = "Last error: " .. status.lastError
  end
  return table.concat(lines, "\n")
end

function init(plugin)
  trace.write("init(plugin) called")
  if plugin.preferences.autoConnect == nil then
    plugin.preferences.autoConnect = true
  end

  plugin:newCommand{
    id = "AsepriteMcpToggle",
    title = "MCP Bridge: Start/Stop",
    group = "file_scripts",
    onclick = function()
      if queue.isRunning() then
        stop()
        plugin.preferences.autoConnect = false
      else
        start()
        plugin.preferences.autoConnect = true
      end
    end,
    onchecked = function() return queue.isRunning() end,
  }

  plugin:newCommand{
    id = "AsepriteMcpStatus",
    title = "MCP Bridge: Status",
    group = "file_scripts",
    onclick = function()
      app.alert{ title = "Aseprite MCP Bridge", text = statusText() }
    end,
  }

  if plugin.preferences.autoConnect then
    start()
  end
end

function exit(plugin)
  stop()
end
