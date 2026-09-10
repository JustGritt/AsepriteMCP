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
-- unbidden, and this is meant to be read at a glance. They are also appended to
-- %TEMP%/aseprite-mcp-probe.txt so the answers survive dismissing the alert.

local REPORT = app.fs.joinPath(app.fs.tempPath, "aseprite-mcp-probe.txt")

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

--- Write the report out. Called only from top level or from a button, never
--- from the Timer: Aseprite's Security modal never paints if it is raised from
--- inside a timer callback, and the whole run would wedge behind it.
local function writeReport()
  local ok = pcall(function()
    local file = assert(io.open(REPORT, "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
  end)
  return ok
end

record("apiVersion " .. tostring(app.apiVersion), true, tostring(app.version))
record("isUIAvailable", app.isUIAvailable == true, tostring(app.isUIAvailable))

if not app.isUIAvailable then
  print(table.concat(lines, "\n"))
  print("\nNo UI: rerun without -b.")
  return
end

-- Settle the Security grant now, at top level, so the writes from inside the
-- Timer later cannot raise a modal from a place where it would never paint.
record("report file writable", writeReport(), REPORT)

local dlg = Dialog{ title = "MCP probe" }
record("Dialog{} constructed", dlg ~= nil, type(dlg))
if not dlg then
  writeReport()
  app.alert{ title = "MCP probe", text = lines }
  return
end

probe("widgets build", function()
  dlg:label{ id = "status", label = "Status:", text = "Connected" }
  dlg:entry{ id = "host", label = "Server:", text = "127.0.0.1" }
  dlg:number{ id = "port", text = "32145", decimals = 0 }
  -- Question 4 below reads these two back without the user touching anything.
  dlg:number{ id = "portEmpty", label = "Empty port:", text = "", decimals = 0 }
  dlg:number{ id = "portJunk", label = "Junk port:", text = "abc", decimals = 0 }
  -- Question 5: does the UI font carry these, or are they missing-glyph boxes?
  dlg:label{ id = "glyphs", label = "Glyphs:", text = "dot=\u{25CF} ring=\u{25CB} ok" }
  -- Deliberately short at build time; the Timer widens it to see what happens.
  dlg:label{ id = "long", label = "Long:", text = "short" }
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

-- Question 4: what does a number widget hand back for empty and for garbage?
-- The dialog's Reconnect validates dlg.data.port, and 0 is truthy in Lua, so a
-- naive `tonumber(x) or DEFAULT` chain would cheerfully dial ws://host:0/.
probe("number widget bad input", function()
  local empty, junk = dlg.data.portEmpty, dlg.data.portJunk
  return string.format("empty=%s (%s)  junk=%s (%s)",
    tostring(empty), type(empty), tostring(junk), type(junk))
end)

-- Question 6: can bounds be read and restored? Re-invoking the menu command has
-- to close and rebuild the dialog to bring it to front, and that is only
-- acceptable if it comes back where the user left it.
probe("dlg.bounds readable", function()
  local b = dlg.bounds
  if not b then return false end
  return string.format("x=%s y=%s w=%s h=%s", b.x, b.y, b.width, b.height)
end)

-- Question 2: is modify safe from a Timer tick, which is where the real refresh
-- will run from? And question 7: does widening a label's text reflow the window
-- or just clip? Fires a handful of times, then reports.
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

      probe("long modify: reflow or clip", function()
        local before = dlg.bounds
        dlg:modify{ id = "long",
          text = "a very long line that is far wider than the placeholder it replaced" }
        local after = dlg.bounds
        return string.format("w %s -> %s (%s)", before.width, after.width,
          after.width == before.width and "clipped, no relayout" or "RELAYOUT")
      end)

      -- It relayouts. So: does it shrink back too, and can the window be pinned?
      -- The status readout changes text on every command handled, and a dialog
      -- that resizes itself a few times a second is unusable.
      probe("short modify: shrinks back?", function()
        local before = dlg.bounds
        dlg:modify{ id = "long", text = "short" }
        local after = dlg.bounds
        return string.format("w %s -> %s (%s)", before.width, after.width,
          after.width < before.width and "SHRINKS" or "keeps the wider size")
      end)

      probe("dlg.bounds assignable", function()
        local pinned = dlg.bounds
        dlg:modify{ id = "long",
          text = "a very long line that is far wider than the placeholder it replaced" }
        local grown = dlg.bounds
        dlg.bounds = Rectangle(pinned.x, pinned.y, pinned.width, pinned.height)
        local restored = dlg.bounds
        return string.format("pin %s, grew to %s, restored to %s (%s)",
          pinned.width, grown.width, restored.width,
          restored.width == pinned.width and "PINNING WORKS" or "pin ignored")
      end)

      -- Digits are what actually move: "9 commands" -> "10 commands". If the UI
      -- font is proportional, even 1 -> 8 changes the width and the counter
      -- alone would jitter the window.
      probe("digit width is uniform", function()
        local widths = {}
        for _, text in ipairs({ "1111111111", "8888888888", "0000000000" }) do
          dlg:modify{ id = "long", text = text }
          widths[#widths + 1] = dlg.bounds.width
        end
        dlg:modify{ id = "long", text = "short" }
        return string.format("%s / %s / %s (%s)", widths[1], widths[2], widths[3],
          (widths[1] == widths[2] and widths[2] == widths[3])
            and "uniform" or "PROPORTIONAL")
      end)

      record("glyphs render?", true,
        "read the dialog's Glyphs row: boxes mean the UI font lacks them")
      writeReport()
      app.alert{ title = "MCP dialog probe", text = lines }
    end
  end,
}
timer:start()

if not returned then
  -- Only reachable if show blocked and then returned on close.
  record("show{wait=false} BLOCKED until closed", false,
    "the dialog cannot host a live status readout as designed")
  writeReport()
  app.alert{ title = "MCP dialog probe", text = lines }
end
