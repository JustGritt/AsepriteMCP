-- Probes the Dialog API behaviours the connect dialog depends on.
--
-- Run this in the GUI, NOT with -b:
--
--   & "Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe" `
--       --script "tests\lua\probe_dialog.lua"
--
-- Under -b there is no UI at all and Dialog{} returns nil rather than raising,
-- so a batch run would only re-confirm that one already-known fact.
--
-- Results go to app.alert rather than print: print opens the Console window
-- unbidden, and this is meant to be read at a glance.

local lines = {}

local function record(label, ok, detail)
  lines[#lines + 1] = string.format("%s %s%s",
    ok and "[ok]" or "[!!]",
    label,
    detail and ("  -- " .. tostring(detail)) or "")
end

local function probe(label, fn)
  local ok, result = pcall(fn)
  record(label, ok and result ~= false, ok and result or result)
  return ok and result
end

record("apiVersion " .. tostring(app.apiVersion), true, tostring(app.version))
record("isUIAvailable", app.isUIAvailable == true, tostring(app.isUIAvailable))

if not app.isUIAvailable then
  print(table.concat(lines, "\n"))
  print("\nNo UI: rerun without -b.")
  return
end

local dlg = Dialog{ title = "MCP probe" }
record("Dialog{} constructed", dlg ~= nil, type(dlg))
if not dlg then
  app.alert{ title = "MCP probe", text = lines }
  return
end

probe("widgets build", function()
  dlg:label{ id = "status", label = "Status:", text = "Connected" }
  dlg:entry{ id = "host", label = "Server:", text = "127.0.0.1" }
  dlg:number{ id = "port", text = "32145", decimals = 0 }
  dlg:check{ id = "auto", text = "Connect automatically", selected = true }
  dlg:button{ id = "close", text = "Close probe" }
  return "label/entry/number/check/button"
end)

-- Question 1: does a non-modal show return control? If this blocks, the whole
-- live-refresh design has to change, because the pump would stop while open.
local returned = false
probe("show{wait=false} returns", function()
  dlg:show{ wait = false }
  returned = true
  return "control returned"
end)

-- Question 3: are live edits readable before the dialog closes?
probe("dlg.data reads back", function()
  return string.format("host=%s port=%s auto=%s",
    tostring(dlg.data.host), tostring(dlg.data.port), tostring(dlg.data.auto))
end)

-- Question 2: is modify safe from a Timer tick, which is where the real
-- refresh will run from? Fires a handful of times, then reports.
local ticks = 0
local timer
timer = Timer{
  interval = 0.25,
  ontick = function()
    ticks = ticks + 1
    local ok, err = pcall(function()
      dlg:modify{ id = "status", text = "tick " .. ticks }
    end)
    if not ok or ticks >= 4 then
      timer:stop()
      record("modify{} from a Timer tick", ok, ok and (ticks .. " ticks applied") or err)
      app.alert{ title = "MCP dialog probe", text = lines }
    end
  end,
}
timer:start()

if not returned then
  -- Only reachable if show blocked and then returned on close.
  record("show{wait=false} BLOCKED until closed", false,
    "the dialog cannot host a live status readout as designed")
  app.alert{ title = "MCP dialog probe", text = lines }
end
