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
local dialog = dofile(app.fs.joinPath(SCRIPT_DIR, "dialog.lua"))({
  ws = ws,
  queue = queue,
  fsio = core.fsio,
  trace = trace,
})

-- Nothing above may dial, resolve a target or construct a Dialog: this runs at
-- module load, before init(plugin) exists, so plugin.preferences -- which
-- outrank the environment -- have not been pushed in yet.

-- Settle file access now, at load, rather than from inside the pump. A Security
-- modal raised from a Timer callback never paints and hangs the bridge.
local canWriteFiles = core.fsio.primeAccess()

trace.writef("extension loaded (apiVersion=%s, commands=%d, canWriteFiles=%s)",
  tostring(app.apiVersion),
  (function() local n = 0 for _ in pairs(core.dispatch) do n = n + 1 end return n end)(),
  tostring(canWriteFiles))

queue.setSender(ws.send)

-- Fingerprinted at load, after primeAccess has settled file access, and sent
-- in every hello so the server can tell an outdated extension (#16).
if canWriteFiles then
  ws.setFingerprint(core.fsio.fingerprint(SCRIPT_DIR))
else
  ws.setFingerprint(nil, "no file access")
end

--- The pump owns the only Timer in the extension, and that Timer drives both the
--- socket poll and the dialog's refresh. So it runs while the bridge is dialling
--- *or* while the dialog is open, and nothing else may start or stop it.
---
--- Disconnect deliberately flips ws.setEnabled rather than calling queue.stop():
--- stopping the pump would also freeze the dialog and drop anything already
--- queued without a reply, which the server then sees as a timeout rather than a
--- clean disconnect.
local function syncPump()
  if ws.isEnabled() or dialog.isOpen() then
    queue.start()
  else
    queue.stop()
  end
end

-- One timer, one hook. Each branch is isolated so a reconnect hiccup cannot
-- freeze the dialog at a stale reading and a dialog bug cannot make the bridge
-- go deaf -- but both must trace, or this is quieter than the plain
-- setIdleHook(ws.poll) it replaces, where queue.lua reported the failure.
queue.setIdleHook(function()
  local polled, pollErr = pcall(ws.poll)
  if not polled then trace.writef("ws.poll error: %s", tostring(pollErr)) end
  local ticked, tickErr = pcall(dialog.tick)
  if not ticked then trace.writef("dialog tick error: %s", tostring(tickErr)) end
end)

function init(plugin)
  trace.write("init(plugin) called")

  if plugin.preferences.autoConnect == nil then
    -- Right for a boolean with no environment equivalent, and deliberately NOT
    -- done for host and port. Seeding those would write the built-in defaults
    -- into preferences on first launch, and preferences outrank
    -- ASEPRITE_MCP_HOST/_PORT -- so the variables would be shadowed forever, on
    -- a machine where they used to work. See docs/HANDOFF.md.
    plugin.preferences.autoConnect = true
  end

  -- Pushed in before anything dials.
  local ok, err = ws.setTarget{
    host = plugin.preferences.host,
    port = plugin.preferences.port,
  }
  if not ok then
    -- __pref.lua is a plain Lua file that both Aseprite and humans write, so a
    -- bad value can land here. Falling back to the environment and the default
    -- beats refusing to connect, and the dialog will rewrite it on the next
    -- Reconnect. Not printed: this is benign and self-healing, and print pops
    -- Aseprite's Console window on every launch.
    trace.writef("ignoring stored bridge target: %s", tostring(err))
  end

  dialog.setPreferences(plugin.preferences)
  dialog.setPumpHook(syncPump)

  ws.setEnabled(plugin.preferences.autoConnect and true or false)

  plugin:newCommand{
    id = "AsepriteMcpDialog",
    title = "MCP Bridge...",
    group = "file_scripts",
    onclick = function() dialog.open() end,
  }

  syncPump()
end

function exit(plugin)
  dialog.close()
  ws.setEnabled(false)
  queue.stop()
end
