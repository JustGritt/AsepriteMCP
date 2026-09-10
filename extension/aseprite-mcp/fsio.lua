-- The single point of filesystem contact for the whole extension.
--
-- Aseprite gates script file access behind a Security prompt that names *the
-- calling .lua file* and the specific path it wants. If each module called
-- io.open or saveAs directly, the user would face a separate modal for every one
-- of them -- trace.lua, ws.lua, inspection.lua, animation.lua, sprite.lua -- and
-- a modal that appears mid-run blocks the bridge until someone clicks it.
--
-- Routing every filesystem operation through this one module means the prompt
-- names this file and only this file, so ticking "Give full trust to this
-- script" once covers previews, contact sheets, opening and saving.
--
-- Nothing here decides *whether* a path is allowed; the MCP server sandboxes
-- paths before they are ever sent (see src/aseprite_mcp/paths.py).

local M = {}

--- Read a whole file, or nil plus a reason.
function M.readText(path)
  local file, err = io.open(path, "r")
  if not file then return nil, tostring(err) end
  local text = file:read("a")
  file:close()
  return text
end

--- Write text, replacing any existing content.
function M.writeText(path, text)
  local file, err = io.open(path, "w")
  if not file then return false, tostring(err) end
  file:write(text)
  file:close()
  return true
end

function M.appendText(path, text)
  local file = io.open(path, "a")
  if not file then return false end
  file:write(text)
  file:close()
  return true
end

function M.exists(path)
  return app.fs.isFile(path)
end

function M.remove(path)
  os.remove(path)
end

local canWriteCache = nil

local function probeWrite()
  local path = app.fs.joinPath(app.fs.tempPath, "aseprite_mcp_write_probe.tmp")
  local ok = M.writeText(path, "ok")
  if ok then M.remove(path) end
  return ok
end

--- Can this extension write files at all? Cached after the first call.
function M.canWrite()
  if canWriteCache == nil then canWriteCache = probeWrite() end
  return canWriteCache
end

--- Touch the filesystem once, at extension load, to settle the permission.
--
-- Aseprite raises its Security modal the first time a script touches a file. That
-- modal must not be raised from inside the command pump: the pump runs inside the
-- UI message loop, and a modal opened from there never paints -- Aseprite simply
-- hangs with an invisible dialog and the bridge stops answering. Asking at load
-- time, before any timer exists, is where the dialog reliably appears (it is the
-- same moment the debug-log prompt shows up).
--
-- Tick "Give full trust to this script" and this never asks again; see
-- docs/SETUP.md.
function M.primeAccess()
  return M.canWrite()
end

--- Save an Image as a PNG.
function M.saveImage(image, path)
  image:saveAs(path)
  return app.fs.isFile(path)
end

--- Save a Sprite, keeping it associated with the file.
function M.saveSprite(sprite, path)
  sprite:saveAs(path)
  return app.fs.isFile(path)
end

--- Open a document.
function M.openSprite(path)
  return app.open(path)
end

return M
