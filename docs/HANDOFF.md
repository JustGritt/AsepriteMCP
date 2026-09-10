# Handoff — next session

Written at the end of the session that landed `593bf03`. Read this before touching the
extension; the "Landmines" section is the part that saves the most time.

---

## Where things stand

Phases 1–5 of [ASEPRITE_MCP.md](ASEPRITE_MCP.md) are built, committed and verified end
to end. **33 MCP tools** drive a live Aseprite session over a loopback WebSocket.

| | |
| --- | --- |
| Commit | `593bf03` (on `main`, **not pushed** — pushes are the user's) |
| Python tests | 205 passing |
| Lua assertions | 144 passing, against the real engine |
| End-to-end | 34/34, the spec §29 workflow against a live Aseprite |
| Aseprite | 1.3.18.3, `apiVersion` 41, Steam build |

Nothing is known-broken. The MVP loop — edit, preview, analyze, correct — works, and the
contact sheet and onion skin were visually confirmed, not just asserted on.

```powershell
# Python suite
uv run pytest -q

# Lua suite, headless against the real engine
& "Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe" -b --script "tests\lua\run_tests.lua"

# Install the extension (junctions %APPDATA%\Aseprite\extensions\aseprite-mcp at the repo)
.\scripts\install-extension.ps1
```

Layout, protocol and tool reference live in [ARCHITECTURE.md](ARCHITECTURE.md),
[PROTOCOL.md](PROTOCOL.md) and [TOOLS.md](TOOLS.md); setup and the env vars are in
[SETUP.md](SETUP.md).

---

## Next task: a real connect dialog

**Decided with the user.** Today the only connection UI is two entries under
`File > Scripts` — a `Start/Stop` toggle and a `Status` item that fires an `app.alert`
with a wall of text. Host and port can *only* be changed with environment variables,
which is close to useless for an Aseprite launched from Steam. Replace both with one
non-modal dialog:

```text
┌─ Aseprite MCP Bridge ──────────────┐
│                                    │
│  Status:  ● Connected              │
│  Server:  [127.0.0.1] : [32145]    │
│  Files:   ● Trusted                │
│  Handled: 214 commands (0 failed)  │
│                                    │
│  [x] Connect automatically         │
│                                    │
│  [ Disconnect ]  [ Reconnect ]     │
│                                    │
└────────────────────────────────────┘
```

### Behaviour

- **Live status.** `Status`, `Files` and `Handled` update while the dialog is open. The
  pump already ticks at 1/60 and already has an idle hook (`queue.setIdleHook`), so drive
  the refresh from there — do **not** add a second `Timer`. Throttle to ~4 Hz; repainting
  sixty times a second to move a command counter is waste.
- **Editable host and port.** Applied on `Reconnect`, persisted in `plugin.preferences`,
  which outrank the env vars — so the field must say when it is shadowing one. See
  [Decisions](#settled-preferences-win-over-the-environment).
- **`Connect automatically`** replaces today's implicit coupling between the Start/Stop
  toggle and `preferences.autoConnect`.
- **Files: Trusted / Not trusted** surfaces `fsio.canWrite()`. This is the single most
  common failure a user will hit — previews and saves fail without the Security grant —
  and right now nothing tells them except a failed tool call. Put the remedy in the
  dialog when it reads Not trusted.
- **One dialog instance.** Re-invoking the menu command should focus the existing dialog
  rather than stacking a second one; keep a module-level handle and clear it in `onclose`.

### Files

| File | Change |
| --- | --- |
| `extension/aseprite-mcp/dialog.lua` | **New.** Widget construction and refresh. |
| `extension/aseprite-mcp/main.lua` | Replace the two `plugin:newCommand` blocks with one `MCP Bridge...` command; keep `exit()` closing the dialog. |
| `extension/aseprite-mcp/ws.lua` | Add `M.setTarget{host, port}` and the precedence chain. `readTarget()` currently re-reads env on every `openSocket()` and would clobber a dialog edit. |
| `tests/lua/run_tests.lua` | Cover the view model only — see below. |
| `docs/SETUP.md` | Rewrite the connection section around the dialog. |

### Structure it so it can be tested

The headless harness runs under `-b`, where **there is no `Dialog`** (see Landmines).
So split the module:

- a **pure view model** — `(ws.status(), queue.stats(), fsio.canWrite())` mapped to
  `{statusText, statusOk, filesText, filesOk, handledText}`, with no `Dialog` reference
  at all, and
- a **thin widget layer** that only maps those fields onto `dlg:modify{}` calls.

The view model is then testable in `run_tests.lua` exactly like every other module, and
the untestable surface shrinks to widget wiring that a single manual click confirms.

---

## What I verified about `Dialog`, and what I did not

Verified by probe on 1.3.18.3 / apiVersion 41:

- **In batch mode `Dialog{...}` returns `nil`. It does not raise.** `app.isUIAvailable` is
  `false` there, and the constructor answers with a silent `nil`, so the failure surfaces
  later as `attempt to index a nil value (upvalue 'dlg')` at the first `dlg:label{}`.
  Guard on `app.isUIAvailable` before constructing, and never let a `nil` dialog reach the
  refresh path.

Not verified — **do these first, in the GUI, before writing the real module**:

1. Does `dlg:show{ wait = false }` genuinely return control so the pump keeps running?
   The whole design assumes a non-modal dialog. If `show` blocks, the bridge goes deaf
   while the dialog is open and the layout has to change.
2. Is `dlg:modify{}` safe from inside a `Timer` tick? It is the same UI thread that
   already runs all `app.*` work, so it should be — but "should be" is what the
   Landmines list below is made of.
3. Does `dlg.data.<id>` read back live edits from `entry` and `number` before the dialog
   is closed? `Reconnect` depends on it.

`tests/lua/probe_dialog.lua` answers all three. Run it under the **GUI**, not `-b`:

```powershell
& "Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe" --script "tests\lua\probe_dialog.lua"
```

It reports through `app.alert` rather than `print`, because `print` opens the Console
window unbidden. Expect one alert; if `show{wait=false}` blocks, you get a different alert
saying so only after you close the dialog, which is itself the answer.

---

## Decisions

### Settled: preferences win over the environment

```text
plugin.preferences  >  ASEPRITE_MCP_HOST / _PORT  >  built-in default
```

A value typed into the dialog is the more deliberate act, and an env var is invisible to
someone running Aseprite from Steam. The cost is that a scripted `ASEPRITE_MCP_PORT` can
be silently ineffective, so the dialog has to *show* when it is shadowing one — annotate
the field (`env: 32200 — overridden`) rather than letting the user wonder why their
variable did nothing.

**The trap in implementing this:** an unset preference must fall through to the env var,
so "unset" and "set to the default value" cannot be the same state. Do **not** seed the
preference at first run. `main.lua` currently does exactly that for `autoConnect`:

```lua
if plugin.preferences.autoConnect == nil then
  plugin.preferences.autoConnect = true
end
```

That pattern is right for a boolean with no env equivalent and **wrong** for host and
port. Copying it would write `127.0.0.1` / `32145` into preferences on first launch, which
then outranks the env var forever — and the symptom is `ASEPRITE_MCP_PORT` being ignored
on a machine where it used to work. Leave host and port `nil` until the user edits them,
and treat `nil` as "not set" in the precedence chain.

Concretely, `ws.lua` keeps an override slot that starts empty:

```lua
-- Precedence: explicit override (from plugin.preferences, set via the dialog),
-- then the environment, then the built-in default. An empty override is not the
-- same as one holding the default value -- see docs/HANDOFF.md.
local override = { host = nil, port = nil }

local function readTarget()
  return {
    host = override.host or env("ASEPRITE_MCP_HOST", DEFAULT_HOST),
    port = override.port or tonumber(env("ASEPRITE_MCP_PORT", "")) or DEFAULT_PORT,
    token = env("ASEPRITE_MCP_TOKEN", ""),
  }
end
```

`main.lua` pushes the stored preferences in via `ws.setTarget{...}` at `init`, and the
dialog calls the same setter on `Reconnect`. `ws.status()` should also report which source
won, so the dialog can render the annotation without duplicating the precedence logic.

### Still open

- **Whether the dialog should offer a token field.** Token auth is off by default and the
  token has to match the server's. A field invites a mismatch that presents as an
  unexplained failed handshake, so leaving it env-only is defensible.

---

## Landmines

Every one of these was found the hard way. They are all documented at their site in the
code as well; this is the index.

- **`json.decode` returns *userdata*, not a table.** Indexing, `pairs`, `ipairs` and `#`
  all work on it, so it looks like a table right up until a `type(x) == "table"` check
  rejects it. That check is what made the bridge accept connections and then ignore every
  request, with no error anywhere. Use `proto.isStructured()`. The Lua tests drive raw
  JSON through `queue.handleRaw` specifically so a decoding bug cannot hide again.
- **Aseprite's Security modal fails closed, and `app.fs.isFile` does not prompt** — it
  just returns `false` for an un-granted path. Any design that discovers something by
  reading a file is unbuildable. All filesystem contact goes through `fsio.lua` so exactly
  one prompt appears, primed at extension load.
- **A modal raised from inside a `Timer` callback never paints** and wedges the bridge.
  That is why file access is settled at load rather than on demand.
- **`onreceive` must never touch `app.*`** — it only enqueues, and the `Timer` drains.
  This also keeps the message loop awake so commands still land while Aseprite is
  unfocused.
- **`frame.duration` is in seconds**; the whole MCP surface is milliseconds. Convert only
  at the Lua boundary.
- **`image:resize` has no nearest-neighbour mode.** Bilinear blurs every preview and
  destroys the visual loop. `render.lua` upscales by row blit instead.
- **`Dialog{}` returns `nil` under `-b`.** See above.
- **`extension/aseprite-mcp/__pref.lua` is Aseprite's own state**, not source. The dev
  install junctions the extensions dir at the repo, so the editor writes into the working
  tree. It is gitignored; keep it that way.
- **Ordering when testing by hand:** start the server first, then Aseprite. Killing
  Aseprite while a driver is attached, or starting a driver while a stale Aseprite is
  still running, both present as a misleading `ASEPRITE_NOT_CONNECTED`.

### Debug tracing

`ASEPRITE_MCP_DEBUG=1` turns on `trace.lua`, the pump heartbeat and per-event socket
tracing, writing to `%TEMP%/aseprite-mcp-debug.log`. Silent and off by default. This is
what made the `json.decode` bug visible; leave it in.

Full env var list: `ASEPRITE_MCP_HOST`, `_PORT`, `_TOKEN`, `_REQUIRE_TOKEN`,
`_ALLOWED_DIRS`, `_ALLOW_NON_LOOPBACK`, `_TIMEOUT`, `_RENDER_TIMEOUT`, `_MAX_PIXELS`,
`_MAX_REGION_PIXELS`, `_LOG_LEVEL`, `_DEBUG`.

---

## Deferred, still deferred

Phase 6 — `compare_frames`, `shift_cel`, `copy_cel`, `flip_cel`, `get_used_palette`,
`get_animation_bounds`, `get_history_info`.

Edit transactions (`begin_edit` / `commit_edit` / `rollback_edit`, spec §16) stay deferred
on purpose. The obvious implementation — count transactions since `begin_edit`, then call
`app.undo()` that many times — silently undoes the user's manual work if they touch
Aseprite mid-transaction. Doing it safely needs a `sprite.events:on('change')` watcher,
and aseprite/aseprite#4997 reports crashes when calling `undo` inside a `change` handler.
Per-call transactions already give the agent clean single-step undo.
