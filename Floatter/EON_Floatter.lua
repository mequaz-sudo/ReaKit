-- @description EON Floatter
-- @version 1.0.0
-- @author EON Studios
-- @about
--   Opens every EON plugin's floating window at the size EON designed for it,
--   and lets you keep your own size for any JSFX. Run it once: it switches on,
--   starts with REAPER from then on, and shows its panel. Run it again to open
--   the panel. Closing the panel never stops it.
--
--   Needs js_ReaScriptAPI (the window measuring). The panel needs ReaImGui;
--   without it the sizing still works, silently.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE MODEL
--
-- `@gfx W H` sets a JSFX's floating size AND fixes its TCP/MCP embed aspect at
-- compile time -- one pair of numbers doing two jobs -- and a JSFX cannot
-- resize its own window (gfx_w/gfx_h are read-only; forum t=263900,
-- p=2866376). So the float is sized from outside, after REAPER opens it.
--
-- Every size here is a CANVAS size: the JSFX gfx canvas, its own child window
-- (class "jsfx_gfx") inside the float. Resizing the OUTER window by
-- (target - current canvas) lands the canvas on the target exactly, growing
-- or shrinking below @gfx alike. REAPER's title bar and toolbar never travel
-- with a size, so a size means the same thing on every machine.
--
-- Two stores, deliberately different:
--   * YOURS  -- a capture, this machine's window px, applied as-is;
--   * EON    -- the table below, logical px at 100%, times the display scale.
-- No DPI API reaches Lua, so the display scale is read off a FRESH window:
-- a float nobody has sized yet opens at @gfx x scale (bent only WIDER by the
-- float's minimum width, or SHORTER by the screen). REAPER keeps a float's
-- size in the session and in the project, so a window that is not fresh is a
-- size somebody chose, and it is left alone.
--
-- Everything measured behind this is in the bundle's wiki, chapter 6.7.
-- ─────────────────────────────────────────────────────────────────────────────

local r = reaper

local VERSION   = "1.0.0"
local EXT_D     = "EON_FloatSize"      -- captures / scale / global (the keys the pair used)
local EXT_F     = "EON_Floatter"       -- this script's own state
-- ⚠ Mirrored in rk_lua_core.lua (core.ALIVE_FLOATTER_*) for the Kit Bridge,
-- which starts this script for Swing users. Keep the four strings in step.
local ALIVE_KEY  = "alive_t"
local LAUNCH_KEY = "launch_src"
local REQ_KEY    = "req"
local POLL_SEC   = 0.25
local STALE_S    = 2.0

local L, S, W, UI, P = {}, {}, {}, {}, {}

-- ═════════════════════════════════════════════════════════════════════════════
-- L — measurement (the one place the model lives)
-- ═════════════════════════════════════════════════════════════════════════════

-- fx_ident is the JSFX path: renaming an FX in the chain keeps its size, and
-- two different plugins with one display name stay apart.
function L.fx_ident(tr, fx)
  if r.TrackFX_GetNamedConfigParm then
    local ok, val = r.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
    if ok and val and val ~= "" then return val end
  end
  return nil
end

function L.fx_key(tr, fx)
  local ident = L.fx_ident(tr, fx)
  if not ident then
    local _, nm = r.TrackFX_GetFXName(tr, fx, "")
    ident = nm or ""
  end
  ident = ident:gsub("\\", "/")
  local base = ident:match("([^/]+)$") or ident
  base = base:gsub("%.[%w]+$", "")            -- drop .jsfx / .dll / .vst3
  base = base:gsub("[^%w%-_]", "_")
  return base
end

-- "1175_ReaKit" -> "1175", "EON_Drum_Strip" -> "Drum Strip"
function L.pretty(key)
  local s = key:gsub("_ReaKit$", ""):gsub("^EON_", ""):gsub("_", " ")
  return s
end

-- Magnitudes for w/h: on a flipped or secondary display the rect can come
-- back with bottom < top. `inv` remembers that so on-screen nudging skips an
-- axis it cannot reason about.
function L.rect(h)
  if not h then return nil end
  local ok, l, t, rt, b = r.JS_Window_GetRect(h)
  if not ok then return nil end
  return { x = l, y = t, w = math.abs(rt - l), h = math.abs(b - t), inv = (b < t) }
end

-- js_ReaScriptAPI has returned the class name in either slot across versions.
local function classname(h)
  local a, b = r.JS_Window_GetClassName(h, "")
  if type(a) == "string" and a ~= "" then return a end
  if type(b) == "string" and b ~= "" then return b end
  return ""
end

-- The jsfx_gfx child of a floating FX window, or nil for anything that is
-- not a JSFX with a canvas. A VST or CLAP float sizes itself and is not ours.
function L.find_canvas(hwnd)
  if not hwnd or not r.JS_Window_ArrayAllChild then return nil end
  local arr = r.new_array({}, 256)
  local n = r.JS_Window_ArrayAllChild(hwnd, arr)
  if not n or n <= 0 then return nil end
  if n > 256 then n = 256 end
  local t = arr.table(1, n)
  for i = 1, n do
    local h = r.JS_Window_HandleFromAddress(t[i])
    if h and classname(h):lower():find("jsfx_gfx", 1, true) then return h end
  end
  return nil
end

-- Put the canvas at tw x th by resizing the OUTER window by the difference.
-- The top-left stays where REAPER put it unless the new size would hang off
-- the monitor, in which case the window slides back on.
function L.set_canvas(hwnd, canvas, tw, th)
  local o, c = L.rect(hwnd), L.rect(canvas)
  if not o or not c then return false end
  tw, th = math.floor(tw + 0.5), math.floor(th + 0.5)
  if tw < 40 or th < 40 then return false end         -- anything smaller is garbage
  local nw, nh = o.w + (tw - c.w), o.h + (th - c.h)
  local nx, ny = o.x, o.y
  if r.JS_Window_GetViewportFromRect and not o.inv then
    local vl, vt, vr, vb = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + nw, o.y + nh, true)
    if vr and nx + nw > vr then nx = math.max(vl or nx, vr - nw) end
    if vb and ny + nh > vb then ny = math.max(vt or ny, vb - nh) end
  end
  r.JS_Window_SetPosition(hwnd, nx, ny, nw, nh)
  return true
end

-- The steps Windows offers; anything else (a custom percentage) simply never
-- reads as fresh, and the plugin opens at @gfx as it always did.
local STEPS = { 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 3.5, 4 }

function L.snap_scale(ratio)
  if not ratio or ratio ~= ratio then return nil end
  for _, s in ipairs(STEPS) do
    if math.abs(ratio - s) <= 0.02 then return s end
  end
  return nil
end

local function bottom_on_edge(hwnd)
  if not r.JS_Window_GetViewportFromRect then return false end
  local o = L.rect(hwnd)
  if not o or o.inv then return false end
  local bottom = o.y + o.h
  local _, _, _, vb  = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + o.w, bottom, true)
  local _, _, _, vb2 = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + o.w, bottom, false)
  return (vb and math.abs(bottom - vb) <= 2) or (vb2 and math.abs(bottom - vb2) <= 2) or false
end

-- The scale a FRESH float reveals, or nil when the window is not fresh. What
-- REAPER opens is @gfx x scale, bent two ways and only two: WIDER (the float's
-- minimum width; never narrower, so sw >= true scale) and SHORTER (the screen;
-- never taller, so sh <= true scale). When both snap to the same step that is
-- the scale; when they differ, the bottom edge on the screen says which side
-- was bent.
function L.fresh_scale(hwnd, c, gfx_w, gfx_h)
  if not c or not gfx_w or gfx_w <= 0 or not gfx_h or gfx_h <= 0 then return nil end
  local sw, sh  = L.snap_scale(c.w / gfx_w), L.snap_scale(c.h / gfx_h)
  local h_short = bottom_on_edge(hwnd)
  local s
  if sw and sh then
    if sw == sh then s = sw
    else s = h_short and sw or sh end
  else
    s = sh or sw
  end
  if not s then return nil end
  local h_ok = (sh == s) or h_short
  local w_ok = (sw == s) or (c.w >= gfx_w * s - 2)
  if h_ok and w_ok then return s end
  return nil
end

-- Stored captures, this machine's window px:
--   <key>_cw / <key>_ch   canvas size        <key>_ident   the fx_ident
--   <key>_w  / <key>_h    LEGACY: an OUTER size from the pair this script
--                         replaced; converted per plugin, once, against that
--                         plugin's own live window (convert_legacy)
--   keys                  index of every key, because ExtState cannot be enumerated
function L.get_capture(key)
  local w = tonumber(r.GetExtState(EXT_D, key .. "_cw"))
  local h = tonumber(r.GetExtState(EXT_D, key .. "_ch"))
  if w and h and w > 0 and h > 0 then return w, h end
  return nil
end

function L.get_legacy(key)
  local w = tonumber(r.GetExtState(EXT_D, key .. "_w"))
  local h = tonumber(r.GetExtState(EXT_D, key .. "_h"))
  if w and h and w > 0 and h > 0 then return w, h end
  return nil
end

local function index_set(keys)
  r.SetExtState(EXT_D, "keys", table.concat(keys, ","), true)
end

local function index_list()
  local list = {}
  for k in (r.GetExtState(EXT_D, "keys") .. ","):gmatch("([^,]*),") do
    if k ~= "" then list[#list + 1] = k end
  end
  return list
end

local function index_add(key)
  local keys = index_list()
  for _, k in ipairs(keys) do if k == key then return end end
  keys[#keys + 1] = key
  index_set(keys)
end

function L.set_capture(key, w, h, ident)
  r.SetExtState(EXT_D, key .. "_cw", tostring(math.floor(w + 0.5)), true)
  r.SetExtState(EXT_D, key .. "_ch", tostring(math.floor(h + 0.5)), true)
  if ident and ident ~= "" then r.SetExtState(EXT_D, key .. "_ident", ident, true) end
  r.DeleteExtState(EXT_D, key .. "_w", true)     -- a legacy outer size is superseded
  r.DeleteExtState(EXT_D, key .. "_h", true)
  index_add(key)
end

function L.del_capture(key)
  for _, suf in ipairs({ "_cw", "_ch", "_ident", "_w", "_h" }) do
    r.DeleteExtState(EXT_D, key .. suf, true)
  end
  local keep = {}
  for _, k in ipairs(index_list()) do if k ~= key then keep[#keep + 1] = k end end
  index_set(keep)
end

function L.note_ident(key, ident)
  if ident and ident ~= "" and r.GetExtState(EXT_D, key .. "_ident") == "" then
    r.SetExtState(EXT_D, key .. "_ident", ident, true)
  end
end

-- A legacy OUTER capture, met on its own plugin's live float. The canvas
-- tracks the outer window 1:1, and each plugin keeps its own distance between
-- the two (REAPER's side meters inset the canvas when a plugin shows them),
-- so the conversion is done against THIS plugin's window, never a constant.
function L.convert_legacy(hwnd, canvas, key)
  local w, h = L.get_legacy(key)
  if not w then return nil end
  local o, c = L.rect(hwnd), L.rect(canvas)
  if not o or not c then return nil end
  local cw, ch = w - (o.w - c.w), h - (o.h - c.h)
  if cw < 40 or ch < 40 then return nil end
  L.set_capture(key, cw, ch, nil)
  return cw, ch
end

-- Every key with a capture (canvas or legacy). The index covers everything
-- written since it existed; reaper-extstate.ini (written at exit) covers
-- captures from before it did.
function L.captured_keys()
  local set, list = {}, {}
  local function add(k)
    if k and k ~= "" and not set[k] and (L.get_capture(k) or L.get_legacy(k)) then
      set[k] = true
      list[#list + 1] = k
    end
  end
  for _, k in ipairs(index_list()) do add(k) end
  local f = io.open(r.GetResourcePath() .. "/reaper-extstate.ini", "r")
  if f then
    local insec = false
    for line in f:lines() do
      local sec = line:match("^%[(.-)%]%s*$")
      if sec then
        insec = (sec == EXT_D)
      elseif insec then
        add(line:match("^(.-)_cw=") or line:match("^(.-)_w="))
      end
    end
    f:close()
  end
  table.sort(list)
  return list
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SIZES — the size EON set for each plugin: canvas, logical px at 100%, with
-- the plugin's @gfx so a fresh window can be told from a sized one. Written
-- by EON_Floatter_Export from captures; the rows between the markers are the
-- only thing it touches.
-- ═════════════════════════════════════════════════════════════════════════════
local SIZES = {
  -- EON SIZES BEGIN
  ["1175_ReaKit"] = { w = 545, h = 204, gfx_w = 464, gfx_h = 840 },
  ["3BandEQ_ReaKit"] = { w = 418, h = 228, gfx_w = 460, gfx_h = 900 },
  ["ChannelTool_ReaKit"] = { w = 350, h = 546, gfx_w = 450, gfx_h = 540 },
  ["DDC_ReaKit"] = { w = 573, h = 319, gfx_w = 600, gfx_h = 520 },
  ["DeEsser_ReaKit"] = { w = 465, h = 376, gfx_w = 540, gfx_h = 520 },
  ["Delay_ReaKit"] = { w = 581, h = 560, gfx_w = 620, gfx_h = 760 },
  ["EON_Drum_Strip"] = { w = 504, h = 368, gfx_w = 300, gfx_h = 700 },
  ["Gate_ReaKit"] = { w = 512, h = 430, gfx_w = 560, gfx_h = 520 },
  ["Saturation_ReaKit"] = { w = 288, h = 506, gfx_w = 220, gfx_h = 320 },
  ["StereoWidth_ReaKit"] = { w = 291, h = 364, gfx_w = 200, gfx_h = 280 },
  -- EON SIZES END
}

-- The Export loads this file for the lib and the table; nothing below runs.
if EON_FLOATTER_EMBED then return { L = L, SIZES = SIZES, VERSION = VERSION } end

-- ═════════════════════════════════════════════════════════════════════════════
-- S — this launch: who started us, and how the script keeps itself alive
-- ═════════════════════════════════════════════════════════════════════════════

local _, self_path, sec_id, cmd_id = r.get_action_context()
local SCRIPT_DIR = self_path:match("^(.*)[/\\]") or "."
local SCRIPT_NAME = "EON_Floatter"

S.now = r.time_precise()

-- Who launched us. The startup block and the Kit Bridge stamp `launch_src`
-- right before Main_OnCommand; a stale stamp (> 5 s) is somebody else's.
do
  local src = r.GetExtState(EXT_F, LAUNCH_KEY)
  r.DeleteExtState(EXT_F, LAUNCH_KEY, false)
  local kind, t = src:match("^(%a+):([%d%.]+)$")
  S.launch = (kind and (S.now - (tonumber(t) or 0)) < 5) and kind or "user"
  S.quiet  = S.launch ~= "user"
end

-- Was an instance alive a moment ago? REAPER runs the old instance's atexit
-- before the new main chunk (measured: 2 ms apart), so `handoff_t` is the
-- reliable sign; `alive_t` covers the same second.
do
  local alive = tonumber(r.GetExtState(EXT_F, ALIVE_KEY))
  local hand  = tonumber(r.GetExtState(EXT_F, "handoff_t"))
  S.alive_age = alive and (S.now - alive) or 1e9
  S.hand_age  = hand  and (S.now - hand)  or 1e9
end

-- An instance is alive and REAPER did not just end it (no fresh handoff):
-- that is a DIFFERENT copy of this script -- the Swing bundle's and the
-- ReaKit package's can both be installed -- or a REAPER without
-- set_action_options. Two watchers would fight over every window. Poke the
-- live one to open its panel and leave.
if S.alive_age < STALE_S and S.hand_age >= STALE_S then
  if not S.quiet then r.SetExtState(EXT_F, REQ_KEY, "open_panel", false) end
  return
end

-- js_ReaScriptAPI does the measuring; nothing works without it.
if not r.JS_Window_SetPosition then
  if S.quiet then
    r.ShowConsoleMsg("[EON Floatter] needs the js_ReaScriptAPI extension (ReaPack: js_ReaScriptAPI). Not running.\n")
  else
    r.MB("EON Floatter needs the js_ReaScriptAPI extension.\n\n" ..
         "Install it via ReaPack (Extensions > ReaPack > Browse packages > js_ReaScriptAPI), then run this again.",
         "EON Floatter", 0)
  end
  return
end

-- Run again = REAPER terminates this instance and starts a fresh one, no
-- dialog. The fresh one sees `handoff_t` and opens the panel.
if r.set_action_options then r.set_action_options(1 | 2) end

S.first_run  = r.GetExtState(EXT_F, "setup_v1") ~= "1"
S.want_panel = not S.quiet
S.msg, S.msg_t = nil, 0

function S.say(msg)
  S.msg, S.msg_t = msg, r.time_precise()
end

function S.beat()
  r.SetExtState(EXT_F, ALIVE_KEY, tostring(r.time_precise()), false)
end

function S.set_toggle(on)
  if sec_id and sec_id >= 0 and cmd_id and cmd_id > 0 then
    r.SetToggleCommandState(sec_id, cmd_id, on and 1 or 0)
    r.RefreshToolbar2(sec_id, cmd_id)
  end
end

function S.enabled()
  return r.GetExtState(EXT_F, "enabled") ~= "0"
end

-- ── The startup file ─────────────────────────────────────────────────────────
-- Rewrite __startup.lua via tmp-file + rename instead of truncating in place.
-- The file is SHARED -- other vendors' startup lines live in it too -- so a
-- crash or full disk mid-write must never be able to eat it. Global on
-- purpose: same helper as the other EON self-registering scripts.
function eon_write_startup(path, content)
  local tmp, prev = path .. ".eon-tmp", path .. ".eon-prev"
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(content)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  -- Windows os.rename won't overwrite, so the old file steps aside first --
  -- and steps back if the new one cannot take its place. Nothing is ever
  -- deleted before the replacement is in.
  os.remove(prev)
  local had_old = os.rename(path, prev)
  if os.rename(tmp, path) then
    os.remove(prev)
    return true
  end
  if had_old then os.rename(prev, path) end
  os.remove(tmp)
  return false
end

local function startup_path()
  return r.GetResourcePath() .. "/Scripts/__startup.lua"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return c
end

-- Strip one "-- EON:<name> BEGIN ... -- EON:<name> END" block.
function S.strip_block(content, name)
  local marker = "-- EON:" .. name
  if not content:find(marker .. " BEGIN", 1, true) then return content, false end
  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  return (content:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")), true
end

function S.autostart_on()
  local c = read_file(startup_path())
  return c ~= nil and c:find("-- EON:" .. SCRIPT_NAME .. " BEGIN", 1, true) ~= nil
end

-- The panel asks every frame; the file is read once a second.
local autostart_cache = { t = -1, v = false }
function S.autostart_cached()
  local now = r.time_precise()
  if now - autostart_cache.t > 1.0 then
    autostart_cache.t, autostart_cache.v = now, S.autostart_on()
  end
  return autostart_cache.v
end
function S.autostart_forget() autostart_cache.t = -1 end

-- Self-register as a startup action: the same self-cleaning block the Kit
-- Bridge and Strip Sync write, plus one line that stamps `launch_src` so the
-- instance it starts knows to stay quiet (no panel at REAPER launch). If
-- NamedCommandLookup ever stops resolving, the block strips ITSELF out.
function S.self_register()
  local key    = SCRIPT_NAME .. "_registered_v1"
  local marker = "-- EON:" .. SCRIPT_NAME
  local path   = startup_path()

  if r.GetExtState(EXT_F, key) == "1" and S.autostart_on() then return true end

  local reg_cmd_id = r.AddRemoveReaScript(true, 0, self_path, true)
  if not reg_cmd_id or reg_cmd_id <= 0 then return false end

  local existing = read_file(path) or ""
  existing = S.strip_block(existing, SCRIPT_NAME)

  local named_id = r.ReverseNamedCommandLookup(reg_cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(reg_cmd_id)

  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then\n" ..
    "  reaper.SetExtState('" .. EXT_F .. "','" .. LAUNCH_KEY .. "','startup:'..reaper.time_precise(),false)\n" ..
    "  reaper.Main_OnCommand(id,0)\n" ..
    "else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. SCRIPT_NAME .. " BEGIN.-%-%- EON:" .. SCRIPT_NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. EXT_F .. "','" .. key .. "','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  if eon_write_startup(path, existing .. block) then
    r.SetExtState(EXT_F, key, "1", true)
    return true
  end
  return false
end

function S.unregister_startup()
  local path = startup_path()
  local c = read_file(path)
  if c then
    local stripped, had = S.strip_block(c, SCRIPT_NAME)
    if had then eon_write_startup(path, stripped) end
  end
  r.SetExtState(EXT_F, SCRIPT_NAME .. "_registered_v1", "", true)
end

-- ── Retiring the pair this script replaced ───────────────────────────────────
-- EON_FloatSize_Watch / _Capture (and the 1175-only pair before them) may be
-- registered, and the Watch may sit in __startup.lua and be RUNNING. Order
-- matters (wiki 11.3): stop it, unregister by path (both separator
-- spellings: REAPER keys a registration by the path string), strip its
-- startup block, then register ourselves. Captures stay: same keys.
-- Names are assembled, never quoted whole, so the installer's dependency
-- scan does not go looking for files that no longer ship.
function S.migrate_old_pair()
  r.SetExtState(EXT_D, "running", "0", false)          -- an old Watch loop exits on its own
  local old = { "EON_FloatSize_Watch", "EON_FloatSize_Capture",
                "EON_1175_FloatSize_Capture", "EON_1175_FloatSize_Watch" }
  local dir_bs = SCRIPT_DIR:gsub("/", "\\")
  local dir_fs = SCRIPT_DIR:gsub("\\", "/")
  for _, name in ipairs(old) do
    r.AddRemoveReaScript(false, 0, dir_bs .. "\\" .. name .. ".lua", false)
    r.AddRemoveReaScript(false, 0, dir_fs .. "/" .. name .. ".lua", false)
  end
  r.AddRemoveReaScript(false, 0, dir_fs .. "/" .. old[1] .. ".lua", true)   -- commit once
  local path = startup_path()
  local c = read_file(path)
  if c then
    local stripped, had = S.strip_block(c, "EON_FloatSize_Watch")
    if had then eon_write_startup(path, stripped) end
  end
  r.SetExtState("EON_FloatSize_Watch", "EON_FloatSize_Watch_registered_v1", "", true)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- W — the watcher
-- ═════════════════════════════════════════════════════════════════════════════

W.win       = {}      -- addr -> window entry (see first_sight)
W.by_key    = {}      -- key  -> { addr, ... } of open floats
W.quiet_q   = {}      -- addr -> pending quiet-pass entry
W.rev       = 0       -- bumps when the set of windows or a source changes
W.next_poll = 0
W.scale_session = nil -- the scale read off a fresh window this session
W.open_n    = 0

local function round(v) return math.floor(v + 0.5) end

function W.addr(hwnd)
  return r.JS_Window_AddressFromHandle and r.JS_Window_AddressFromHandle(hwnd) or tostring(hwnd)
end

-- (scale, "measured" | "remembered" | "assumed")
function W.scale_now()
  if W.scale_session then return W.scale_session, "measured" end
  local s = tonumber(r.GetExtState(EXT_D, "scale"))
  if s and s > 0 then return s, "remembered" end
  return 1.0, "assumed"
end

function W.global()
  local g = tonumber(r.GetExtState(EXT_D, "global")) or 100
  if g < 75 then g = 75 elseif g > 150 then g = 150 end
  return g
end

function W.set_global(g)
  r.SetExtState(EXT_D, "global", tostring(round(g)), true)
end

function W.eon_size(key)
  local e = SIZES[key]
  if not e then return nil end
  local s = W.scale_now()
  local g = W.global() / 100
  return e.w * s * g, e.h * s * g
end

-- What this key should be sized to: yours first, then EON's.
function W.effective(key)
  local cw, ch = L.get_capture(key)
  if cw then return cw, ch, "yours" end
  local w, h = W.eon_size(key)
  if w then return w, h, "eon" end
  return nil
end

local function apply(e, w, h, src)
  if not e.canvas then return false end
  if not L.set_canvas(e.hwnd, e.canvas, w, h) then return false end
  e.src, e.applied, e.applied_t, e.adopted = src, { w = round(w), h = round(h) }, r.time_precise(), false
  W.rev = W.rev + 1
  return true
end

-- A fresh window says what the display scale is; learn it whenever one is
-- in hand, whatever is about to be done to it.
local function learn_scale(e, rc)
  local ship = SIZES[e.key]
  if not ship or not rc then return nil end
  local s = L.fresh_scale(e.hwnd, rc, ship.gfx_w, ship.gfx_h)
  if s then
    if s ~= W.scale_session then W.rev = W.rev + 1 end
    W.scale_session = s
    r.SetExtState(EXT_D, "scale", tostring(s), true)
  end
  return s
end

-- Whatever the key should be, now, regardless of freshness. A legacy outer
-- capture is converted first, against this very window, so the passes see
-- it the way first sight would.
function W.force_apply(e)
  if not e.canvas then return false end
  if not L.get_capture(e.key) and L.get_legacy(e.key) then
    L.convert_legacy(e.hwnd, e.canvas, e.key)
  end
  local w, h, src = W.effective(e.key)
  if not w then return false end
  return apply(e, w, h, src)
end

-- One window, first sight. Returns true when settled (sized, kept, or none of
-- ours), false when the canvas child is not there yet (counted), and "later"
-- for a minimized window (not counted: it comes back).
function W.first_sight(e)
  local canvas = L.find_canvas(e.hwnd)
  if not canvas then return false end
  e.canvas = canvas
  local rc = L.rect(canvas)
  if not rc then return false end
  if rc.x <= -32000 then return "later" end

  -- A pass asked for this window: whatever it should be, freshness aside --
  -- but a fresh window still teaches the scale first.
  if e.force then
    e.force = nil
    learn_scale(e, rc)
    if W.force_apply(e) then return true end
  end

  local key = e.key
  -- 1. Yours: this machine's px, applied as-is. A capture from the pair this
  --    script replaced is an OUTER size; converted here, against this window.
  local w, h = L.get_capture(key)
  if not w then
    w, h = L.convert_legacy(e.hwnd, canvas, key)
    if w then S.say(("%s: capture converted to canvas size %d x %d"):format(L.pretty(key), w, h)) end
  end
  if w and h then
    L.note_ident(key, L.fx_ident(e.tr, e.fx))
    apply(e, w, h, "yours")
    return true
  end

  -- 2. EON's size, on a fresh window only.
  local ship = SIZES[key]
  if not ship then e.src = nil; return true end
  local s = learn_scale(e, rc)
  if not s then e.src = "kept"; W.rev = W.rev + 1; return true end
  local g = W.global() / 100
  if apply(e, ship.w * s * g, ship.h * s * g, "eon") then
    e.scale_used = s
    S.say(("%s opened at %d x %d"):format(L.pretty(key), e.applied.w, e.applied.h))
  else
    e.src = "kept"
  end
  return true
end

-- A window we sized that no longer measures what we set: somebody dragged it,
-- and the global dial then leaves it alone. The first mismatch after an apply
-- is where the window actually landed (a size the screen or REAPER would not
-- allow): adopted, not blamed on anyone.
function W.detect_manual(e, now)
  if not e.applied or not e.canvas or (now - (e.applied_t or 0)) < 0.5 then return end
  local rc = L.rect(e.canvas)
  if not rc then
    e.canvas = L.find_canvas(e.hwnd)                 -- the child was rebuilt; find it again
    return
  end
  if math.abs(rc.w - e.applied.w) > 1 or math.abs(rc.h - e.applied.h) > 1 then
    if not e.adopted then
      e.applied, e.adopted = { w = rc.w, h = rc.h }, true
    else
      e.src, e.applied = "manual", nil
      W.rev = W.rev + 1
    end
  end
end

local function collect(tr, out)
  if not tr then return end
  for fx = 0, r.TrackFX_GetCount(tr) - 1 do
    local hwnd = r.TrackFX_GetFloatingWindow(tr, fx)
    if hwnd then out[#out + 1] = { tr = tr, fx = fx, hwnd = hwnd } end
  end
end

function W.poll(now)
  local open = {}
  collect(r.GetMasterTrack(0), open)
  for i = 0, r.CountTracks(0) - 1 do collect(r.GetTrack(0, i), open) end

  local live, by_key, n = {}, {}, 0
  local enabled = S.enabled()
  for _, o in ipairs(open) do
    local a = W.addr(o.hwnd)
    live[a] = true
    local key = L.fx_key(o.tr, o.fx)
    local e = W.win[a]
    if e and e.key ~= key then e = nil end            -- a recycled HWND address: not the same window
    if not e then
      e = { hwnd = o.hwnd, tr = o.tr, fx = o.fx, key = key, tries = 0, settled = false, since = now }
      W.win[a] = e
      W.rev = W.rev + 1
    else
      e.tr, e.fx, e.hwnd = o.tr, o.fx, o.hwnd            -- indices move when FX are reordered
    end
    if W.quiet_q[a] then
      -- a quiet-pass window: finished by quiet_tick, not here
    elseif not e.settled then
      if enabled then
        local got = W.first_sight(e)
        if got == true then
          e.settled = true
        elseif got == false then
          -- No canvas child yet: a JSFX gets 20 polls (5 s) in case REAPER is
          -- still building the window; a VST never grows one and is let go.
          e.tries = e.tries + 1
          if e.tries >= 20 then e.settled = true; e.src = nil end
        end                                          -- "later": minimized, look again
      end
    else
      W.detect_manual(e, now)
    end
    if e.key then
      by_key[e.key] = by_key[e.key] or {}
      table.insert(by_key[e.key], a)
    end
    n = n + 1
  end
  for a in pairs(W.win) do
    if not live[a] then W.win[a] = nil; W.rev = W.rev + 1 end
  end
  W.by_key, W.open_n = by_key, n
end

-- ── Passes ───────────────────────────────────────────────────────────────────
-- Every instance in the project (master + tracks) this script has a size for.
function W.instances()
  local out = {}
  local function scan(tr)
    if not tr then return end
    for fx = 0, r.TrackFX_GetCount(tr) - 1 do
      local key = L.fx_key(tr, fx)
      if SIZES[key] or L.get_capture(key) or L.get_legacy(key) then
        local _, nm = r.TrackFX_GetFXName(tr, fx, "")
        out[#out + 1] = { tr = tr, fx = fx, key = key, name = nm }
      end
    end
  end
  scan(r.GetMasterTrack(0))
  for i = 0, r.CountTracks(0) - 1 do scan(r.GetTrack(0, i)) end
  return out
end

-- QUIET: size every instance, opening a closed float invisibly (alpha 0) just
-- long enough for its canvas to exist -- one or two polls -- then hiding it
-- again. The size REAPER remembers for that float is then ours. Measured
-- 2026-09-04 (floatter_quiet_probe): the canvas child is not there in the
-- tick the window opens; hide destroys the HWND, so a reopen is a new,
-- un-layered window.
function W.quiet_pass()
  local inst = W.instances()
  local opened, sized = 0, 0
  W.quiet_focus = r.JS_Window_GetFocus and r.JS_Window_GetFocus() or nil
  for _, it in ipairs(inst) do
    local hwnd = r.TrackFX_GetFloatingWindow(it.tr, it.fx)
    if hwnd then
      local e = W.win[W.addr(hwnd)]
      if e and e.canvas then
        if W.force_apply(e) then sized = sized + 1 end
      elseif e then
        e.settled, e.force = false, true          -- sized on its first sight
      end
    else
      r.TrackFX_Show(it.tr, it.fx, 3)
      hwnd = r.TrackFX_GetFloatingWindow(it.tr, it.fx)
      if hwnd then
        if r.JS_Window_SetOpacity then r.JS_Window_SetOpacity(hwnd, "ALPHA", 0) end
        local a = W.addr(hwnd)
        W.quiet_q[a] = { tr = it.tr, fx = it.fx, key = it.key, hwnd = hwnd, deadline = r.time_precise() + 3 }
        opened = opened + 1
      end
    end
  end
  W.quiet_sized, W.quiet_total = sized, sized + opened
  if opened == 0 then
    if W.quiet_focus and r.JS_Window_SetFocus then r.JS_Window_SetFocus(W.quiet_focus) end
    S.say(("Sized %d window%s"):format(sized, sized == 1 and "" or "s"))
  end
  return sized, opened
end

local function quiet_finish(a, q)
  if r.JS_Window_SetOpacity then r.JS_Window_SetOpacity(q.hwnd, "ALPHA", 1) end
  r.TrackFX_Show(q.tr, q.fx, 2)
  W.quiet_q[a] = nil
  W.win[a] = nil
end

function W.quiet_tick(now)
  if not next(W.quiet_q) then return end
  for a, q in pairs(W.quiet_q) do
    local canvas = L.find_canvas(q.hwnd)
    if canvas then
      -- This float is fresh: it teaches the scale. A legacy capture converts here too.
      learn_scale({ key = q.key, hwnd = q.hwnd }, L.rect(canvas))
      if not L.get_capture(q.key) and L.get_legacy(q.key) then
        L.convert_legacy(q.hwnd, canvas, q.key)
      end
      local w, h = W.effective(q.key)
      if w then
        L.set_canvas(q.hwnd, canvas, w, h)
        W.quiet_sized = (W.quiet_sized or 0) + 1
      end
      quiet_finish(a, q)
    elseif now > q.deadline then
      quiet_finish(a, q)
    end
  end
  if not next(W.quiet_q) then
    if W.quiet_focus and r.JS_Window_SetFocus then r.JS_Window_SetFocus(W.quiet_focus) end
    W.quiet_focus = nil
    S.say(("Sized %d of %d window%s"):format(W.quiet_sized or 0, W.quiet_total or 0, (W.quiet_total or 0) == 1 and "" or "s"))
    W.rev = W.rev + 1
  end
end

-- LOUD: open every instance's float; each gets its size on first sight, the
-- ones already open get it now.
function W.loud_pass()
  local inst = W.instances()
  local n = 0
  for _, it in ipairs(inst) do
    local hwnd = r.TrackFX_GetFloatingWindow(it.tr, it.fx)
    if hwnd then
      local e = W.win[W.addr(hwnd)]
      if e and e.canvas then W.force_apply(e) end
    else
      r.TrackFX_Show(it.tr, it.fx, 3)
      hwnd = r.TrackFX_GetFloatingWindow(it.tr, it.fx)
      if hwnd then
        local a = W.addr(hwnd)
        W.win[a] = { hwnd = hwnd, tr = it.tr, fx = it.fx, key = it.key, tries = 0, settled = false, since = r.time_precise(), force = true }
      end
    end
    n = n + 1
  end
  S.say(("Showing %d EON plugin%s"):format(n, n == 1 and "" or "s"))
  return n
end

-- The dial moved: every open window on EON's size follows; yours and the ones
-- somebody dragged do not.
function W.reapply_global()
  local n = 0
  for _, e in pairs(W.win) do
    if e.src == "eon" and e.canvas and W.force_apply(e) then n = n + 1 end
  end
  return n
end

-- Back to EON's size for a key: the capture goes, every open float of it moves.
function W.reset_key(key)
  L.del_capture(key)
  local n = 0
  for _, a in ipairs(W.by_key[key] or {}) do
    local e = W.win[a]
    if e and e.canvas and W.force_apply(e) then n = n + 1 end
  end
  W.rev = W.rev + 1
  S.say(("%s: back to EON's size"):format(L.pretty(key)))
  return n
end

-- Keep this window's canvas size as yours.
function W.capture(e)
  if not e or not e.canvas then return false end
  local rc = L.rect(e.canvas)
  if not rc or rc.w < 40 or rc.h < 40 then return false end
  L.set_capture(e.key, rc.w, rc.h, L.fx_ident(e.tr, e.fx))
  e.src, e.applied, e.applied_t = "yours", { w = rc.w, h = rc.h }, r.time_precise()
  W.rev = W.rev + 1
  S.say(("%s: kept %d x %d as yours"):format(L.pretty(e.key), rc.w, rc.h))
  return true
end

-- ── Requests from outside (the REAPER-6 poke path, probes, toolbars) ─────────
function S.take_requests()
  local req = r.GetExtState(EXT_F, REQ_KEY)
  if req == "" then return end
  r.DeleteExtState(EXT_F, REQ_KEY, false)
  if req == "open_panel" then UI.open()
  elseif req == "apply_project" then if not next(W.quiet_q) then W.quiet_pass() end
  elseif req == "show_all" then W.loud_pass()
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- UI — the panel (ReaImGui 0.10). Only ever entered through UI.open(); the
-- watcher above never touches it. A frame error closes the panel and prints
-- one console line; the watcher carries on.
-- ═════════════════════════════════════════════════════════════════════════════

-- The look of the Swing FX picker, in 0xRRGGBBAA: dark slate, EON's action
-- blue (eon_imgui_dialog's COL_OK family), the orange mark, amber for what
-- the user chose.
P.bg        = 0x161F28FF
P.raised    = 0x1C2732FF
P.sunken    = 0x111920FF
P.line      = 0x283644FF
P.line2     = 0x34465AFF
P.text      = 0xDBE3EAFF
P.muted     = 0x8B95A1FF
P.dim       = 0x5B6773FF
P.accent    = 0x3A86D0FF
P.accent_lo = 0x2A6FB0FF
P.accent_hi = 0x4D9AE6FF
P.brand     = 0xE8532AFF
P.yours     = 0xE6B84FFF
P.yours_ink = 0x1A1408FF
P.ok        = 0x58C858FF
P.ghost     = 0x4A5C70FF
P.white     = 0xFFFFFFFF

UI.on          = false
UI.ctx         = nil
UI.font        = nil
UI.filter      = ""
UI.tab         = "ALL"
UI.cards       = {}
UI.cards_rev   = -1
UI.dirty       = true
UI.warned      = false
UI.dial_drag   = nil
UI.drag        = nil
UI.welcome     = false

local function alpha(col, a)           -- col with its alpha replaced (a in 0..1)
  return (col & 0xFFFFFF00) | math.floor(a * 255 + 0.5)
end

function UI.open()
  if UI.on then return true end
  if not r.ImGui_GetBuiltinPath then
    if not UI.warned then
      UI.warned = true
      r.MB("EON Floatter is on and sizing windows.\n\n" ..
           "Its panel needs the ReaImGui extension: install it via ReaPack " ..
           "(Extensions > ReaPack > Browse packages > ReaImGui), then run EON Floatter again.",
           "EON Floatter", 0)
    end
    return false
  end
  if not UI.ImGui then
    package.path = r.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
    local ok, mod = pcall(function() return require("imgui")("0.10") end)
    if not ok or type(mod) ~= "table" then
      r.ShowConsoleMsg("[EON Floatter] ReaImGui could not be loaded: " .. tostring(mod) .. "\n")
      return false
    end
    UI.ImGui = mod
  end
  local ImGui = UI.ImGui
  UI.ctx = ImGui.CreateContext("EON Floatter")
  local okf, font = pcall(ImGui.CreateFont, "sans-serif", ImGui.FontFlags_Bold)
  if okf and font then
    UI.font = font
    pcall(ImGui.Attach, UI.ctx, font)
  else
    UI.font = nil
  end
  UI.on, UI.dirty = true, true
  UI.welcome = r.GetExtState(EXT_F, "welcomed_v1") ~= "1"
  return true
end

function UI.close()
  UI.on, UI.ctx, UI.font, UI.drag, UI.dial_drag = false, nil, nil, nil, nil
end

-- ── theme ────────────────────────────────────────────────────────────────────
local THEME = nil
local function theme_list(ImGui)
  if THEME then return THEME end
  THEME = {
    { ImGui.Col_WindowBg,          P.bg },
    { ImGui.Col_ChildBg,           0x00000000 },
    { ImGui.Col_PopupBg,           P.raised },
    { ImGui.Col_Border,            P.line2 },
    { ImGui.Col_FrameBg,           P.sunken },
    { ImGui.Col_FrameBgHovered,    P.raised },
    { ImGui.Col_FrameBgActive,     P.line },
    { ImGui.Col_TitleBg,           P.sunken },
    { ImGui.Col_TitleBgActive,     P.sunken },
    { ImGui.Col_TitleBgCollapsed,  P.sunken },
    { ImGui.Col_ScrollbarBg,       P.sunken },
    { ImGui.Col_ScrollbarGrab,     P.line2 },
    { ImGui.Col_ScrollbarGrabHovered, P.dim },
    { ImGui.Col_ScrollbarGrabActive,  P.muted },
    { ImGui.Col_Button,            P.raised },
    { ImGui.Col_ButtonHovered,     P.line2 },
    { ImGui.Col_ButtonActive,      P.line },
    { ImGui.Col_Text,              P.text },
    { ImGui.Col_TextDisabled,      P.dim },
    { ImGui.Col_Separator,         P.line },
    { ImGui.Col_ResizeGrip,        P.line },
    { ImGui.Col_ResizeGripHovered, P.line2 },
    { ImGui.Col_ResizeGripActive,  P.accent },
  }
  return THEME
end

function UI.push_theme(ImGui, ctx)
  for _, c in ipairs(theme_list(ImGui)) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding,  3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,  12, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,    8, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ScrollbarSize,  10)
end

function UI.pop_theme(ImGui, ctx)
  ImGui.PopStyleColor(ctx, #theme_list(ImGui))
  ImGui.PopStyleVar(ctx, 5)
end

-- ── small widgets ────────────────────────────────────────────────────────────
-- A pill of text. Reserves its space; returns nothing.
function UI.chip(ImGui, ctx, text, col, fill)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local w, h = tw + 14, th + 6
  if fill then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, fill, 3)
  else
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, P.line2, 3, 0, 1)
  end
  ImGui.DrawList_AddText(dl, x + 7, y + 3, col, text)
  ImGui.Dummy(ctx, w, h)
end

-- A toggle switch (34 x 18). Returns true when clicked.
function UI.switch(ImGui, ctx, id, on)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = 34, 18
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local hov = ImGui.IsItemHovered(ctx)
  local track = on and P.accent or P.line2
  if hov then track = on and P.accent_hi or P.dim end
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, track, h / 2)
  local kx = on and (x + w - 9) or (x + 9)
  ImGui.DrawList_AddCircleFilled(dl, kx, y + h / 2, 7, P.white)
  return clicked
end

-- A dashed rectangle, since ImGui has no dash flag.
function UI.dashed_rect(ImGui, dl, x1, y1, x2, y2, col)
  local on, off = 4, 3
  local function dash_h(y, xa, xb)
    local x = xa
    while x < xb do
      local xe = math.min(x + on, xb)
      ImGui.DrawList_AddLine(dl, x, y, xe, y, col, 1)
      x = x + on + off
    end
  end
  local function dash_v(x, ya, yb)
    local y = ya
    while y < yb do
      local ye = math.min(y + on, yb)
      ImGui.DrawList_AddLine(dl, x, y, x, ye, col, 1)
      y = y + on + off
    end
  end
  dash_h(y1, x1, x2); dash_h(y2, x1, x2)
  dash_v(x1, y1, y2); dash_v(x2, y1, y2)
end

-- Three-way pill tabs. Returns the (maybe new) selection.
function UI.pill_tabs(ImGui, ctx, id, labels, cur)
  for i, lab in ipairs(labels) do
    local on = (lab == cur)
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, P.accent_lo)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, P.accent)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, P.white)
    end
    if ImGui.SmallButton(ctx, lab .. "##" .. id .. i) then cur = lab end
    if on then ImGui.PopStyleColor(ctx, 3) end
    if i < #labels then ImGui.SameLine(ctx, 0, 2) end
  end
  return cur
end

-- A labelled action button in EON blue (or quiet grey).
function UI.action(ImGui, ctx, label, w, primary, enabled)
  if enabled == false then ImGui.BeginDisabled(ctx, true) end
  if primary then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        P.accent_lo)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, P.accent)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x1E5A94FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,          P.white)
  end
  local clicked = ImGui.Button(ctx, label, w or 0, 0)
  if primary then ImGui.PopStyleColor(ctx, 4) end
  if enabled == false then ImGui.EndDisabled(ctx) end
  return clicked and enabled ~= false
end

-- ── data for the cards ───────────────────────────────────────────────────────
local function family_of(key)
  if key:find("_ReaKit$") then return "ReaKit" end
  if key:find("^EON_") then return "Swing" end
  return "JSFX"
end

function UI.build_cards()
  local seen, cards = {}, {}
  local function add(key)
    if seen[key] then return end
    seen[key] = true
    local eon = SIZES[key]
    local cw, ch = L.get_capture(key)
    local lw, lh = L.get_legacy(key)
    if not eon and not cw and not lw then return end
    local eon_px
    if eon then
      local ew, eh = W.eon_size(key)
      local sc = W.scale_now()
      eon_px = { w = round(ew), h = round(eh), gfx_w = round(eon.gfx_w * sc), gfx_h = round(eon.gfx_h * sc) }
    end
    cards[#cards + 1] = {
      key = key, name = L.pretty(key), fam = family_of(key),
      eon = eon_px, cap = cw and { w = cw, h = ch } or nil,
      legacy = (not cw) and lw and { w = lw, h = lh } or nil,
    }
  end
  for key in pairs(SIZES) do add(key) end
  for _, key in ipairs(L.captured_keys()) do add(key) end
  table.sort(cards, function(a, b)
    if (a.eon ~= nil) ~= (b.eon ~= nil) then return a.eon ~= nil end
    return a.name:lower() < b.name:lower()
  end)
  UI.cards, UI.cards_rev, UI.dirty = cards, W.rev, false
end

-- The window the user is looking at: REAPER's focused FX, or the one it last
-- focused that is still open (parm & 1), or the only float we know.
function UI.focused()
  if r.GetTouchedOrFocusedFX then
    local ok, tidx, iidx, _, fxidx, parm = r.GetTouchedOrFocusedFX(1)
    if ok and iidx == -1 then
      local tr = (tidx == -1) and r.GetMasterTrack(0) or r.GetTrack(0, tidx)
      local hwnd = tr and r.TrackFX_GetFloatingWindow(tr, fxidx)
      if hwnd then
        local e = W.win[W.addr(hwnd)]
        if e then return e, (parm & 1) ~= 0 end
      end
    end
  elseif r.GetFocusedFX2 then
    local rv, tn, _, fxn = r.GetFocusedFX2()
    if rv & 1 == 1 and fxn < 0x1000000 then
      local tr = (tn == 0) and r.GetMasterTrack(0) or r.GetTrack(0, tn - 1)
      local hwnd = tr and r.TrackFX_GetFloatingWindow(tr, fxn)
      if hwnd then
        local e = W.win[W.addr(hwnd)]
        if e then return e, (rv & 4) ~= 0 end
      end
    end
  end
  local only, n = nil, 0
  for _, e in pairs(W.win) do only = e; n = n + 1 end
  if n == 1 then return only, true end
  return nil, false
end

-- ── sections ─────────────────────────────────────────────────────────────────
function UI.header(ImGui, ctx)
  local line_w = ImGui.GetContentRegionAvail(ctx)      -- the whole line, measured first
  -- wordmark
  if UI.font then ImGui.PushFont(ctx, UI.font, 19) end
  ImGui.TextColored(ctx, P.brand, "EON")
  ImGui.SameLine(ctx, 0, 8)
  ImGui.TextColored(ctx, P.line2, "|")
  ImGui.SameLine(ctx, 0, 8)
  ImGui.Text(ctx, "FLOATTER")
  if UI.font then ImGui.PopFont(ctx) end

  -- status: on/off switch + starts-with-REAPER switch
  ImGui.SameLine(ctx, 0, 24)
  local on = S.enabled()
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local lh = ImGui.GetTextLineHeight(ctx)
  ImGui.DrawList_AddCircleFilled(dl, x + 5, y + lh / 2 + 1, 4, on and P.ok or P.dim)
  ImGui.Dummy(ctx, 12, lh)
  ImGui.SameLine(ctx, 0, 4)
  ImGui.Text(ctx, on and "ON" or "OFF")
  ImGui.SameLine(ctx, 0, 8)
  if UI.switch(ImGui, ctx, "##enabled", on) then
    r.SetExtState(EXT_F, "enabled", on and "0" or "1", true)
    S.set_toggle(not on)
    S.say(on and "Paused: windows open as they are" or "On: EON plugins open at their sizes")
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, on and "Pause the sizing" or "Resume the sizing") end

  ImGui.SameLine(ctx, 0, 16)
  local auto = S.autostart_cached()
  ImGui.TextColored(ctx, P.muted, "starts with REAPER")
  ImGui.SameLine(ctx, 0, 8)
  if UI.switch(ImGui, ctx, "##autostart", auto) then
    if auto then
      S.unregister_startup()
      r.SetExtState(EXT_F, "autostart", "0", true)
      S.say("Will not start with REAPER; run the action to start it")
    else
      r.SetExtState(EXT_F, "autostart", "1", true)
      if S.self_register() then S.say("Starts with REAPER from now on") end
    end
    S.autostart_forget()
  end

  -- right side: chips + version
  local sc, src = W.scale_now()
  local yours = 0
  for _, c in ipairs(UI.cards) do if c.cap then yours = yours + 1 end end
  local eon_n = 0
  for _ in pairs(SIZES) do eon_n = eon_n + 1 end
  local disp = ("Display %d%%"):format(round(sc * 100))
  local cnt  = ("%d EON plugins · %d yours"):format(eon_n, yours)
  local ver  = "v" .. VERSION
  local w1 = select(1, ImGui.CalcTextSize(ctx, disp)) + 14
  local w2 = select(1, ImGui.CalcTextSize(ctx, cnt)) + 14
  local w3 = select(1, ImGui.CalcTextSize(ctx, ver))
  local total = w1 + w2 + w3 + 8 + 12
  local used = ImGui.GetCursorPosX(ctx)
  if line_w - used > total + 10 then
    ImGui.SameLine(ctx, line_w - total)               -- offset from the line's start
  else
    ImGui.SameLine(ctx, 0, 16)
  end
  UI.chip(ImGui, ctx, disp, P.muted)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, src == "measured" and "Read off a freshly opened window this session"
      or src == "remembered" and "Read off a fresh window in an earlier session"
      or "Not read yet: assumed 100% until an EON plugin opens fresh")
  end
  ImGui.SameLine(ctx, 0, 8)
  UI.chip(ImGui, ctx, cnt, P.muted)
  ImGui.SameLine(ctx, 0, 12)
  ImGui.TextColored(ctx, P.dim, ver)
end

-- One plugin's card. Draws the float to scale against its @gfx ghost.
local CARD_W, CARD_H, SHAPE_H = 196, 148, 66
function UI.card(ImGui, ctx, c, k)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##card_" .. c.key, CARD_W, CARD_H)
  local hov = ImGui.IsItemHovered(ctx)
  local x2, y2 = x + CARD_W, y + CARD_H
  ImGui.DrawList_AddRectFilled(dl, x, y, x2, y2, P.raised, 4)
  ImGui.DrawList_AddRect(dl, x, y, x2, y2, hov and P.accent or P.line, 4, 0, 1)

  -- name, family, badge
  ImGui.DrawList_AddText(dl, x + 10, y + 8, P.text, c.name)
  local nw = select(1, ImGui.CalcTextSize(ctx, c.name))
  ImGui.DrawList_AddText(dl, x + 10 + nw + 6, y + 9, P.dim, c.fam)
  local badge = c.cap and "YOURS" or (c.eon and "EON" or "LEGACY")
  local bw = select(1, ImGui.CalcTextSize(ctx, badge)) + 10
  local bx, by = x2 - 10 - bw, y + 8
  if c.cap then
    ImGui.DrawList_AddRectFilled(dl, bx, by, bx + bw, by + 16, P.yours, 2)
    ImGui.DrawList_AddText(dl, bx + 5, by + 1, P.yours_ink, badge)
  else
    ImGui.DrawList_AddRect(dl, bx, by, bx + bw, by + 16, c.eon and P.accent_lo or P.dim, 2, 0, 1)
    ImGui.DrawList_AddText(dl, bx + 5, by + 1, c.eon and P.accent_hi or P.dim, badge)
  end

  -- the shape: set size solid, @gfx dashed, both on one floor
  local set = c.cap or (c.eon and { w = c.eon.w, h = c.eon.h }) or c.legacy
  local gw, gh = c.eon and c.eon.gfx_w or set.w, c.eon and c.eon.gfx_h or set.h
  local sx, sy, sw, sh = x + 10, y + 30, CARD_W - 20, SHAPE_H
  local floor_y = sy + sh
  ImGui.DrawList_AddLine(dl, sx, floor_y + 0.5, sx + sw, floor_y + 0.5, P.line2, 1)
  if k and set then
    local col = c.cap and P.yours or (c.eon and P.accent or P.dim)
    if c.eon then
      local ggw, ggh = gw * k, gh * k
      local gx = sx + (sw - ggw) / 2
      UI.dashed_rect(ImGui, dl, gx, floor_y - ggh, gx + ggw, floor_y, P.ghost)
    end
    local ww, hh = set.w * k, set.h * k
    local rx = sx + (sw - ww) / 2
    ImGui.DrawList_AddRectFilled(dl, rx, floor_y - hh, rx + ww, floor_y, alpha(col, 0.22), 0)
    ImGui.DrawList_AddRect(dl, rx, floor_y - hh, rx + ww, floor_y, col, 0, 0, 1.25)
  end

  -- captions
  local size_s = set and ("%d × %d"):format(set.w, set.h) or "-"
  ImGui.DrawList_AddText(dl, x + 10, y2 - 24, P.text, size_s)
  local sub = c.cap and (c.eon and ("EON %d × %d"):format(c.eon.w, c.eon.h) or "your size")
           or (c.eon and ("default %d × %d"):format(gw, gh) or "old capture")
  local subw = select(1, ImGui.CalcTextSize(ctx, sub))
  ImGui.DrawList_AddText(dl, x2 - 10 - subw, y2 - 23, P.dim, sub)

  -- open floats dot + count
  local opened = W.by_key[c.key]
  if opened and #opened > 0 then
    ImGui.DrawList_AddCircleFilled(dl, bx - 10, by + 8, 3, P.ok)
  end

  -- hover: Reset / Capture drawn over the captions, hit-tested by hand so the
  -- card wall's cursor never moves.
  if hov then
    local mx, my = ImGui.GetMousePos(ctx)
    local clicked = ImGui.IsItemClicked(ctx, 0)
    local can_reset = c.cap ~= nil or c.legacy ~= nil
    local one = opened and #opened == 1 and W.win[opened[1]] or nil
    local bh = 18
    local byy = y2 - 8 - bh
    local bxx = x + 10
    local function pseudo(label, enabled, fill, ink)
      local tw = select(1, ImGui.CalcTextSize(ctx, label))
      local w = tw + 16
      local inside = mx >= bxx and mx <= bxx + w and my >= byy and my <= byy + bh
      local f = enabled and (inside and (fill == P.raised and P.line2 or P.accent) or fill) or P.sunken
      ImGui.DrawList_AddRectFilled(dl, bxx, byy, bxx + w, byy + bh, f, 3)
      ImGui.DrawList_AddRect(dl, bxx, byy, bxx + w, byy + bh, enabled and P.line2 or P.line, 3, 0, 1)
      ImGui.DrawList_AddText(dl, bxx + 8, byy + 2, enabled and ink or P.dim, label)
      bxx = bxx + w + 6
      return inside
    end
    ImGui.DrawList_AddRectFilled(dl, x + 1, byy - 4, x2 - 1, y2 - 1, P.raised, 4)   -- cover the captions
    local in_reset = pseudo(c.eon and "Reset" or "Forget", can_reset, P.raised, P.text)
    local in_cap   = pseudo("Capture", one ~= nil, P.accent_lo, P.white)
    if in_reset and can_reset then
      ImGui.SetTooltip(ctx, c.eon and "Back to EON's size" or "Forget your size")
      if clicked then
        if c.eon then W.reset_key(c.key) else L.del_capture(c.key); S.say(c.name .. ": size forgotten"); W.rev = W.rev + 1 end
        UI.dirty = true
      end
    elseif in_cap then
      ImGui.SetTooltip(ctx, one and "Keep this window's size as yours"
        or (opened and #opened > 1 and "Two of these are open: use THIS WINDOW" or "Open its floating window first"))
      if clicked and one then W.capture(one); UI.dirty = true end
    end
  end
end

function UI.library(ImGui, ctx)
  local line_w = ImGui.GetContentRegionAvail(ctx)
  ImGui.TextColored(ctx, P.muted, "PLUGINS")
  ImGui.SameLine(ctx, 0, 14)
  UI.tab = UI.pill_tabs(ImGui, ctx, "tab", { "ALL", "EON", "YOURS" }, UI.tab)
  local used = ImGui.GetCursorPosX(ctx) + 8            -- still on the tabs' line
  local fw = math.max(60, math.min(200, line_w - used))
  ImGui.SameLine(ctx, line_w - fw)
  ImGui.SetNextItemWidth(ctx, fw)
  local _, txt = ImGui.InputTextWithHint(ctx, "##filter", "filter plugins", UI.filter)
  UI.filter = txt or ""
  ImGui.Spacing(ctx)

  if UI.dirty or UI.cards_rev ~= W.rev then UI.build_cards() end

  -- one scale for every card, so shapes compare across the wall
  local maxw, maxh = 1, 1
  local shown = {}
  local needle = UI.filter:lower()
  for _, c in ipairs(UI.cards) do
    local keep = (UI.tab == "ALL") or (UI.tab == "EON" and c.eon ~= nil) or (UI.tab == "YOURS" and c.cap ~= nil)
    if keep and (needle == "" or c.name:lower():find(needle, 1, true) or c.key:lower():find(needle, 1, true)) then
      shown[#shown + 1] = c
      local set = c.cap or c.eon or c.legacy
      if set then maxw, maxh = math.max(maxw, set.w), math.max(maxh, set.h) end
      if c.eon then maxw, maxh = math.max(maxw, c.eon.gfx_w), math.max(maxh, c.eon.gfx_h) end
    end
  end
  local k = math.min((CARD_W - 28) / maxw, (SHAPE_H - 6) / maxh)

  if #shown == 0 then
    ImGui.TextDisabled(ctx, UI.filter ~= "" and "nothing matches" or "no plugins yet: open one and Capture it")
    return
  end
  local cols = math.max(1, math.floor((ImGui.GetContentRegionAvail(ctx) + 8) / (CARD_W + 8)))
  for i, c in ipairs(shown) do
    if (i - 1) % cols ~= 0 then ImGui.SameLine(ctx, 0, 8) end
    UI.card(ImGui, ctx, c, k)
  end
end

-- The proxy: the focused window's canvas to scale, with dimension lines and
-- a corner handle that drives the real window.
function UI.proxy(ImGui, ctx, e, cur)
  local dl = ImGui.GetWindowDrawList(ctx)
  local BW, BH = ImGui.GetContentRegionAvail(ctx), 124
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + BW, y0 + BH, P.bg, 4)
  ImGui.DrawList_AddRect(dl, x0, y0, x0 + BW, y0 + BH, P.line, 4, 0, 1)

  local ew, eh = W.eon_size(e.key)
  local set = SIZES[e.key] and { w = ew, h = eh } or nil
  local mw = math.max(cur.w, set and set.w or 0)
  local mh = math.max(cur.h, set and set.h or 0)
  local ps = math.min((BW - 64) / mw, (BH - 54) / mh)
  local rw, rh = cur.w * ps, cur.h * ps
  local rx = x0 + 36 + ((BW - 64) - rw) / 2
  local ry = y0 + 22
  -- title bar so it reads as a window
  ImGui.DrawList_AddRectFilled(dl, rx, ry - 12, rx + rw, ry, 0x223040FF, 0)
  ImGui.DrawList_AddRect(dl, rx, ry - 12, rx + rw, ry, P.line, 0, 0, 1)
  -- EON's size as a ghost when it differs
  if set and (math.abs(set.w - cur.w) > 1 or math.abs(set.h - cur.h) > 1) then
    local gw, gh = set.w * ps, set.h * ps
    UI.dashed_rect(ImGui, dl, rx, ry, rx + gw, ry + gh, P.ghost)
  end
  local col = e.src == "yours" and P.yours or (e.src == "eon" and P.accent or P.muted)
  ImGui.DrawList_AddRectFilled(dl, rx, ry, rx + rw, ry + rh, alpha(col, 0.18), 0)
  ImGui.DrawList_AddRect(dl, rx, ry, rx + rw, ry + rh, col, 0, 0, 1.5)
  -- dimension lines
  local dimc = P.dim
  local yb = ry + rh + 12
  ImGui.DrawList_AddLine(dl, rx, yb, rx + rw, yb, dimc, 1)
  ImGui.DrawList_AddLine(dl, rx, yb - 4, rx, yb + 4, dimc, 1)
  ImGui.DrawList_AddLine(dl, rx + rw, yb - 4, rx + rw, yb + 4, dimc, 1)
  local ws = tostring(cur.w)
  local wsw = select(1, ImGui.CalcTextSize(ctx, ws))
  ImGui.DrawList_AddText(dl, rx + rw / 2 - wsw / 2, yb + 5, P.text, ws)
  local xl = rx - 12
  ImGui.DrawList_AddLine(dl, xl, ry, xl, ry + rh, dimc, 1)
  ImGui.DrawList_AddLine(dl, xl - 4, ry, xl + 4, ry, dimc, 1)
  ImGui.DrawList_AddLine(dl, xl - 4, ry + rh, xl + 4, ry + rh, dimc, 1)
  local hs = tostring(cur.h)
  local hsw = select(1, ImGui.CalcTextSize(ctx, hs))
  ImGui.DrawList_AddText(dl, xl - 6 - hsw, ry + rh / 2 - 7, P.text, hs)

  -- the handle
  local hx, hy = rx + rw, ry + rh
  ImGui.SetCursorScreenPos(ctx, hx - 8, hy - 8)
  ImGui.InvisibleButton(ctx, "##handle", 16, 16)
  local hov, act = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  if hov or act then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNWSE) end
  ImGui.DrawList_AddRectFilled(dl, hx - 5, hy - 5, hx + 5, hy + 5, P.white, 1)
  ImGui.DrawList_AddRect(dl, hx - 5, hy - 5, hx + 5, hy + 5, (hov or act) and P.accent_hi or col, 1, 0, 2)
  if ImGui.IsItemActivated(ctx) then
    UI.drag = { w = cur.w, h = cur.h, lw = cur.w, lh = cur.h }
  end
  if act and UI.drag and e.canvas then
    local dx, dy = ImGui.GetMouseDragDelta(ctx, nil, nil, ImGui.MouseButton_Left, 0)
    local fine = (ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift) ~= 0
    local g = fine and 0.25 or 1
    local tw = math.max(40, round(UI.drag.w + dx / ps * g))
    local th = math.max(40, round(UI.drag.h + dy / ps * g))
    if tw ~= UI.drag.lw or th ~= UI.drag.lh then
      L.set_canvas(e.hwnd, e.canvas, tw, th)
      UI.drag.lw, UI.drag.lh = tw, th
    end
  end
  if ImGui.IsItemDeactivated(ctx) and UI.drag then
    UI.drag = nil
    e.src, e.applied = "manual", nil
    W.rev = W.rev + 1
    S.say(("%s resized to %d × %d - Capture to keep it"):format(L.pretty(e.key), cur.w, cur.h))
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0 + BH)
  ImGui.Dummy(ctx, BW, 4)
end

-- −/+ stepper on one axis. Returns the delta asked for (0 if none).
function UI.stepper(ImGui, ctx, id, label, value)
  local d = 0
  local step = ((ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift) ~= 0) and 10 or 1
  if ImGui.SmallButton(ctx, "-##m" .. id) then d = -step end
  ImGui.SameLine(ctx, 0, 6)
  ImGui.TextColored(ctx, P.dim, label)
  ImGui.SameLine(ctx, 0, 4)
  ImGui.Text(ctx, tostring(value))
  ImGui.SameLine(ctx, 0, 6)
  if ImGui.SmallButton(ctx, "+##p" .. id) then d = step end
  return d
end

-- The dial: 75..150 %, stops at 75/100/125/150, vertical drag, double-click = 100.
function UI.dial(ImGui, ctx, value)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local R = 24
  local cx, cy = x + R + 2, y + R + 2
  ImGui.InvisibleButton(ctx, "##dial", 2 * R + 4, 2 * R + 4)
  local hov, act = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local shown = value
  local committed = nil
  if ImGui.IsItemActivated(ctx) then UI.dial_drag = { start = value } end
  if act and UI.dial_drag then
    local _, dy = ImGui.GetMouseDragDelta(ctx, nil, nil, ImGui.MouseButton_Left, 0)
    local v = UI.dial_drag.start - dy * 0.5
    for _, stop in ipairs({ 75, 100, 125, 150 }) do
      if math.abs(v - stop) <= 2 then v = stop end
    end
    if v < 75 then v = 75 elseif v > 150 then v = 150 end
    UI.dial_drag.v = round(v)
    shown = UI.dial_drag.v
  end
  if ImGui.IsItemDeactivated(ctx) and UI.dial_drag then
    committed = UI.dial_drag.v or value
    UI.dial_drag = nil
  end
  if hov and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    committed, UI.dial_drag, shown = 100, nil, 100
  end

  -- face
  ImGui.DrawList_AddCircleFilled(dl, cx, cy, R, P.sunken)
  ImGui.DrawList_AddCircle(dl, cx, cy, R, (hov or act) and P.accent_hi or P.line2, 0, 1.5)
  local a0, a1 = math.pi * 0.75, math.pi * 2.25          -- 270° sweep, 7 o'clock to 5 o'clock
  local function ang(v) return a0 + (v - 75) / 75 * (a1 - a0) end
  ImGui.DrawList_PathArcTo(dl, cx, cy, R - 5, a0, a1)
  ImGui.DrawList_PathStroke(dl, P.line2, 0, 3)
  ImGui.DrawList_PathArcTo(dl, cx, cy, R - 5, ang(75), ang(shown))
  ImGui.DrawList_PathStroke(dl, P.accent, 0, 3)
  for _, stop in ipairs({ 75, 100, 125, 150 }) do
    local a = ang(stop)
    ImGui.DrawList_AddLine(dl, cx + math.cos(a) * (R + 3), cy + math.sin(a) * (R + 3),
                               cx + math.cos(a) * (R + 7), cy + math.sin(a) * (R + 7), P.dim, 1)
  end
  local a = ang(shown)
  ImGui.DrawList_AddLine(dl, cx + math.cos(a) * (R - 14), cy + math.sin(a) * (R - 14),
                             cx + math.cos(a) * (R - 8), cy + math.sin(a) * (R - 8), P.white, 2)
  return shown, committed
end

function UI.focus_panel(ImGui, ctx)
  ImGui.TextColored(ctx, P.muted, "THIS WINDOW")
  local e, stale = UI.focused()
  local cur = e and e.canvas and L.rect(e.canvas) or nil
  if not e or not cur then
    ImGui.Spacing(ctx)
    ImGui.TextDisabled(ctx, "Click a plugin's floating window.")
    ImGui.TextDisabled(ctx, "It shows up here with its size, a handle to")
    ImGui.TextDisabled(ctx, "resize it live, and Capture to keep the result.")
  else
    if UI.font then ImGui.PushFont(ctx, UI.font, 17) end
    ImGui.TextColored(ctx, stale and P.muted or P.text, L.pretty(e.key))
    if UI.font then ImGui.PopFont(ctx) end
    local _, tname = r.GetTrackName(e.tr)
    ImGui.TextColored(ctx, P.dim, ("%s · %s"):format(family_of(e.key), tname or "track"))
    UI.proxy(ImGui, ctx, e, cur)
    local dw = UI.stepper(ImGui, ctx, "w", "W", cur.w)
    ImGui.SameLine(ctx, 0, 14)
    local dh = UI.stepper(ImGui, ctx, "h", "H", cur.h)
    if (dw ~= 0 or dh ~= 0) and e.canvas then
      L.set_canvas(e.hwnd, e.canvas, math.max(40, cur.w + dw), math.max(40, cur.h + dh))
      e.src, e.applied = "manual", nil
      W.rev = W.rev + 1
    end
    local dl = ImGui.GetWindowDrawList(ctx)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.DrawList_AddCircleFilled(dl, x + 4, y + 8, 3, P.ok)
    ImGui.Dummy(ctx, 10, 12)
    ImGui.SameLine(ctx, 0, 2)
    ImGui.TextColored(ctx, P.muted, "Live: drag the corner, the window follows")
    ImGui.Spacing(ctx)
    local src_s = e.src == "yours" and "yours" or e.src == "eon" and "EON's size" or e.src == "manual" and "resized by hand" or "as REAPER opened it"
    if UI.action(ImGui, ctx, ("Capture %d × %d##cap"):format(cur.w, cur.h), -1, true) then
      W.capture(e); UI.dirty = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Keep this size as yours for " .. L.pretty(e.key) .. " (now: " .. src_s .. ")") end
    if SIZES[e.key] then
      local ew, eh = W.eon_size(e.key)
      if UI.action(ImGui, ctx, ("Reset to EON %d × %d##rst"):format(round(ew), round(eh)), -1, false) then
        W.reset_key(e.key); UI.dirty = true
      end
    elseif L.get_capture(e.key) then
      if UI.action(ImGui, ctx, "Forget my size##fgt", -1, false) then
        L.del_capture(e.key); S.say(L.pretty(e.key) .. ": size forgotten"); W.rev = W.rev + 1; UI.dirty = true
      end
    end
  end

  -- the dial
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)
  ImGui.TextColored(ctx, P.muted, "ALL EON SIZES")
  local g = W.global()
  local shown, committed = UI.dial(ImGui, ctx, UI.dial_drag and UI.dial_drag.v or g)
  ImGui.SameLine(ctx, 0, 12)
  local yv = ImGui.GetCursorPosY(ctx)
  ImGui.SetCursorPosY(ctx, yv + 4)
  ImGui.BeginGroup(ctx)
  if UI.font then ImGui.PushFont(ctx, UI.font, 20) end
  ImGui.Text(ctx, ("%d%%"):format(shown))
  if UI.font then ImGui.PopFont(ctx) end
  ImGui.TextColored(ctx, P.dim, "75 · 100 · 125 · 150")
  ImGui.EndGroup(ctx)
  if committed and committed ~= g then
    W.set_global(committed)
    local n = W.reapply_global()
    S.say(("EON sizes at %d%% - %d open window%s moved"):format(committed, n, n == 1 and "" or "s"))
    UI.dirty = true
  end
  ImGui.TextColored(ctx, P.dim, "One dial for a small laptop or a big 4K.")
  ImGui.TextColored(ctx, P.dim, "Your own captures are never scaled.")
end

function UI.welcome_card(ImGui, ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, P.raised)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, P.accent_lo)
  local vis = ImGui.BeginChild(ctx, "##welcome", w, 100, ImGui.ChildFlags_Borders)
  if vis then
    if UI.font then ImGui.PushFont(ctx, UI.font, 16) end
    ImGui.TextColored(ctx, P.brand, "EON")
    ImGui.SameLine(ctx, 0, 6)
    ImGui.Text(ctx, "Floatter is on")
    if UI.font then ImGui.PopFont(ctx) end
    local now = r.time_precise()
    if not UI.welcome_n or now - (UI.welcome_t or -1) > 1.0 then
      UI.welcome_n, UI.welcome_t = #W.instances(), now
    end
    local n = UI.welcome_n
    ImGui.TextColored(ctx, P.muted, ("Your EON plugins now open at their designed sizes, and this starts with REAPER. " ..
      "This project has %d EON plugin%s already."):format(n, n == 1 and "" or "s"))
    ImGui.Spacing(ctx)
    if UI.action(ImGui, ctx, "Set them now##welcome_apply", 160, true, n > 0) then
      W.quiet_pass()
      r.SetExtState(EXT_F, "welcomed_v1", "1", true); UI.welcome = false
    end
    ImGui.SameLine(ctx, 0, 8)
    if UI.action(ImGui, ctx, "Later##welcome_later", 90, false) then
      r.SetExtState(EXT_F, "welcomed_v1", "1", true); UI.welcome = false
    end
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx, 2)
  ImGui.Spacing(ctx)
end

function UI.footer(ImGui, ctx)
  local busy = next(W.quiet_q) ~= nil
  if UI.action(ImGui, ctx, "Apply EON sizes to this project", 0, true, not busy) then W.quiet_pass() end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Every EON plugin in this project, open or not, to its size. Quietly.") end
  ImGui.SameLine(ctx, 0, 8)
  if UI.action(ImGui, ctx, "Show all EON plugins", 0, false) then W.loud_pass() end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open every EON plugin's floating window in this project") end
  ImGui.SameLine(ctx, 0, 16)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local lh = ImGui.GetTextLineHeight(ctx)
  local fresh = S.msg and (r.time_precise() - S.msg_t) < 6
  ImGui.DrawList_AddCircleFilled(dl, x + 4, y + lh / 2 + 3, 3, fresh and P.ok or P.dim)
  ImGui.Dummy(ctx, 10, lh)
  ImGui.SameLine(ctx, 0, 2)
  ImGui.AlignTextToFramePadding(ctx)
  if fresh then
    ImGui.TextColored(ctx, P.muted, S.msg)
  else
    ImGui.TextColored(ctx, P.dim, ("watching · %d window%s open"):format(W.open_n, W.open_n == 1 and "" or "s"))
  end
end

function UI.draw(ImGui, ctx)
  UI.push_theme(ImGui, ctx)
  ImGui.SetNextWindowSize(ctx, 860, 720, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 700, 520, 4096, 4096)
  local visible, open = ImGui.Begin(ctx, "EON Floatter###eon_floatter", true, ImGui.WindowFlags_NoCollapse)
  if visible then
    if UI.dirty or UI.cards_rev ~= W.rev then UI.build_cards() end
    UI.header(ImGui, ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    if UI.welcome then UI.welcome_card(ImGui, ctx) end

    local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
    local right_w = 300
    local footer_h = ImGui.GetFrameHeight(ctx) + 14
    local body_h = math.max(120, avail_h - footer_h)
    if ImGui.BeginChild(ctx, "##library", avail_w - right_w - 8, body_h, ImGui.ChildFlags_None) then
      UI.library(ImGui, ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.SameLine(ctx, 0, 8)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, P.sunken)
    if ImGui.BeginChild(ctx, "##focus", right_w, body_h, ImGui.ChildFlags_Borders) then
      UI.focus_panel(ImGui, ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Spacing(ctx)
    UI.footer(ImGui, ctx)

    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
       and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      open = false
    end
    ImGui.End(ctx)
  end
  UI.pop_theme(ImGui, ctx)
  if not open then UI.close() end
end

function UI.frame()
  if not UI.on then return end
  local ImGui, ctx = UI.ImGui, UI.ctx
  if not ctx or not ImGui.ValidatePtr(ctx, "ImGui_Context*") then UI.close(); return end
  local ok, err = pcall(UI.draw, ImGui, ctx)
  if not ok then
    r.ShowConsoleMsg("[EON Floatter] panel error: " .. tostring(err) .. "\n")
    UI.close()
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- The loop
-- ═════════════════════════════════════════════════════════════════════════════
local function tick()
  S.beat()
  S.take_requests()
  local now = r.time_precise()
  if now >= W.next_poll then
    W.next_poll = now + POLL_SEC
    W.poll(now)
  end
  W.quiet_tick(now)
  if UI.on then UI.frame() end
  r.defer(tick)
end

-- ── Boot ─────────────────────────────────────────────────────────────────────
if S.first_run then
  S.migrate_old_pair()
  if S.self_register() then r.SetExtState(EXT_F, "setup_v1", "1", true) end
elseif r.GetExtState(EXT_F, "autostart") ~= "0" then
  S.self_register()                                    -- heals a stripped block
end

S.set_toggle(S.enabled())
r.atexit(function()
  r.SetExtState(EXT_F, "handoff_t", tostring(r.time_precise()), false)
  for a, q in pairs(W.quiet_q) do quiet_finish(a, q) end   -- never leave an invisible float behind
  S.set_toggle(false)
end)

if S.want_panel then UI.open() end
tick()
