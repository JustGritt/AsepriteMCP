-- The connect dialog.
--
-- Split in two on purpose, because half of this file is untestable. The headless
-- harness runs under -b, where there is no UI and Dialog{} returns *nil* rather
-- than raising -- the failure only surfaces later as "attempt to index a nil
-- value" at the first widget call. So:
--
--   * M.viewModel and M.displayText are pure. They take a status table, a stats
--     table, a boolean and a clock, and return strings. No Dialog, no deps.
--     run_tests.lua exercises them with literal tables like any other module.
--   * everything below the widget banner touches Dialog and cannot be tested
--     headless at all. It is kept as thin as possible for that reason: it maps
--     the strings above onto dlg:modify{} calls and wires five callbacks.
--
-- Three behaviours here were verified by probe on 1.3.18.3 / apiVersion 41 and
-- are load-bearing; tests/lua/probe_dialog.lua re-checks all of them:
--
--   * dlg:show{ wait = false } returns control, so the pump keeps running.
--   * dlg:modify{} is safe from inside a Timer tick, which is where refreshes
--     come from.
--   * modifying a label's text RELAYOUTS the window, growing and shrinking it.
--     Since "Handled: 214 commands" changes text on every command, the dialog
--     would visibly jitter. dlg.bounds is assignable, so the size is pinned.

-- The pump runs at 1/60, so this is about 4 Hz. Repainting sixty times a second
-- to move a counter is waste.
local REFRESH_EVERY_TICKS = 15

-- ...but never let the cadence hide work: under a burst the pump's 0.15s tick
-- budget stretches fifteen ticks toward two seconds, which is exactly when the
-- counter is worth watching. A changed counter refreshes sooner, but not faster
-- than this.
local MIN_TICKS_ON_CHANGE = 4

-- Errors are truncated here rather than left to the window, because the window
-- is pinned and would simply clip them at an arbitrary point.
local ERROR_MAX = 58

-- Every label that can grow is built at this width and the window is pinned to
-- the result, so nothing after that resizes it.
local WIDEST_LINE = "No server at 255.255.255.255:65535 - is the MCP server running?"

local DOT_OK = "\u{25CF}"
local DOT_BAD = "\u{25CB}"

return function(deps)
  local ws = deps.ws
  local queue = deps.queue
  local fsio = deps.fsio
  local trace = deps.trace

  local M = {}

  -- ------------------------------------------------------------- view model (pure)

  local function truncate(text, limit)
    text = tostring(text)
    if #text <= limit then return text end
    return text:sub(1, limit - 3) .. "..."
  end

  local function commands(n)
    return string.format("%d %s", n, n == 1 and "command" or "commands")
  end

  --- Which environment values a preference is currently shadowing.
  ---
  --- Only counts a differing value: annotating "env: 32145 - overridden" when
  --- the preference happens to match the variable would be noise.
  local function shadowedEnv(status)
    local shadowed = {}
    if status.hostSource == "preference"
      and status.envHost and status.envHost ~= status.host then
      shadowed[#shadowed + 1] = status.envHost
    end
    if status.portSource == "preference"
      and status.envPort and status.envPort ~= tostring(status.port) then
      shadowed[#shadowed + 1] = status.envPort
    end
    return shadowed
  end

  local function serverNote(status)
    -- A resolved target the live socket is not on yet. Only reachable if
    -- setTarget is called without reconnecting, but saying nothing there would
    -- mean the dialog reports a server it is not talking to.
    if status.connected and status.activeHost
      and (status.activeHost ~= status.host or status.activePort ~= status.port) then
      return string.format("on %s:%s - press Reconnect to apply",
        status.activeHost, tostring(status.activePort))
    end

    -- Set but unusable. Reporting this as a plain fallback to the default is
    -- what makes someone ask why their ASEPRITE_MCP_PORT did nothing.
    if status.portSource == "environment-invalid" then
      return string.format("env: %s - not a number, ignored", tostring(status.envPort))
    end

    local shadowed = shadowedEnv(status)
    if #shadowed > 0 then
      return "env: " .. table.concat(shadowed, ":") .. " - overridden"
    end
    return ""
  end

  local function statusHint(status, now)
    if not status.enabled or status.connected then return "" end
    -- The common failure -- no server listening -- leaves lastError nil.
    -- WebSocket{} construction succeeds and the dial fails asynchronously, and
    -- onreceive only ever sees OPEN/TEXT/CLOSE, so there is nothing to report
    -- unless the dialog says it itself.
    if status.lastError then return "" end
    if not status.lastAttempt or (now - status.lastAttempt) < 3 then return "" end
    return string.format("No server at %s:%s - is the MCP server running?",
      tostring(status.host), tostring(status.port))
  end

  --- Map the three live sources onto display strings. Pure: no deps, no Dialog.
  function M.viewModel(status, stats, canWrite, now)
    now = now or os.time()

    local statusText, statusOk
    if not status.enabled then
      statusText, statusOk = "Disconnected", false
    elseif status.connected then
      statusText, statusOk = "Connected", true
    else
      statusText, statusOk = "Connecting...", false
    end

    return {
      statusText = statusText,
      statusOk = statusOk,
      statusHint = statusHint(status, now),

      serverNote = serverNote(status),

      filesText = canWrite and "Trusted" or "Not trusted",
      filesOk = canWrite and true or false,
      -- The single most common thing a user hits: without the Security grant
      -- every preview and save fails, and nothing else tells them.
      filesHint = canWrite and ""
        or "Previews and saves will fail - see docs/SETUP.md section 3.",

      -- Read-only. The token stays environment-only by design, but a mismatched
      -- one opens the socket and immediately closes it again, which is
      -- indistinguishable from "no server" without this line.
      tokenText = status.usingToken and "on (environment)" or "off",

      -- What an agent selects this window by when one server holds several.
      instanceText = status.instanceName
        and string.format("%s (%s)", status.instanceName, tostring(status.instance))
        or tostring(status.instance or "?"),

      handledText = string.format("%s (%d failed)",
        commands(stats.handled), stats.failed),

      toggleText = status.enabled and "Disconnect" or "Connect",

      -- Only while something is actually trying. A stale dial error beside a
      -- live connection reads as a current problem, and beside a deliberate
      -- Disconnect it reads as a failure the user did not cause.
      errorText = (status.lastError and status.enabled and not status.connected)
        and truncate(status.lastError, ERROR_MAX) or "",
    }
  end

  --- Compose the final widget strings, keyed by widget id.
  ---
  --- Separate from viewModel so the status markers are decided in one place: if
  --- a future Aseprite build stops rendering these glyphs, this is the only
  --- line that changes.
  function M.displayText(vm)
    return {
      status = (vm.statusOk and DOT_OK or DOT_BAD) .. " " .. vm.statusText,
      statusHint = vm.statusHint,
      serverNote = vm.serverNote,
      files = (vm.filesOk and DOT_OK or DOT_BAD) .. " " .. vm.filesText,
      filesHint = vm.filesHint,
      token = vm.tokenText,
      instance = vm.instanceText,
      handled = vm.handledText,
      toggle = vm.toggleText,
      error = vm.errorText,
    }
  end

  -- ----------------------------------------------------------------------- widgets

  local dlg = nil
  local prefs = nil
  local onPumpChange = nil
  local rendered = {}
  local pinned = nil
  local ticks = 0
  local lastCounters = nil
  -- A validation message the refresh must not clobber. Writing one straight to
  -- the widget would put it on screen for at most a quarter of a second, since
  -- the next refresh overwrites the same label from the view model.
  local pendingMessage = nil

  --- The plugin.preferences table. Handed in from init(plugin) so ws.lua and
  --- this module never learn that `plugin` exists.
  function M.setPreferences(value) prefs = value end

  --- main.lua's syncPump, called whenever the dialog opens or closes: the pump
  --- has to keep running while the dialog is up, or its refresh stops.
  function M.setPumpHook(fn) onPumpChange = fn end

  function M.isOpen() return dlg ~= nil end

  local function pumpChanged()
    if onPumpChange then pcall(onPumpChange) end
  end

  local function apply(texts)
    local changed = false
    for id, text in pairs(texts) do
      if rendered[id] ~= text then
        local ok, err = pcall(function() dlg:modify{ id = id, text = text } end)
        if not ok then
          -- A stale handle throwing once per tick would append to the debug log
          -- sixty times a second, so abandon the dialog rather than the modify.
          if trace then trace.writef("dialog modify failed on %s: %s", id, tostring(err)) end
          dlg, rendered, pinned = nil, {}, nil
          return false
        end
        rendered[id] = text
        changed = true
      end
    end
    return changed
  end

  local function repin()
    if not (dlg and pinned) then return end
    local ok = pcall(function()
      local b = dlg.bounds
      if b.width ~= pinned.width or b.height ~= pinned.height then
        -- Width and height only: a dialog the user has dragged somewhere stays
        -- where they put it.
        dlg.bounds = Rectangle(b.x, b.y, pinned.width, pinned.height)
      end
    end)
    if not ok then pinned = nil end
  end

  function M.refresh()
    if not dlg then return end
    local vm = M.viewModel(ws.status(), queue.stats(), fsio.canWrite(), os.time())
    local texts = M.displayText(vm)
    if pendingMessage then texts.error = pendingMessage end
    if apply(texts) then repin() end
  end

  --- Called from the pump's idle hook, so there is exactly one Timer.
  function M.tick()
    if not dlg then return end
    ticks = ticks + 1
    local stats = queue.stats()
    local counters = stats.handled + stats.failed
    local due = ticks >= REFRESH_EVERY_TICKS
      or (counters ~= lastCounters and ticks >= MIN_TICKS_ON_CHANGE)
    if not due then return end
    ticks, lastCounters = 0, counters
    M.refresh()
  end

  function M.close()
    local handle = dlg
    if not handle then return end
    -- onclose fires during close(), so by the time this returns dlg is already
    -- nil and clearing it again is the safe, not the redundant, thing to do.
    pcall(function() handle:close() end)
    dlg, rendered, pinned = nil, {}, nil
  end

  local function onToggle()
    local turningOn = not ws.isEnabled()
    pendingMessage = nil
    ws.setEnabled(turningOn)
    -- Before connecting, so the pump is already draining when the socket opens.
    pumpChanged()
    if turningOn then ws.connect() end
    M.refresh()
  end

  local function showError(message)
    pendingMessage = truncate(message, ERROR_MAX)
    M.refresh()
  end

  --- Put back what was actually applied, which is not always what was typed:
  --- clearing a field falls through to the environment or the default.
  ---
  --- Safe to write here and nowhere else. The user has just pressed Reconnect,
  --- so this is feedback rather than the refresh path stomping live typing.
  local function writeBackTarget()
    local applied = ws.status()
    pcall(function()
      dlg:modify{ id = "host", text = tostring(applied.host) }
      dlg:modify{ id = "port", text = tostring(applied.port) }
    end)
    repin()
  end

  local function onReconnect()
    pendingMessage = nil
    local host, port
    local read = pcall(function() host, port = dlg.data.host, dlg.data.port end)
    if not read then return end

    -- Persist only what actually differs from what the environment and the
    -- default would resolve to on their own. Writing back a value the user never
    -- touched would silently promote it to a preference and shadow
    -- ASEPRITE_MCP_HOST forever -- the exact failure docs/HANDOFF.md warns
    -- about, whose symptom is an env var being ignored on a machine where it
    -- used to work.
    local status = ws.status()
    local base = ws.resolve(nil, nil, status.envHost, status.envPort)
    local wantHost = (host ~= nil and host ~= "" and host ~= base.host) and host or nil
    local wantPort = (port ~= base.port) and port or nil

    local ok, err = ws.setTarget{ host = wantHost, port = wantPort }
    if not ok then
      -- Rendered in place rather than through app.alert. A modal raised from a
      -- button handler is not the Timer case that wedges the bridge and would
      -- probably paint, but there is no reason to find out.
      showError("Cannot apply: " .. err)
      return
    end

    if prefs then
      prefs.host = wantHost
      prefs.port = wantPort
    end

    ws.setEnabled(true)
    pumpChanged()
    ws.connect()
    writeBackTarget()
    M.refresh()
  end

  local function onAutoConnect()
    if not prefs then return end
    pcall(function() prefs.autoConnect = dlg.data.auto and true or false end)
  end

  --- Open the dialog, or bring the existing one back to the front.
  function M.open()
    -- Aseprite exposes no raise API and show{} on an already-shown dialog is
    -- undefined, so the only way to front an existing one is to rebuild it where
    -- it stood. One frame of flicker beats a menu item that appears to do
    -- nothing.
    local where = nil
    if dlg then
      pcall(function() where = dlg.bounds end)
      M.close()
    end

    if not app.isUIAvailable then return false end

    local built = Dialog{
      title = "Aseprite MCP Bridge",
      onclose = function()
        dlg, rendered, pinned = nil, {}, nil
        pumpChanged()
      end,
    }
    -- Under -b this is nil rather than an error. Letting it through would fail
    -- later and elsewhere, at the first dlg:label{}.
    if not built then return false end
    dlg = built

    local status = ws.status()

    dlg:label{ id = "status", label = "Status:", text = DOT_BAD .. " Disconnected" }
    dlg:label{ id = "statusHint", label = "", text = WIDEST_LINE }
    dlg:entry{ id = "host", label = "Server:", text = tostring(status.host) }
    dlg:number{ id = "port", text = tostring(status.port), decimals = 0 }
    dlg:label{ id = "serverNote", label = "", text = WIDEST_LINE }
    dlg:label{ id = "files", label = "Files:", text = DOT_BAD .. " Not trusted" }
    dlg:label{ id = "filesHint", label = "", text = WIDEST_LINE }
    dlg:label{ id = "token", label = "Token:", text = "off" }
    dlg:label{ id = "instance", label = "Instance:", text = tostring(status.instance or "?") }
    dlg:label{ id = "handled", label = "Handled:", text = "0 commands (0 failed)" }
    dlg:label{ id = "error", label = "", text = WIDEST_LINE }
    dlg:check{
      id = "auto",
      text = "Connect automatically",
      selected = (prefs and prefs.autoConnect) and true or false,
      onclick = onAutoConnect,
    }
    -- Built with the longer caption so flipping to "Connect" cannot clip it.
    dlg:button{ id = "toggle", text = "Disconnect", onclick = onToggle }
    dlg:button{ id = "reconnect", text = "Reconnect", onclick = onReconnect }

    dlg:show{ wait = false }

    -- Captured while every growable label still holds its widest placeholder, so
    -- the pinned size fits the worst case. The refresh below then writes the
    -- real, shorter strings and repin() restores this size.
    pcall(function() pinned = dlg.bounds end)
    if where and pinned then
      pcall(function()
        dlg.bounds = Rectangle(where.x, where.y, pinned.width, pinned.height)
      end)
    end

    -- Synchronous, so the dialog is correct even when the pump has never
    -- started -- which is exactly the case when autoConnect is off.
    rendered = {}
    M.refresh()
    pumpChanged()
    return true
  end

  return M
end
