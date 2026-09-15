--[[--------------------------------------------------------------------------
  re7trainer.ui.debug_menu — the developer panel.

  Rendered inside the main panel's Developer section, after the discovery
  controls. Its job is to make the trainer's internal state visible so that a
  problem can be diagnosed without reading source.

  DESIGN CONSTRAINT
  -----------------
  This panel must never be the thing that breaks. It draws inside REFramework's
  menu, and an error here would take the whole menu down. So every value is
  printed defensively, unknown values render as "unknown" rather than as a
  misleading zero, and nothing here mutates game state.

  It deliberately does NOT show speculative values. If health has not been
  discovered, there is no health line — not a line reading 0.
----------------------------------------------------------------------------]]

local W = require("re7trainer.utils.imgui_safe")
local state = require("re7trainer.state")
local logger = require("re7trainer.logger")
local objects = require("re7trainer.utils.object_helpers")
local config = require("re7trainer.config")

local M = {}

--- Format a value for display, mapping nil to an explicit "unknown".
-- @param value any
-- @return string
local function show(value)
  if value == nil then
    return "unknown"
  end
  return tostring(value)
end

--- Draw the environment block: what are we actually running against?
local function draw_environment()
  local r = state.runtime

  W.text("Environment")
  W.field("  SDK available", show(r.sdk_available))
  W.field("  Initialised", show(r.initialized))
  W.field("  Game name", show(r.game_name))
  W.field("  Game ready", show(r.game_ready))
  W.field("  Frame", tostring(logger.frame()))
  W.field("  Cached handles", tostring(objects.cache_size()))
  W.field("  Errors logged", tostring(r.error_count))

  if r.init_error ~= nil then
    W.text("  init error: " .. tostring(r.init_error))
  end
end

--- Draw the discovery status block.
local function draw_discovery_state()
  local r = state.runtime

  W.spacing()
  W.text("Subsystem discovery")
  W.field("  health supported", show(r.health_supported))
  W.field("  health reason", show(r.health_reason))
  W.field("  ammo supported", show(r.ammo_supported))
  W.field("  ammo reason", show(r.ammo_reason))
  W.field("  inventory supported", show(r.inventory_supported))
  W.field("  inventory reason", show(r.inventory_reason))
  W.field("  discovery runs", tostring(r.discovery_runs))
  W.field("  last dump file", show(r.last_dump_path))
end

--- Draw the live-value block, skipping anything not yet measured.
local function draw_live_values()
  local r = state.runtime

  W.spacing()
  W.text("Measured values")

  local any = false
  if r.health_current ~= nil then
    W.field("  health", string.format("%.1f", r.health_current))
    any = true
  end
  if r.health_max ~= nil then
    W.field("  health max", string.format("%.1f", r.health_max))
    any = true
  end
  if r.ammo_current ~= nil then
    W.field("  magazine", string.format("%.0f", r.ammo_current))
    any = true
  end
  if r.item_count ~= nil then
    W.field("  tracked items", string.format("%.0f", r.item_count))
    any = true
  end

  if not any then
    W.muted("nothing measured yet - run a discovery pass from inside gameplay")
  end
end

--- Draw the candidate-name block: what we will ask the game about.
local function draw_candidates()
  local explorer = require("re7trainer.discovery.explorer")
  local types = require("re7trainer.utils.type_helpers")

  W.spacing()
  W.text("Candidate types (exist in this build?)")

  for group, names in pairs(explorer.CANDIDATE_TYPES) do
    local present, missing = 0, 0
    for _, name in ipairs(names) do
      if types.exists(name) then
        present = present + 1
      else
        missing = missing + 1
      end
    end

    W.field("  " .. group, string.format("%d present, %d missing", present, missing))
  end
end

--- Draw the maintenance controls.
local function draw_controls()
  W.spacing()
  W.text("Maintenance")

  if W.button("Save settings now") then
    if config.save() then
      W.text("  saved")
    else
      W.text("  save failed - see log")
    end
  end

  if W.button("Clear cached object handles") then
    objects.release_all()
    W.text("  cleared")
  end
end

--- Draw the whole debug panel.
function M.draw()
  if not W.available() then
    return
  end

  draw_environment()
  draw_discovery_state()
  draw_live_values()
  draw_candidates()
  draw_controls()
end

return M
