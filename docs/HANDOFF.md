# Handoff — next session

Read this before touching the extension; the "Landmines" section is the part that
saves the most time.

---

## Where things stand

Phases 1–5 of [ASEPRITE_MCP.md](ASEPRITE_MCP.md) are built and verified end to
end, and the connect dialog that replaced the old menu entries is in.
**39 MCP tools** drive a live Aseprite session over a loopback WebSocket, on top
of 39 Lua commands. The mapping is not 1:1: `app.status` and `fs.probe` are called
by the server rather than exposed, and `draw_rows` / `draw_rect` are decoded into
`draw.pixels` server-side. Token-cost work is tracked in GitHub issue #10.

| | |
| --- | --- |
| Python tests | 296 passing |
| Lua assertions | 333 passing, against the real engine |
| End-to-end | 34/34 spec §29 workflow, from the session that landed `593bf03` |
| Aseprite | 1.3.18.3, `apiVersion` 41, Steam build |

```powershell
# Python suite
uv run pytest -q

# Lua suite, headless against the real engine
& "Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe" -b --script "tests\lua\run_tests.lua"
# ...the same on macOS (Steam build); `uv run pytest -m lua` also finds it
"$HOME/Library/Application Support/Steam/steamapps/common/Aseprite/Aseprite.app/Contents/MacOS/aseprite" -b --script tests/lua/run_tests.lua

# Dialog API probe -- GUI only, see "What Dialog actually does" below
& "Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe" --script "tests\lua\probe_dialog.lua"

# Install the extension (junctions %APPDATA%\Aseprite\extensions\aseprite-mcp at the repo)
.\scripts\install-extension.ps1
```

Layout, protocol and tool reference live in [ARCHITECTURE.md](ARCHITECTURE.md),
[PROTOCOL.md](PROTOCOL.md) and [TOOLS.md](TOOLS.md); setup, the env vars and the
dialog are in [SETUP.md](SETUP.md).

---

## The connect dialog

`File > MCP Bridge...` replaces the old `Start/Stop` toggle and the `Status`
alert. Both command ids are gone, so any keybinding on them is broken — that is
noted in SETUP.md. Note that `group = "file_scripts"` puts a command in the File
menu *beside* the Scripts submenu, not inside it; the docs claimed "File >
Scripts >" for years and were wrong about the old commands too.

`dialog.lua` is split in two because half of it is untestable: the harness runs
under `-b`, where `Dialog{}` returns nil.

- `M.viewModel(status, stats, canWrite, now)` and `M.displayText(vm)` are pure —
  no deps, no `Dialog`, no clock of their own. `run_tests.lua` drives them with
  literal tables like any other module.
- Everything below the widget banner touches `Dialog` and is confirmed by one
  manual pass, not by the suite.

Three things about it are worth knowing before changing it.

**Disconnect does not stop the pump.** `queue.lua` owns the only `Timer` in the
extension, and that Timer drives both `ws.poll` and the dialog's refresh, so
`queue.stop()` would freeze the dialog at a stale reading and drop anything
already queued without a reply — which the server then sees as a timeout rather
than a clean disconnect. Disconnect flips `ws.setEnabled(false)` instead, and one
helper in `main.lua` owns the Timer:

```lua
local function syncPump()
  if ws.isEnabled() or dialog.isOpen() then queue.start() else queue.stop() end
end
```

The dialog clause is what keeps "off means off" for people who never open it,
while still guaranteeing a live readout whenever it is up.

**The editable widgets are write-once.** `host`, `port` and the checkbox are
built at `M.open` and never appear in the refresh path; a 4 Hz repaint would
fight the user's typing. The one exception is `writeBackTarget`, which runs
immediately after Reconnect — feedback the user just asked for, not the refresh
stomping them. Everything else is diffed against `lastRendered` so unchanged text
is never re-written.

**Nothing is persisted unless it differs from the environment.** Reconnect
compares what was typed against `ws.resolve(nil, nil, envHost, envPort)` and only
stores the difference. Without that, pressing Reconnect without changing anything
would promote the current values to preferences and shadow
`ASEPRITE_MCP_HOST/_PORT` forever — see the trap below.

---

## What `Dialog` actually does

All measured on 1.3.18.3 / apiVersion 41 by `tests/lua/probe_dialog.lua`, which
reports through `app.alert` (because `print` opens the Console window unbidden)
and also writes `%TEMP%/aseprite-mcp-probe.txt`. Re-run it after an Aseprite
upgrade; four of these are load-bearing.

| Question | Answer |
| --- | --- |
| `Dialog{...}` under `-b` | Returns **nil**. Does not raise. |
| `dlg:show{ wait = false }` | Returns control. The pump keeps running. |
| `dlg:modify{}` from a `Timer` tick | Safe. |
| `dlg.data.<id>` before close | Reads back live edits. |
| `dlg.data.port` on empty **or** garbage input | **`0`**, a number, for both. The field can read `abc` while the data reads 0. |
| Modifying a label's text | **Relayouts the window**, growing *and* shrinking it. It does not clip. |
| `dlg.bounds` | Readable **and assignable**. Pinning works. |
| Digit glyph widths | Uniform. |
| `●` U+25CF / `○` U+25CB | **Render correctly.** The UI font has them. |

The relayout answer is why the dialog pins its own size: `Handled: 214 commands`
changes text on every command, so without pinning the window jitters several
times a second. Every growable label is built at `WIDEST_LINE` so the pinned size
fits the worst case, and the view model truncates errors so the cut lands
somewhere chosen rather than wherever the clip falls.

---

## Decisions

### Settled: preferences win over the environment

```text
plugin.preferences  >  ASEPRITE_MCP_HOST / _PORT  >  built-in default
```

A value typed into the dialog is the more deliberate act, and an env var is
invisible to someone running Aseprite from Steam. The cost is that a scripted
`ASEPRITE_MCP_PORT` can be silently ineffective, so the dialog annotates the
field (`env: 32200 - overridden`) rather than letting the user wonder.
`ws.status()` reports which source won, so the dialog never re-derives it.

**The trap, which the obvious implementation walks straight into:** an unset
preference must fall through to the env var, so "unset" and "set to the default
value" cannot be the same state. Host and port are never seeded at first run.
`main.lua` does seed `autoConnect`:

```lua
if plugin.preferences.autoConnect == nil then
  plugin.preferences.autoConnect = true
end
```

That is right for a boolean with no env equivalent and **wrong** for host and
port. Copying it would write `127.0.0.1` / `32145` into preferences on first
launch, which then outranks the env var forever — and the symptom is
`ASEPRITE_MCP_PORT` being ignored on a machine where it used to work.

### Settled: the token stays environment-only

The dialog shows `Token: on (environment)` / `off` and offers no field. The token
has to match the server's exactly, and a field invites a mismatch that presents
as a socket which opens and immediately closes — indistinguishable from "no
server running" without that row, which is why the row exists at all.

### Settled: `Files: Not trusted` gets text, not a button

`fsio.canWrite()` caches for the session, so a grant made after startup does not
show until Aseprite restarts. A "re-check" button would have to re-probe, which
raises Aseprite's Security modal; given the rule that modals must never come from
the pump, that deserves its own change rather than a rider. The dialog names the
remedy and says a restart is needed.

---

## Landmines

Every one of these was found the hard way. They are all documented at their site
in the code as well; this is the index.

- **`json.decode` returns *userdata*, not a table.** Indexing, `pairs`, `ipairs`
  and `#` all work on it, so it looks like a table right up until a
  `type(x) == "table"` check rejects it. That check is what made the bridge accept
  connections and then ignore every request, with no error anywhere. Use
  `proto.isStructured()`. The Lua tests drive raw JSON through `queue.handleRaw`
  specifically so a decoding bug cannot hide again.
- **Aseprite's Lua 5.4 truncates where stock Lua raises.** `math.tointeger(32145.5)`
  is `32145` and `string.format("%d", 32145.5)` is `"32145"` — no error. So a
  fractional port in a hand-edited `__pref.lua` would dial a port nobody wrote,
  with nothing connecting the symptom back to the file. `ws.toPort` checks
  `n % 1 ~= 0` explicitly and a test pins the truncation, so a future Aseprite
  that starts raising gets noticed rather than silently changing behaviour.
- **Aseprite's `number` widget returns `0` for an empty field and for garbage
  alike.** `0` is truthy in Lua, so a `tonumber(x) or DEFAULT` chain will happily
  dial `ws://host:0/`. Validation lives in `ws.setTarget`, not only in the dialog,
  because the other caller is `init(plugin)` reading `plugin.preferences`.
- **Modifying a label's text resizes the dialog.** See the table above.
- **Aseprite's Security modal fails closed, and `app.fs.isFile` does not prompt** —
  it just returns `false` for an un-granted path. Any design that discovers
  something by reading a file is unbuildable. All filesystem contact goes through
  `fsio.lua` so exactly one prompt appears, primed at extension load.
- **A modal raised from inside a `Timer` callback never paints** and wedges the
  bridge. That is why file access is settled at load rather than on demand, and
  why the dialog renders validation failures into its own label instead of
  calling `app.alert`.
- **`onreceive` must never touch `app.*`** — it only enqueues, and the `Timer`
  drains. This also keeps the message loop awake so commands still land while
  Aseprite is unfocused.
- **`frame.duration` is in seconds**; the whole MCP surface is milliseconds.
  Convert only at the Lua boundary.
- **`image:resize` has no nearest-neighbour mode.** Bilinear blurs every preview
  and destroys the visual loop. `render.lua` upscales by row blit instead.
- **`Dialog{}` returns `nil` under `-b`.** Guard on `app.isUIAvailable` *and* on
  the constructor's return, or it fails later and elsewhere, at the first
  `dlg:label{}`.
- **`extension/aseprite-mcp/__pref.lua` is Aseprite's own state**, not source. The
  dev install junctions the extensions dir at the repo, so the editor writes into
  the working tree. It is gitignored; keep it that way.
- **Only one Aseprite may attach.** The server closes the older connection when a
  newer one arrives, so two running instances take turns forever — a reconnect
  storm, hundreds a minute, that looks like a bridge bug and is not. Testing
  against a second Aseprite means giving it its own port.
- **Ordering when testing by hand:** start the server first, then Aseprite.
  Killing Aseprite while a driver is attached, or starting a driver while a stale
  Aseprite is still running, both present as a misleading
  `ASEPRITE_NOT_CONNECTED`.

### Debug tracing

`ASEPRITE_MCP_DEBUG=1` turns on `trace.lua`, the pump heartbeat and per-event
socket tracing, writing to `%TEMP%/aseprite-mcp-debug.log`. Silent and off by
default. This is what made the `json.decode` bug visible; leave it in. Note that
every Aseprite process with the variable set appends to the *same* file, so two
instances interleave two heartbeat streams in one log.

Full env var list: `ASEPRITE_MCP_HOST`, `_PORT`, `_TOKEN`, `_REQUIRE_TOKEN`,
`_ALLOWED_DIRS`, `_ALLOW_NON_LOOPBACK`, `_TIMEOUT`, `_RENDER_TIMEOUT`,
`_MAX_PIXELS`, `_MAX_REGION_PIXELS`, `_LOG_LEVEL`, `_DEBUG`.

---

## Deferred, still deferred

Phase 6 — `get_used_palette`, `get_history_info`. (The cel transforms,
`compare_frames` and `get_animation_bounds` landed with the token-cost work, #10.)

Edit transactions (`begin_edit` / `commit_edit` / `rollback_edit`, spec §16) stay
deferred on purpose. The obvious implementation — count transactions since
`begin_edit`, then call `app.undo()` that many times — silently undoes the user's
manual work if they touch Aseprite mid-transaction. Doing it safely needs a
`sprite.events:on('change')` watcher, and aseprite/aseprite#4997 reports crashes
when calling `undo` inside a `change` handler. Per-call transactions already give
the agent clean single-step undo.

A re-check button for `Files: Not trusted` is the one piece of the dialog that
was deliberately left out; see Decisions.
