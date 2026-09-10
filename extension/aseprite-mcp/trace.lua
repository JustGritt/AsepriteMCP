-- Opt-in trace log.
--
-- The bridge runs inside a GUI application with no console, and errors in the
-- pump are deliberately swallowed so a bad command cannot kill the timer. That
-- combination makes silent failure the default, so there has to be somewhere to
-- look. Set ASEPRITE_MCP_DEBUG=1 in the environment Aseprite is launched from
-- and the bridge appends to %TEMP%/aseprite-mcp-debug.log.
--
-- Writes go through fsio so they are attributed to the same script as every
-- other file operation, keeping the Security prompt down to one.

return function(deps)
  local fsio = deps.fsio
  local M = {}

  local enabled = false
  do
    local flag = os.getenv and os.getenv("ASEPRITE_MCP_DEBUG")
    enabled = flag ~= nil and flag ~= "" and flag ~= "0"
  end

  local path = app.fs.joinPath(app.fs.tempPath, "aseprite-mcp-debug.log")

  function M.isEnabled() return enabled end
  function M.path() return path end

  function M.write(text)
    if not enabled then return end
    fsio.appendText(path, string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(text)))
  end

  function M.writef(fmt, ...)
    if not enabled then return end
    M.write(string.format(fmt, ...))
  end

  return M
end
