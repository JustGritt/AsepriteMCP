-- Builds the command dispatch table from the individual modules.
--
-- Kept separate from main.lua so the headless Lua test harness can construct the
-- exact same handlers without a plugin, a Timer or a WebSocket.

local SCRIPT_DIR = app.fs.filePath(debug.getinfo(1, "S").source:sub(2))

local function loadModule(name)
  return dofile(app.fs.joinPath(SCRIPT_DIR, name))
end

return function()
  local proto = loadModule("protocol.lua")

  local color = loadModule("color.lua")
  color.setProtocol(proto)

  local doc = loadModule("doc.lua")
  doc.setProtocol(proto)

  local render = loadModule("render.lua")

  -- Every filesystem operation in the extension goes through this one module so
  -- Aseprite only ever raises its Security prompt for a single script file.
  local fsio = loadModule("fsio.lua")

  local rigstore = loadModule("rigstore.lua")

  local deps = {
    proto = proto, doc = doc, color = color, render = render, fsio = fsio, rigstore = rigstore,
  }

  local dispatch = {}
  local groups = {
    "commands/sprite.lua",
    "commands/layers.lua",
    "commands/frames.lua",
    "commands/drawing.lua",
    "commands/cels.lua",
    "commands/inspection.lua",
    "commands/animation.lua",
    "commands/history.lua",
    "commands/rig.lua",
    "commands/image.lua",
  }
  for _, path in ipairs(groups) do
    local commands = loadModule(path)(deps)
    for name, handler in pairs(commands) do
      if dispatch[name] then
        error("duplicate command registration: " .. name)
      end
      dispatch[name] = handler
    end
  end
  -- Registered last, because a batch dispatches to every other command.
  for name, handler in pairs(loadModule("commands/batch.lua")(deps, dispatch)) do
    dispatch[name] = handler
  end

  return {
    proto = proto,
    color = color,
    doc = doc,
    render = render,
    fsio = fsio,
    dispatch = dispatch,
    loadModule = loadModule,
    scriptDir = SCRIPT_DIR,
  }
end
