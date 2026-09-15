--[[--------------------------------------------------------------------------
  re7trainer.state — the single source of truth for trainer state.

  Two kinds of state live here and they must not be confused:

    PERSISTED  — user preferences. Booleans only, written to disk by config.lua.
                 Cheats default to OFF, always. A trainer that turns itself on
                 when the game loads is a trainer that surprises you at the
                 worst moment.

    RUNTIME    — facts about the current session: whether the SDK is reachable,
                 whether a subsystem has actually been discovered, whether the
                 player object is currently valid. Never written to disk,
                 because none of it is meaningful in the next session.

  The `*_supported` flags deserve emphasis. They start false and are only set
  true by a successful discovery. The UI reads them to decide whether a toggle
  is live or greyed out. That is the mechanism which prevents this trainer from
  presenting a switch that silently does nothing — the failure mode this whole
  project is built to avoid.
----------------------------------------------------------------------------]]

local M = {}

--- Persisted user preferences. Defaults are all OFF.
M.prefs = {
  trainer_enabled  = true,
  god_mode         = false,
  infinite_ammo    = false,
  infinite_items   = false,
  debug_mode       = false,
  discovery_mode   = false,
  log_discovery    = true,
}

--- Session facts. Reset by M.reset_runtime().
M.runtime = {
  -- Environment
  sdk_available     = false,
  initialized       = false,
  init_error        = nil,

  -- Game identity, filled in at startup from the running title
  game_name         = nil,
  game_ready        = false,

  -- Per-subsystem discovery status. Both must be true before the matching
  -- cheat will enable: something was found, AND we can act on it.
  health_supported    = false,
  health_reason       = "not yet discovered",
  ammo_supported      = false,
  ammo_reason         = "not yet discovered",
  inventory_supported = false,
  inventory_reason    = "not yet discovered",

  -- Live values captured by the probes, for display only. These are numbers,
  -- never object references, so they are safe to keep across frames.
  health_current    = nil,
  health_max        = nil,
  ammo_current      = nil,
  item_count        = nil,

  -- Discovery bookkeeping
  discovery_runs    = 0,
  discovery_last    = nil,
  last_dump_path    = nil,

  -- Diagnostics
  error_count       = 0,
}

--- Record that a subsystem was successfully discovered and can be controlled.
-- @param subsystem string  "health" | "ammo" | "inventory"
-- @param reason string     short human-readable justification
function M.mark_supported(subsystem, reason)
  M.runtime[subsystem .. "_supported"] = true
  M.runtime[subsystem .. "_reason"] = reason or "discovered"
end

--- Record that a subsystem was probed and could NOT be controlled.
-- Leaves the flag false so the UI keeps the toggle disabled.
-- @param subsystem string
-- @param reason string
function M.mark_unsupported(subsystem, reason)
  M.runtime[subsystem .. "_supported"] = false
  M.runtime[subsystem .. "_reason"] = reason or "not discovered"
end

--- @param subsystem string
-- @return boolean
function M.is_supported(subsystem)
  return M.runtime[subsystem .. "_supported"] == true
end

--- Increment the error counter. Used by the UI to surface "something is going
-- wrong" without the user having to read the log.
function M.note_error()
  M.runtime.error_count = M.runtime.error_count + 1
end

--- Clear everything that describes the current session.
--
-- Called on scene change and on script reset. Deliberately does NOT touch
-- M.prefs: the user's toggles should survive a script reload, and the cheat
-- modules re-validate their targets before acting on them anyway.
function M.reset_runtime()
  M.runtime.sdk_available     = false
  M.runtime.initialized       = false
  M.runtime.init_error        = nil
  M.runtime.game_ready        = false
  M.runtime.health_supported  = false
  M.runtime.health_reason     = "not yet discovered"
  M.runtime.ammo_supported    = false
  M.runtime.ammo_reason       = "not yet discovered"
  M.runtime.inventory_supported = false
  M.runtime.inventory_reason  = "not yet discovered"
  M.runtime.health_current    = nil
  M.runtime.health_max        = nil
  M.runtime.ammo_current      = nil
  M.runtime.item_count        = nil
  M.runtime.discovery_runs    = 0
  M.runtime.discovery_last    = nil
  M.runtime.error_count       = 0
  -- last_dump_path is intentionally preserved: it points at a file on disk
  -- that still exists and the user may still want to open it.
end

--- Convenience: is the trainer allowed to touch the game at all right now?
-- @return boolean
function M.is_active()
  return M.prefs.trainer_enabled == true and M.runtime.sdk_available == true
end

return M
