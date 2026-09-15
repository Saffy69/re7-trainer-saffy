--[[--------------------------------------------------------------------------
  re7trainer.main — entry point.

  WHAT THIS FILE DOES
  -------------------
  Wires the modules together, registers the REFramework callbacks, and runs the
  per-frame update. That is all. Every behaviour lives in a module; this file
  should read as a table of contents.

  CALLBACK CHOICES, AND WHY
  -------------------------
  re.on_draw_ui   draws the trainer panel inside REFramework's own menu.
                  Runs on the render thread. Nothing here mutates game state.
  re.on_frame     per-frame work. Runs on the game's main thread, which is the
                  only thread where touching game objects is safe. This is
                  where cheat update() calls happen.
  re.on_script_reset
                  fires when REFramework reloads scripts. We drop cached object
                  handles, because they point into a process state that may
                  have moved on.
  re.on_config_save
                  fires continuously while the menu is open, so the actual
                  write is gated on a real change (config.save_if_changed).

  All four callback names were confirmed present as literal strings in the
  user's installed dinput8.dll. See docs/COMPATIBILITY.md.

  FAILURE PHILOSOPHY
  ------------------
  Initialisation is wrapped so that a failure at any stage leaves the trainer
  loaded but inert, with the reason visible in the menu. It must never be
  possible for a problem in this mod to stop the game from running, and it must
  never be possible for the mod to fail silently — "inert and explained" is the
  target state.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local config = require("re7trainer.config")

local health_cheat = require("re7trainer.cheats.health")
local ammo_cheat = require("re7trainer.cheats.ammo")
local inventory_cheat = require("re7trainer.cheats.inventory")

local menu = require("re7trainer.ui.menu")
local objects = require("re7trainer.utils.object_helpers")

local M = {}

M.VERSION = "0.1.0"

--- Virtual key codes for the hotkeys.
-- F6/F7/F8 are 0x75/0x76/0x77 in the Windows VK scheme.
local HOTKEYS = {
  { vk = 0x75, key = "god_mode",       cheat = health_cheat,    label = "God Mode" },
  { vk = 0x76, key = "infinite_ammo",  cheat = ammo_cheat,      label = "Infinite Ammo" },
  { vk = 0x77, key = "infinite_items", cheat = inventory_cheat, label = "Infinite Items" },
}

--- Set false the first time the key API fails, so we stop trying.
local hotkeys_usable = true

--- Set true once the one-time startup banner has been emitted.
local announced = false

-- ---------------------------------------------------------------------------
-- Game identification
-- ---------------------------------------------------------------------------

--- Ask REFramework what it knows about the running title.
--
-- These accessors (get_game_name, get_commit_hash, get_tag, get_build_date)
-- were confirmed present as strings in the installed dinput8.dll, but which
-- table holds them is not something we can prove without running the game. So
-- each is probed across the plausible locations and any failure is simply
-- reported as unknown rather than guessed at.
-- @return table
local function detect_environment()
  local info = {
    game_name = nil,
    framework_version = nil,
    framework_build = nil,
  }

  local function probe(name)
    for _, tbl in ipairs({ re, reframework, sdk }) do
      if type(tbl) == "table" and type(tbl[name]) == "function" then
        local ok, value = pcall(tbl[name])
        if ok and value ~= nil then
          return tostring(value)
        end
      end
    end
    return nil
  end

  info.game_name = probe("get_game_name")
  info.framework_build = probe("get_build_date")
  info.framework_version = probe("get_tag") or probe("get_commit_hash")

  return info
end

-- ---------------------------------------------------------------------------
-- Hotkeys
-- ---------------------------------------------------------------------------

--- Toggle a cheat from a hotkey.
--
-- Deliberately routes through the same enable()/disable() path the checkbox
-- uses, so a hotkey cannot enable something the UI would have refused. If the
-- cheat is not supported, the press is reported and ignored.
-- @param entry table  one of HOTKEYS
local function handle_hotkey(entry)
  local wanted = state.prefs[entry.key] ~= true

  if wanted then
    local ok, message = entry.cheat.enable()
    if ok then
      state.prefs[entry.key] = true
      logger.info(nil, entry.label .. " enabled via hotkey.")
    else
      logger.warn(nil, entry.label .. " hotkey ignored: " .. tostring(message))
    end
  else
    entry.cheat.disable()
    state.prefs[entry.key] = false
    logger.info(nil, entry.label .. " disabled via hotkey.")
  end
end

--- Poll the hotkeys. Never throws.
local function poll_hotkeys()
  if not hotkeys_usable then
    return
  end
  if type(imgui) ~= "table" or type(imgui.is_key_pressed) ~= "function" then
    hotkeys_usable = false
    logger.once("hotkeys:noapi", "warn", nil,
                "imgui.is_key_pressed is unavailable; hotkeys are disabled. Use the menu toggles.")
    return
  end

  for _, entry in ipairs(HOTKEYS) do
    local ok, pressed = pcall(imgui.is_key_pressed, entry.vk)
    if not ok then
      hotkeys_usable = false
      logger.once("hotkeys:fail", "warn", nil,
                  "Key polling failed; hotkeys are disabled. Use the menu toggles. (" ..
                  tostring(pressed) .. ")")
      return
    end
    if pressed == true then
      handle_hotkey(entry)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Initialisation
-- ---------------------------------------------------------------------------

--- Bring the trainer up. Safe to call more than once.
local function initialize()
  if state.runtime.initialized then
    return
  end

  logger.reset()

  -- Step 1: is REFramework actually there? Everything else depends on this.
  if not require("re7trainer.utils.safe_call").has_sdk() then
    state.runtime.init_error = "REFramework SDK not reachable"
    state.runtime.sdk_available = false
    logger.error(nil, "REFramework SDK is not reachable. The trainer will load but do nothing.")
    state.runtime.initialized = true
    return
  end
  state.runtime.sdk_available = true

  -- Step 2: identify what we are running against.
  local env = detect_environment()
  state.runtime.game_name = env.game_name

  logger.info(nil, string.format(
    "RE7 Personal Trainer v%s starting. Game: %s. Framework: %s (%s).",
    M.VERSION,
    env.game_name or "unknown",
    env.framework_version or "unknown",
    env.framework_build or "unknown build date"))

  -- Step 3: user preferences.
  config.load()

  -- Step 4: cheat modules. initialize() never touches the game.
  health_cheat.initialize()
  ammo_cheat.initialize()
  inventory_cheat.initialize()

  state.runtime.initialized = true

  -- Say plainly what state we are in. This is the "unsupported/undiscovered
  -- game build" message the project requires, and it is emitted once.
  if not announced then
    announced = true
    logger.info(nil, "No cheat is functional yet: health, ammo and inventory APIs have "
                  .. "not been discovered. Open the Developer section and run a discovery "
                  .. "dump from inside gameplay.")
  end
end

-- ---------------------------------------------------------------------------
-- REFramework callbacks
-- ---------------------------------------------------------------------------

-- Draw the trainer panel inside REFramework's menu.
if type(re) == "table" and type(re.on_draw_ui) == "function" then
  re.on_draw_ui(function()
    local ok, err = pcall(menu.draw)
    if not ok then
      -- Reporting this every frame would flood the log; object_helpers'
      -- throttle inside menu.draw usually prevents it, so log once here.
      logger.once("menu:draw", "error", "Error", "Menu draw failed: " .. tostring(err))
    end
  end)
else
  logger.error(nil, "re.on_draw_ui is unavailable; the trainer menu cannot be shown.")
end

-- Per-frame update.
if type(re) == "table" and type(re.on_frame) == "function" then
  re.on_frame(function()
    logger.tick()

    if not state.runtime.initialized then
      local ok, err = pcall(initialize)
      if not ok then
        state.runtime.init_error = tostring(err)
        state.runtime.initialized = true
        logger.error(nil, "Initialisation failed: " .. tostring(err))
      end
      return
    end

    poll_hotkeys()

    if not state.is_active() then
      return
    end

    -- Cheat updates. Each returns immediately when its subsystem has not been
    -- discovered, so an undiscovered build costs nothing per frame.
    health_cheat.update()
    ammo_cheat.update()
    inventory_cheat.update()
  end)
else
  logger.error(nil, "re.on_frame is unavailable; the trainer cannot run.")
end

-- Snapshot of the persisted preferences as of the last save, used to detect
-- real changes. Declared here, before any callback that closes over it:
-- declaring it further down would make the closures above capture a global
-- instead of this local, which pollutes the shared Lua state and silently
-- breaks the change detection.
local prefs_snapshot = nil

-- Drop cached handles when REFramework reloads scripts.
if type(re) == "table" and type(re.on_script_reset) == "function" then
  re.on_script_reset(function()
    objects.release_all()
    health_cheat.reset()
    ammo_cheat.reset()
    inventory_cheat.reset()
    logger.reset()
    prefs_snapshot = nil
  end)
end

-- Persist preferences, but only when they actually changed.
if type(re) == "table" and type(re.on_config_save) == "function" then
  re.on_config_save(function()
    if prefs_snapshot == nil then
      prefs_snapshot = config.snapshot()
      return
    end
    config.save_if_changed(prefs_snapshot)
    prefs_snapshot = config.snapshot()
  end)
end

-- Initialize immediately so the menu is meaningful the first time it opens,
-- rather than only after the first frame.
pcall(initialize)

return M
