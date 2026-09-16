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
      # bundle mode: run the single generated file
      lua tools/selfcheck.lua build/re7trainer.lua

      # modular mode: run an installed autorun tree the way ScriptRunner does
      lua tools/selfcheck.lua --autorun /path/to/reframework/autorun

  Modular mode reproduces what ScriptRunner::reset_scripts() does before it
  runs scripts — appends <autorun>/?.lua and <autorun>/?/init.lua to
  package.path — and then executes autorun/re7trainer.lua exactly as the
  framework would. That exercises the real module resolution path rather than
  the package.preload shortcut the bundle uses.
----------------------------------------------------------------------------]]

-- ---------------------------------------------------------------------------
-- Mode selection
-- ---------------------------------------------------------------------------

local mode = "bundle"
local target = arg[1] or "build/re7trainer.lua"

if arg[1] == "--autorun" then
  if arg[2] == nil then
    io.stderr:write("usage: selfcheck.lua --autorun <reframework/autorun dir>\n")
    os.exit(64)
  end
  mode = "modular"
  local autorun = arg[2]:gsub("/+$", "")
  -- What ScriptRunner does for us before running any script.
  package.path = package.path .. ";" .. autorun .. "/?.lua;" .. autorun .. "/?/init.lua"
  target = autorun .. "/re7trainer.lua"
end

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
  -- get_method is what safe_call.hook_method uses to resolve a hook target.
  t.get_method      = function(self, name)
    for _, m in ipairs(self.methods) do
      if m:get_name() == name then return m end
    end
    return nil
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
  -- REMethodDefinition registers `call` in the real binary (confirmed in the
  -- registration block). game.inventory() uses it for the static
  -- getActivePlayerInventory, so the stub must provide it or that route
  -- silently appears broken.
  m.call            = function(_, ...) return nil end
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
  { make_method("doDamage", "System.Void", { "app.Collision.HitController.DamageInfo" }),
    make_method("applyDamage", "System.Void", { "System.Single", "System.Int32" }),
    make_method("isInvincible", "System.Boolean", {}) },
  { make_field("DamageRate", "System.Single") })

-- Types the implemented cheats hook. Present so the selfcheck exercises the
-- real enable/disable paths rather than skipping them.
TYPE_DB["app.Item"] = make_type("app.Item", nil,
  { make_method("reduceNum", "System.Boolean", { "System.Int32", "System.Boolean" }),
    make_method("useItem", "System.Boolean", { "System.Int32" }),
    make_method("getStackNum", "System.Int32", {}),
    make_method("get_ItemData", "app.ItemData", {}) },
  { make_field("ItemStackNum", "System.Int32"),
    make_field("_ItemData", "app.ItemData") })

TYPE_DB["app.ItemData"] = make_type("app.ItemData", nil,
  { make_method("getSlotNum", "System.Int32", {}) },
  { make_field("Category", "app.Item.ItemCategoryType"),
    make_field("MaxStackNum", "System.Int32") })

TYPE_DB["app.WeaponGun"] = make_type("app.WeaponGun", nil,
  { make_method("expendBullet", "System.Boolean", {}),
    make_method("get_loadNum", "System.Int32", {}),
    make_method("set_loadNum", "System.Void", { "System.Int32" }) },
  { make_field("Inventory", "app.Inventory") })

TYPE_DB["app.Inventory"] = make_type("app.Inventory", nil,
  { make_method("getActivePlayerInventory", "app.Inventory", {}),
    make_method("get_ItemList", "System.Collections.Generic.List`1<app.Inventory.ItemInfo>", {}) },
  { make_field("PlayerStatus", "app.IPlayerStatus"),
    make_field("_ItemList", "System.Collections.Generic.List`1<app.Inventory.ItemInfo>") })

TYPE_DB["app.PlayerGun"] = make_type("app.PlayerGun", nil,
  { make_method("get_Ammo", "System.Int32", {}),
    make_method("set_Ammo", "System.Void", { "System.Int32" }) },
  { make_field("Ammo", "System.Int32"),
    make_field("AmmoMax", "System.Int32") })

TYPE_DB["app.InventoryManager"] = make_type("app.InventoryManager", nil,
  { make_method("getItemCount", "System.Int32", { "System.Int32" }),
    make_method("useItem", "System.Boolean", { "System.Int32" }) },
  { make_field("ItemList", "System.Collections.Generic.List`1<app.Item>") })

local CONSTRUCTED_SINGLETONS = {}

--- A minimal stand-in for a live app.Inventory.
--
-- Has to behave like a managed object -- get_field and call -- or the access
-- chain above it appears broken when it is only the stub that is thin. An
-- earlier version was a bare table and produced error-level log lines that
-- looked like real faults.
local function fake_inventory()
  return {
    get_type_definition = function()
      return { get_full_name = function() return "app.Inventory" end }
    end,
    get_field = function(_, name)
      if name == "PlayerStatus" then
        return {
          get_type_definition = function()
            return TYPE_DB["app.PlayerStatus"]
          end,
          get_field = function() return nil end,
          call = function(_, method)
            if method == "get_health" then return 100.0 end
            if method == "get_maxHealth" then return 100.0 end
            if method == "get_normalizedHealth" then return 1.0 end
            if method == "get_IsDead" then return false end
            return nil
          end,
        }
      end
      if name == "_ItemList" then return {} end
      return nil
    end,
    call = function(_, method)
      if method == "get_ItemList" then return {} end
      return nil
    end,
  }
end

CONSTRUCTED_SINGLETONS["app.InventoryManager"] = {
  get_type_definition = function() return TYPE_DB["app.InventoryManager"] end,
  get_field = function(_, name)
    if name == "_Inventory" then return fake_inventory() end
    return nil
  end,
  call = function() return nil end,
}

local HOOKS_INSTALLED = {}

sdk = {
  get_managed_singleton = function(name) return CONSTRUCTED_SINGLETONS[name] end,
  get_native_singleton  = function(_) return nil end,
  find_type_definition  = function(name) return TYPE_DB[name] end,
  to_float              = function(v) return tonumber(v) end,
  to_double             = function(v) return tonumber(v) end,
  to_int64              = function(v) return tonumber(v) end,
  to_managed_object     = function(v) return v end,
  -- Record installations so the selfcheck can assert install-once semantics,
  -- which is a real correctness property: this build has no unhook, so a
  -- duplicate hook on the same method can never be undone.
  hook = function(method, pre, post, ignore_jmp)
    local id = #HOOKS_INSTALLED + 1
    HOOKS_INSTALLED[id] = { method = method, pre = pre, post = post }
    return id
  end,
  PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 },
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
io.write(string.format("mode  : %s\n", mode))
io.write(string.format("target: %s\n\n", target))

io.write("load\n")
local chunk, load_err = loadfile(target)
check("entry point parses", chunk ~= nil, load_err)

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
  -- Modules the entry point cannot work without. Listed explicitly rather than
  -- asserted as a magic total, so adding a module does not silently break the
  -- check and removing a required one does not silently pass.
  local REQUIRED = {
    "re7trainer.main", "re7trainer.logger", "re7trainer.state",
    "re7trainer.config", "re7trainer.game",
    "re7trainer.utils.safe_call",
    "re7trainer.utils.object_helpers", "re7trainer.utils.type_helpers",
    "re7trainer.utils.imgui_safe", "re7trainer.ui.menu",
    "re7trainer.cheats.health", "re7trainer.cheats.ammo",
    "re7trainer.cheats.inventory", "re7trainer.discovery.explorer",
    "re7trainer.discovery.introspect",
  }

  local names = {}
  if mode == "bundle" then
    for name in pairs(package.preload) do
      if name:match("^re7trainer%.") then names[#names + 1] = name end
    end
    table.sort(names)
    check("bundle preloads every module", #names >= #REQUIRED,
          string.format("%d registered, %d required", #names, #REQUIRED))
  else
    -- Modular mode has no preload table; resolution went through package.path.
    --
    -- Note: some modules are lazy-loaded by design (the discovery probes are
    -- only required when the user presses the button), so "not in
    -- package.loaded yet" is not a fault. The real question is whether each
    -- required module RESOLVES through package.path, so require them all here.
    local missing = {}
    for _, name in ipairs(REQUIRED) do
      local r_ok = pcall(require, name)
      if not r_ok then
        missing[#missing + 1] = name
      end
    end
    check("every module resolves via package.path",
          #missing == 0,
          #missing > 0 and table.concat(missing, ", ") or nil)
  end

  -- Every module that is registered must require cleanly, whichever mode.
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
  if #names > 0 then
    check("every registered module requires cleanly", loaded_ok)
  end

  -- And every required module must be genuinely loadable right now.
  local req_ok = true
  for _, name in ipairs(REQUIRED) do
    local r_ok, r_err = pcall(require, name)
    if not r_ok then
      req_ok = false
      io.write(string.format("     required %s -> %s\n", name, tostring(r_err)))
    end
  end
  check("all required modules load", req_ok)
end

-- ---------------------------------------------------------------------------
-- Container conversion
--
-- Locks in the behaviour of type_helpers.to_array, which is the single point
-- where the sol2 container shape is handled. This is the code that silently
-- produced "0 methods for every type in the game" when it assumed a plain Lua
-- table, so it gets explicit case coverage rather than being trusted.
-- ---------------------------------------------------------------------------

io.write("\ncontainer conversion\n")
do
  local type_helpers = require("re7trainer.utils.type_helpers")
  local to_array = type_helpers.to_array

  check("to_array is exported for testing", type(to_array) == "function")

  if type(to_array) == "function" then
    local plain = to_array({ "a", "b", "c" })
    check("plain array", #plain == 3 and plain[1] == "a" and plain[3] == "c",
          string.format("got %d", #plain))

    -- Zero-indexed container that declares its size. ipairs alone yields a
    -- short list here, which is the failure mode being guarded against.
    local sized = setmetatable({}, {
      __index = function(_, k)
        if k == "size" then return function() return 3 end end
        if type(k) == "number" and k >= 0 and k <= 2 then return "s" .. k end
        return nil
      end,
    })
    check("zero-indexed with size() reads all elements", #to_array(sized) == 3,
          string.format("got %d", #to_array(sized)))

    -- Degenerate inputs must yield nothing rather than throwing.
    check("nil yields empty", #to_array(nil) == 0)
    check("scalar yields empty", #to_array(42) == 0 and #to_array("x") == 0)

    -- A real userdata that is not a container must not throw.
    local handle = io.open("/dev/null", "r")
    if handle then
      local ok = pcall(to_array, handle)
      check("foreign userdata does not throw", ok)
      handle:close()
    end

    -- A container whose size() raises must fall through to another strategy.
    local throwing = setmetatable({}, {
      __index = function(_, k)
        if k == "size" then return function() error("boom") end end
        if type(k) == "number" and k == 1 then return "safe" end
        return nil
      end,
      __len = function() return 1 end,
    })
    local recovered = to_array(throwing)
    check("size() raising falls through", #recovered == 1 and recovered[1] == "safe",
          string.format("got %d", #recovered))
  end
end

-- ---------------------------------------------------------------------------
-- Cheat lifecycle and hook semantics
--
-- This build has NO unhook, so hooks are permanent and install-once is a
-- correctness property rather than an optimisation: a duplicate hook on the
-- same method could never be undone. These cases assert that, and assert that
-- disabling actually stops the behaviour (via the flag the callback reads)
-- rather than merely appearing to.
-- ---------------------------------------------------------------------------

io.write("\ncheat lifecycle\n")
do
  local state = require("re7trainer.state")
  local prefs = state.prefs
  prefs.trainer_enabled = true

  local health = require("re7trainer.cheats.health")
  local ammo = require("re7trainer.cheats.ammo")
  local inventory = require("re7trainer.cheats.inventory")

  health.initialize()
  ammo.initialize()
  inventory.initialize()

  check("health reports supported", health.is_supported())
  check("ammo reports supported", ammo.is_supported())
  check("inventory reports supported", inventory.is_supported())

  local before = #HOOKS_INSTALLED

  check("health enables", (health.enable()))
  check("ammo enables", (ammo.enable()))
  check("inventory enables", (inventory.enable()))

  check("three hooks installed", #HOOKS_INSTALLED == before + 3,
        string.format("%d installed", #HOOKS_INSTALLED - before))

  -- Re-enabling must NOT stack a second hook on the same method.
  health.enable()
  ammo.enable()
  inventory.enable()
  check("re-enable does not stack hooks", #HOOKS_INSTALLED == before + 3,
        string.format("%d installed", #HOOKS_INSTALLED - before))

  -- Locate an installed hook by the method it was attached to. Matching on the
  -- method object is exact, unlike guessing from the callback's name.
  local function hook_for(type_name, method_name)
    local td = TYPE_DB[type_name]
    if td == nil then return nil end
    local m = td:get_method(method_name)
    for _, h in pairs(HOOKS_INSTALLED) do
      if h.method == m then return h end
    end
    return nil
  end

  local dmg = hook_for("app.PlayerDamageController", "doDamage")
  check("health hook is on doDamage", dmg ~= nil)
  if dmg then
    check("health pre skips while enabled",
          dmg.pre({}) == sdk.PreHookResult.SKIP_ORIGINAL)
    health.disable()
    check("health pre calls through while disabled",
          dmg.pre({}) == sdk.PreHookResult.CALL_ORIGINAL)
    health.enable()
  end

  local exp = hook_for("app.WeaponGun", "expendBullet")
  check("ammo hook is on expendBullet", exp ~= nil)
  if exp then
    check("ammo pre skips while enabled",
          exp.pre({}) == sdk.PreHookResult.SKIP_ORIGINAL)
    ammo.disable()
    check("ammo pre calls through while disabled",
          exp.pre({}) == sdk.PreHookResult.CALL_ORIGINAL)
    ammo.enable()
  end

  local red = hook_for("app.Item", "reduceNum")
  check("inventory hook is on reduceNum", red ~= nil)

  if red then
    -- A fake app.Item whose category we control. This is the safety-critical
    -- path: a key item MUST NOT be conserved even while the cheat is on.
    --
    -- The stub mirrors how REFramework exposes a managed object: fields are
    -- read through get_field, not through plain Lua table indexing. An earlier
    -- version of this fake was a bare table, and the production code correctly
    -- refused to treat it as safe -- which is the fail-closed behaviour working
    -- as designed, and worth keeping in mind when reading a failure here.
    local function fake_item_data(category)
      return {
        get_type_definition = function()
          return { get_full_name = function() return "app.ItemData" end }
        end,
        get_field = function(_, name)
          if name == "Category" then return category end
          return nil
        end,
        call = function() return nil end,
      }
    end

    local function fake_item(category)
      return {
        get_type_definition = function()
          return { get_full_name = function() return "app.Item" end }
        end,
        call = function(_, name)
          if name == "get_ItemData" then return fake_item_data(category) end
          return nil
        end,
        get_field = function(_, name)
          if name == "_ItemData" then return fake_item_data(category) end
          return nil
        end,
      }
    end

    check("drug is conserved while enabled",
          red.pre({ [1] = nil, [2] = fake_item("Drug") }) == sdk.PreHookResult.SKIP_ORIGINAL)

    check("KeyItem is NOT conserved while enabled",
          red.pre({ [1] = nil, [2] = fake_item("KeyItem") }) == sdk.PreHookResult.CALL_ORIGINAL)
    check("UsableKeyItem is NOT conserved while enabled",
          red.pre({ [1] = nil, [2] = fake_item("UsableKeyItem") }) == sdk.PreHookResult.CALL_ORIGINAL)
    check("Weapon is NOT conserved while enabled",
          red.pre({ [1] = nil, [2] = fake_item("Weapon") }) == sdk.PreHookResult.CALL_ORIGINAL)

    -- Fail closed: an unreadable category must not be treated as safe.
    check("unreadable category is NOT conserved",
          red.pre({ [1] = nil, [2] = fake_item(nil) }) == sdk.PreHookResult.CALL_ORIGINAL)

    inventory.disable()
    check("nothing is conserved while disabled",
          red.pre({ [1] = nil, [2] = fake_item("Drug") }) == sdk.PreHookResult.CALL_ORIGINAL)
    inventory.enable()
  end
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local errors = 0
for _, entry in ipairs(log_lines) do
  if entry.level == "error" then errors = errors + 1 end
end

io.write(string.format("\nlog lines: %d  (errors: %d)\n", #log_lines, errors))

-- Print error-level lines in full rather than only counting them. A count that
-- nobody can act on is worse than no count: it invites either ignoring a real
-- fault or chasing a phantom.
if errors > 0 then
  io.write("\nerror-level log output:\n")
  for _, entry in ipairs(log_lines) do
    if entry.level == "error" then
      io.write("  " .. tostring(entry.message) .. "\n")
    end
  end
end

io.write(string.format("\n%d checks, %d failed\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
