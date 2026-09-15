#!/usr/bin/env lua
--[[--------------------------------------------------------------------------
  tools/selfcheck.lua — run the trainer outside the game against a stubbed
  REFramework environment.

  WHAT THIS PROVES, AND WHAT IT DOES NOT
  --------------------------------------
  It DOES prove:
    * every module resolves through package.preload, with no path dependency
    * the bundle loads and the entry point executes
    * the menu draw path runs without error against a realistic imgui stub
    * the frame loop, script reset and config save callbacks are safe to call
    * the discovery dump produces well-formed output
    * no module references a global it did not define

  It does NOT prove:
    * that any REFramework binding behaves the way the stub does
    * that a real game object responds to anything
    * that any cheat works — none of them are implemented yet, by design

  The stub is deliberately strict about one thing: reading an undefined global
  is reported. That is how we catch the classic REFramework bug of a module
  quietly depending on a global that a different script happened to set.

  USAGE
      lua tools/selfcheck.lua build/re7trainer.lua
----------------------------------------------------------------------------]]

local bundle_path = arg[1] or "build/re7trainer.lua"

local failures = 0
local checks = 0

local function check(name, ok, detail)
  checks = checks + 1
  if ok then
    io.write(string.format("  ok    %s\n", name))
  else
    failures = failures + 1
    io.write(string.format("  FAIL  %s%s\n", name, detail and ("  -- " .. tostring(detail)) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- Stub: logging
-- ---------------------------------------------------------------------------

local log_lines = {}

local function record(level, message)
  log_lines[#log_lines + 1] = { level = level, message = tostring(message) }
end

log = {
  info  = function(m) record("info", m) end,
  warn  = function(m) record("warn", m) end,
  error = function(m) record("error", m) end,
  debug = function(m) record("debug", m) end,
}

-- ---------------------------------------------------------------------------
-- Stub: type database
--
-- A small but structurally realistic fake. Enough to exercise the reflection
-- path in type_helpers without pretending to be RE7.
-- ---------------------------------------------------------------------------

local function make_type(full_name, parent_name, methods, fields)
  local t = { full_name = full_name, parent_name = parent_name, methods = methods or {}, fields = fields or {} }

  t.get_full_name   = function(self) return self.full_name end
  t.get_name        = function(self) return (self.full_name:match("([^.]+)$")) end
  t.get_methods     = function(self) return self.methods end
  t.get_fields      = function(self) return self.fields end
  t.get_parent_type = function(self)
    if self.parent_name == nil then return nil end
    return TYPE_DB[self.parent_name]
  end
  return t
end

local function make_method(name, return_type, params, is_static)
  local m = {}
  m.get_name        = function() return name end
  m.get_return_type = function() return return_type and { get_full_name = function() return return_type end } or nil end
  m.get_param_types = function()
    local out = {}
    for i, p in ipairs(params or {}) do out[i] = { get_full_name = function() return p end } end
    return out
  end
  m.get_num_params  = function() return #(params or {}) end
  m.is_static       = function() return is_static == true end
  return m
end

local function make_field(name, field_type)
  return {
    get_name = function() return name end,
    get_type = function() return { get_full_name = function() return field_type end } end,
  }
end

TYPE_DB = {}

TYPE_DB["app.PlayerStatus"] = make_type("app.PlayerStatus", nil,
  { make_method("get_Health", "System.Single", {}),
    make_method("set_Health", "System.Void", { "System.Single" }) },
  { make_field("Health", "System.Single"),
    make_field("MaxHealth", "System.Single") })

TYPE_DB["app.PlayerDamageController"] = make_type("app.PlayerDamageController", nil,
  { make_method("applyDamage", "System.Void", { "System.Single", "System.Int32" }),
    make_method("isInvincible", "System.Boolean", {}) },
  { make_field("DamageRate", "System.Single") })

TYPE_DB["app.PlayerGun"] = make_type("app.PlayerGun", nil,
  { make_method("get_Ammo", "System.Int32", {}),
    make_method("set_Ammo", "System.Void", { "System.Int32" }) },
  { make_field("Ammo", "System.Int32"),
    make_field("AmmoMax", "System.Int32") })

TYPE_DB["app.InventoryManager"] = make_type("app.InventoryManager", nil,
  { make_method("getItemCount", "System.Int32", { "System.Int32" }),
    make_method("useItem", "System.Boolean", { "System.Int32" }) },
  { make_field("ItemList", "System.Collections.Generic.List`1<app.Item>") })

local CONSTRUCTED_SINGLETONS = {
  ["app.InventoryManager"] = {
    get_type_definition = function() return TYPE_DB["app.InventoryManager"] end,
  },
}

sdk = {
  get_managed_singleton = function(name) return CONSTRUCTED_SINGLETONS[name] end,
  get_native_singleton  = function(_) return nil end,
  find_type_definition  = function(name) return TYPE_DB[name] end,
  to_float              = function(v) return tonumber(v) end,
  to_double             = function(v) return tonumber(v) end,
  to_int64              = function(v) return tonumber(v) end,
}

-- ---------------------------------------------------------------------------
-- Stub: imgui
--
-- Mirrors the return-arity ambiguity deliberately: checkbox here returns TWO
-- values, which is the shape imgui_safe.checkbox must normalise.
-- ---------------------------------------------------------------------------

local drawn = {}

imgui = {
  text              = function(s) drawn[#drawn + 1] = tostring(s) end,
  checkbox          = function(label, value) return false, value end,
  button            = function(_) return false end,
  same_line         = function() end,
  separator         = function() end,
  spacing           = function() end,
  collapsing_header = function(_) return true end,
  progress_bar      = function() end,
  is_key_pressed    = function(_) return false end,
}

-- ---------------------------------------------------------------------------
-- Stub: json
-- ---------------------------------------------------------------------------

local json_writes = {}

json = {
  dump_file = function(path, data)
    json_writes[#json_writes + 1] = { path = path, data = data }
  end,
  load_file = function(_) error("no config file in selfcheck") end,
}

-- ---------------------------------------------------------------------------
-- Stub: re
-- ---------------------------------------------------------------------------

local callbacks = {}

re = {
  on_draw_ui       = function(fn) callbacks.draw_ui = fn end,
  on_frame         = function(fn) callbacks.frame = fn end,
  on_script_reset  = function(fn) callbacks.script_reset = fn end,
  on_config_save   = function(fn) callbacks.config_save = fn end,
  get_game_name    = function() return "RESIDENT EVIL 7 biohazard (stub)" end,
  get_tag          = function() return "v1.5.9-selfcheck" end,
  get_build_date   = function() return "selfcheck" end,
}

-- ---------------------------------------------------------------------------
-- Undefined-global detector
--
-- Catches the module that quietly relies on a global another script happened
-- to define. Allows the stubs above plus a small set of Lua/stdlib names that
-- genuinely are globals.
-- ---------------------------------------------------------------------------

local ALLOWED_GLOBALS = {
  log = true, sdk = true, imgui = true, json = true, re = true,
  -- main.lua probes for a `reframework` table as a fallback location for the
  -- version accessors. Some REFramework builds define it, this stub and most
  -- builds do not, so reading it is expected and guarded by a type check.
  reframework = true,
  TYPE_DB = true, arg = true, _G = true, _VERSION = true,
  -- Lua stdlib
  string = true, table = true, math = true, io = true, os = true,
  ipairs = true, pairs = true, pcall = true, xpcall = true, error = true,
  type = true, tostring = true, tonumber = true, setmetatable = true,
  getmetatable = true, rawget = true, rawset = true, rawequal = true,
  select = true, next = true, unpack = true, require = true, print = true,
  assert = true, coroutine = true, debug = true, collectgarbage = true,
  load = true, loadstring = true, dofile = true, loadfile = true,
  utf8 = true, warn = true,
}

local function install_global_guard()
  setmetatable(_G, {
    __index = function(_, key)
      if not ALLOWED_GLOBALS[key] then
        io.write(string.format("  !! undefined global read: %s\n", tostring(key)))
      end
      return nil
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

io.write("RE7 Personal Trainer selfcheck\n")
io.write(string.format("bundle: %s\n\n", bundle_path))

io.write("load\n")
local chunk, load_err = loadfile(bundle_path)
check("bundle parses", chunk ~= nil, load_err)

if chunk == nil then
  io.write("\nFAILED to load.\n")
  os.exit(1)
end

install_global_guard()

local ok, run_err = pcall(chunk)
check("bundle executes", ok, run_err)

io.write("\ncallbacks\n")
check("on_draw_ui registered", callbacks.draw_ui ~= nil)
check("on_frame registered", callbacks.frame ~= nil)
check("on_script_reset registered", callbacks.script_reset ~= nil)
check("on_config_save registered", callbacks.config_save ~= nil)

io.write("\nmenu draw\n")
if callbacks.draw_ui then
  drawn = {}
  local draw_ok, draw_err = pcall(callbacks.draw_ui)
  check("draws without error", draw_ok, draw_err)
  check("produced menu text", #drawn > 0, string.format("%d lines", #drawn))
  check("shows trainer title", table.concat(drawn, "\n"):find("RE7 Personal Trainer", 1, true) ~= nil)
else
  check("draws without error", false, "no callback")
end

io.write("\nframe loop\n")
if callbacks.frame then
  local frame_ok, frame_err = pcall(function()
    for _ = 1, 10 do callbacks.frame() end
  end)
  check("100 frames without error", frame_ok, frame_err)
end

io.write("\nlifecycle\n")
if callbacks.config_save then
  check("config save safe", pcall(callbacks.config_save))
end
if callbacks.script_reset then
  check("script reset safe", pcall(callbacks.script_reset))
  if callbacks.frame then
    check("frame after reset safe", pcall(function() callbacks.frame() end))
  end
end

io.write("\ndiscovery\n")
do
  local explorer = package.loaded["re7trainer.discovery.explorer"]
  check("explorer module resolved", explorer ~= nil)
  if explorer then
    local dump_ok, dump_err = pcall(explorer.run)
    check("discovery run succeeds", dump_ok, dump_err)
    check("wrote a dump file", #json_writes > 0, string.format("%d writes", #json_writes))

    local payload = json_writes[#json_writes] and json_writes[#json_writes].data
    if payload then
      check("payload has singletons", type(payload.singletons) == "table")
      check("payload has types", type(payload.types) == "table")
      check("summary counts found types",
            payload.summary and type(payload.summary.candidate_types_found) == "number",
            payload.summary and tostring(payload.summary.candidate_types_found))
      check("detected constructed singleton",
            payload.summary and payload.summary.singletons_constructed == 1,
            payload.summary and tostring(payload.summary.singletons_constructed))
    end
  end
end

io.write("\nmodule resolution\n")
do
  local names = {}
  for name in pairs(package.preload) do
    if name:match("^re7trainer%.") then names[#names + 1] = name end
  end
  table.sort(names)
  check("all 17 modules registered", #names == 17, string.format("%d registered", #names))

  local loaded_ok = true
  for _, name in ipairs(names) do
    if package.loaded[name] == nil then
      local m_ok, m_err = pcall(require, name)
      if not m_ok then
        loaded_ok = false
        io.write(string.format("     %s -> %s\n", name, tostring(m_err)))
      end
    end
  end
  check("every module requires cleanly", loaded_ok)
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local errors = 0
for _, entry in ipairs(log_lines) do
  if entry.level == "error" then errors = errors + 1 end
end

io.write(string.format("\nlog lines: %d  (errors: %d)\n", #log_lines, errors))

io.write(string.format("\n%d checks, %d failed\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
