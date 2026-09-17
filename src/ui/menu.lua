--[[--------------------------------------------------------------------------
  re7trainer.ui.menu — the main trainer panel inside the REFramework menu.

  DESIGN RULES FOLLOWED HERE
  --------------------------
    * A toggle is only interactive when the cheat behind it can actually run.
      Everything else renders as a disabled line carrying the reason. This is
      the single most important property of this UI: it never offers a switch
      that silently does nothing.
    * Status is stated in plain text, not colour. This build has no
      colored_text, and an indicator that depends on a missing binding is worse
      than no indicator.
    * No fake statistics. If a value has not been measured, it shows as unknown
      rather than as zero.

  LAYOUT
  ------
  Four collapsing sections, matching the requested structure:
      Status | Player | Weapons | Inventory
  plus the hotkey reference and the Developer section.

  HOTKEYS
  -------
  The keyboard bindings are real (imgui.is_key_pressed is present in this
  build) but they only ever drive toggles that are already enabled. Pressing F6
  on a build where a cheat cannot run does nothing and says so in the log — it
  does not force the flag on.
----------------------------------------------------------------------------]]

local W = require("re7trainer.utils.imgui_safe")
local state = require("re7trainer.state")
local logger = require("re7trainer.logger")

local M = {}

--- Which collapsible sections are open. Persisted only in memory; a menu that
--- reopens the same way every time is less annoying than one that remembers.
local open = {
  status = true,
  player = true,
  weapons = true,
  inventory = true,
  hotkeys = false,
  developer = false,
}

-- ---------------------------------------------------------------------------
-- Status section
-- ---------------------------------------------------------------------------

local function draw_status()
  local r = state.runtime

  W.field("Framework", r.sdk_available and "Loaded" or "NOT DETECTED")
  W.field("Game", r.game_name or "unknown")
  W.field("Trainer", r.initialized and "Ready" or "Initialising")

  if r.game_ready then
    W.text("Game state: gameplay")
  else
    W.text("Game state: not in gameplay (cheats idle)")
  end

  if r.error_count > 0 then
    W.text("Logged errors this session: " .. tostring(r.error_count))
  end

  if r.init_error ~= nil then
    W.text("Init problem: " .. tostring(r.init_error))
  end

  W.spacing()
  W.field("Cached object handles", tostring(require("re7trainer.utils.object_helpers").cache_size()))
end

-- ---------------------------------------------------------------------------
-- Cheat sections
-- ---------------------------------------------------------------------------

--- Render one cheat toggle, with its support state made explicit.
-- @param label string
-- @param pref_key string    key in state.prefs
-- @param subsystem string   "health" | "ammo" | "inventory"
-- @param cheat table        the cheat module, for status()
local function draw_cheat(label, pref_key, subsystem, cheat)
  local supported = state.runtime[subsystem .. "_supported"] == true

  if not supported then
    -- Not discovered: show why, and do not offer a live checkbox.
    W.button_disabled(label, state.runtime[subsystem .. "_reason"] or "not yet checked")
    return
  end

  local changed, value = W.checkbox(label, state.prefs[pref_key])
  if changed then
    state.prefs[pref_key] = value
    if value then
      local ok, message = cheat.enable()
      if not ok then
        -- The toggle was drawn as available but enable() refused. Put the
        -- preference back rather than leaving the UI claiming something is on
        -- when it is not.
        state.prefs[pref_key] = false
        W.text("  could not enable: " .. tostring(message))
      end
    else
      cheat.disable()
    end
  end

  W.text("  " .. cheat.status())

  -- Live readout, only when a probe has actually measured something.
  local readout = cheat.readout()
  if readout ~= nil then
    if readout.current ~= nil and readout.max ~= nil and readout.max > 0 then
      W.progress(readout.current / readout.max,
                 string.format("%.0f / %.0f", readout.current, readout.max))
    elseif readout.current ~= nil then
      W.field("  current", string.format("%.0f", readout.current))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Developer section
-- ---------------------------------------------------------------------------

local function draw_developer()
  local explorer = require("re7trainer.discovery.explorer")
  local debug_menu = require("re7trainer.ui.debug_menu")

  local changed, value = W.checkbox("Debug Mode", state.prefs.debug_mode)
  if changed then
    state.prefs.debug_mode = value
  end

  changed, value = W.checkbox("Discovery Mode", state.prefs.discovery_mode)
  if changed then
    state.prefs.discovery_mode = value
  end

  changed, value = W.checkbox("Log discovery output", state.prefs.log_discovery)
  if changed then
    state.prefs.log_discovery = value
  end

  W.spacing()

  if explorer.is_running() then
    W.text("Discovery running...")
  else
    if W.button("Run discovery dump") then
      local ok, result = explorer.run()
      if ok then
        W.text("Wrote " .. tostring(result))
      else
        W.text("Failed: " .. tostring(result))
      end
    end

    -- Separate button on purpose. The first dump reported 0 members for every
    -- type while name and parent lookups worked, which points at a shape
    -- mismatch in the member accessors rather than a missing API. This probe
    -- measures what those accessors actually return.
    if W.button("Probe reflection API") then
      local introspect = require("re7trainer.discovery.introspect")
      local ok, result = introspect.run()
      if ok then
        W.text("Wrote " .. tostring(result))
      else
        W.text("Failed: " .. tostring(result))
      end
    end
  end

  if state.runtime.discovery_last ~= nil then
    local s = state.runtime.discovery_last
    W.field("  last: types found", tostring(s.candidate_types_found))
    W.field("  last: types missing", tostring(s.candidate_types_missing))
    W.field("  last: singletons live", tostring(s.singletons_constructed))
  end

  if state.runtime.last_dump_path ~= nil then
    W.text("Output file: " .. tostring(state.runtime.last_dump_path))
  end

  W.spacing()
  debug_menu.draw()
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

--- Draw the trainer panel. Called from re.on_draw_ui.
function M.draw()
  if not W.available() then
    return
  end

  local health = require("re7trainer.cheats.health")
  local ammo = require("re7trainer.cheats.ammo")
  local inventory = require("re7trainer.cheats.inventory")

  W.text("RE7 Personal Trainer")

  -- The version is read lazily and defensively. menu.lua is loaded BY main.lua,
  -- so requiring it at file scope would be a circular require that yields a
  -- half-built module; by the time draw() runs, main is complete. The pcall is
  -- because this panel must never be the thing that breaks.
  local ok, main = pcall(require, "re7trainer.main")
  W.text("v" .. tostring(ok and main.VERSION or "unknown"))
  W.separator()

  -- Master switch. Turning this off disables every cheat without losing the
  -- individual preferences, so it works as a panic button.
  local changed, value = W.checkbox("Trainer enabled", state.prefs.trainer_enabled)
  if changed then
    state.prefs.trainer_enabled = value
    if not value then
      health.disable()
      ammo.disable()
      inventory.disable()
    end
  end

  if state.prefs.trainer_enabled ~= true then
    W.text("Trainer is off. Nothing will be modified.")
    W.separator()
  end

  if W.section_begin("Status") then
    draw_status()
  end

  if W.section_begin("Player") then
    draw_cheat(health.LABEL, "god_mode", "health", health)
  end

  if W.section_begin("Weapons") then
    draw_cheat(ammo.LABEL, "infinite_ammo", "ammo", ammo)
  end

  if W.section_begin("Inventory") then
    draw_cheat(inventory.LABEL, "infinite_items", "inventory", inventory)
  end

  if W.section_begin("Hotkeys") then
    W.text("God Mode        F6")
    W.text("Infinite Ammo   F7")
    W.text("Infinite Items  F8")
    W.spacing()
    W.muted("hotkeys only affect cheats that discovery has enabled")
  end

  if W.section_begin("Developer") then
    draw_developer()
  end
end

return M
