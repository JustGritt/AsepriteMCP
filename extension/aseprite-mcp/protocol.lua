-- Wire protocol helpers. Mirrors src/aseprite_mcp/bridge/protocol.py.

local M = {}

-- Kept in sync with ErrorCode in bridge/protocol.py.
M.ERROR = {
  NO_ACTIVE_SPRITE = "NO_ACTIVE_SPRITE",
  INVALID_FRAME = "INVALID_FRAME",
  INVALID_LAYER = "INVALID_LAYER",
  INVALID_PARAMS = "INVALID_PARAMS",
  PATH_NOT_ALLOWED = "PATH_NOT_ALLOWED",
  DOCUMENT_LOCKED = "DOCUMENT_LOCKED",
  UNSUPPORTED_COLOR_MODE = "UNSUPPORTED_COLOR_MODE",
  TOO_MANY_PIXELS = "TOO_MANY_PIXELS",
  UNKNOWN_COMMAND = "UNKNOWN_COMMAND",
  PROTOCOL_ERROR = "PROTOCOL_ERROR",
  LUA_ERROR = "LUA_ERROR",
}

-- Empty Lua tables encode as {} rather than [], which would make an empty list
-- of tags or layers decode as an object on the Python side. Tagging arrays with
-- this metatable lets M.encode() rewrite them to a real empty JSON array.
local EMPTY_ARRAY = {}
M.EMPTY_ARRAY = EMPTY_ARRAY

-- Marks t as a JSON array so an empty one survives the round trip.
function M.array(t)
  t = t or {}
  if #t == 0 then return EMPTY_ARRAY end
  return t
end

--- True for anything that behaves like a table for indexing and iteration.
--
-- json.decode does NOT return a table: it returns *userdata* that merely acts
-- like one (indexing, pairs, ipairs and # all work on it). A plain
-- type(x) == "table" check therefore rejects every decoded message, which is
-- exactly how the bridge came to accept connections and then silently ignore
-- every request sent over them.
function M.isStructured(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

--- Raise a structured error from inside a command handler.
-- Handlers run under pcall, so this is how they report an expected failure
-- (a bad frame number) as opposed to a Lua bug.
function M.fail(code, message)
  error({ __mcp = true, code = code, message = message }, 0)
end

function M.failf(code, fmt, ...)
  M.fail(code, string.format(fmt, ...))
end

--- Turn whatever pcall caught into an error table.
function M.toError(err)
  if type(err) == "table" and err.__mcp then
    return { code = err.code, message = err.message }
  end
  return { code = M.ERROR.LUA_ERROR, message = tostring(err) }
end

local function substituteEmptyArrays(text)
  -- json.encode has no notion of an empty array, so we encode a placeholder and
  -- rewrite it afterwards. The placeholder is deliberately unlikely to collide.
  return (text:gsub('{"__emptyArray":true}', "[]"))
end

local function prepare(value)
  if value == EMPTY_ARRAY then return { __emptyArray = true } end
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = prepare(v) end
  return out
end

function M.encode(value)
  return substituteEmptyArrays(json.encode(prepare(value)))
end

function M.successMessage(id, result)
  return M.encode({ id = id, ok = true, result = result or {} })
end

function M.errorMessage(id, err)
  return M.encode({ id = id, ok = false, error = err })
end

return M
