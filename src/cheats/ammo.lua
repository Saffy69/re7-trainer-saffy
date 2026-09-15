--[[--------------------------------------------------------------------------
  re7trainer.cheats.ammo — Infinite Ammo.

  READ THIS BEFORE ASSUMING IT DOES ANYTHING
  ------------------------------------------
  Structurally complete, functionally empty. Same reasoning as
  re7trainer.cheats.health: we know the weapon TYPE names
  (app.PlayerGun, app.PlayerWeaponChange, app.PlayerReloadSpeedRateTable, ...)
  from the user's own type dump, and we know nothing whatsoever about their
  members.

  THE REQUIREMENT THAT SHAPES THE DESIGN
  --------------------------------------
  Firing must leave the count unchanged. Twelve rounds stays twelve.

      NOT:  set ammo to 999999
      YES:  after firing, ammo is still 12

  Those are different interventions and only the second is wanted. Setting a
  large constant would also look wrong in the HUD, break the "you are nearly
  out" tension the game is built around, and is exactly the kind of blunt
  change that can desync from a separate reserve count.

  STRATEGY, in preference order
  -----------------------------
    1. PREVENT CONSUMPTION. Hook whichever operation decrements the magazine
       and skip it. The count is never written by us at all, so there is no
       window in which a wrong value is visible.
    2. CAPTURE AND RESTORE. Read the count immediately before and after the
       fire operation and rewrite it if it dropped. Requires a readable AND
       writable field, and introduces one frame where the HUD may show the
       decremented value.
    3. HOLD AT BASELINE. Record the count when enabled and rewrite it every
       frame. Crudest, most visible, last resort — and it would also undo any
       legitimate ammo pickup, which is why it is last.

  "No Reload" is deliberately NOT implemented. It was not requested, and
  suppressing reload would change weapon behaviour beyond what was asked for.

  A NOTE ON WHICH QUANTITY WE MEAN
  --------------------------------
  Magazine ammo, reserve ammo, and the inventory ammo stack are three different
  things. This module targets the magazine — the thing that goes down when you
  pull the trigger — because that is what the stated requirement describes.
  If discovery shows the magazine is not separately addressable, that gets
  documented as a limitation rather than silently redirected to a different
  counter that would produce a different behaviour from the one asked for.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")

local M = {}

M.NAME = "ammo"
M.LABEL = "Infinite Ammo"

--- "hook" | "capture_restore" | "hold_baseline", or nil until discovered.
local strategy = nil

--- Value captured at enable time, for the restore/baseline strategies.
local baseline = nil

--- Handle to whatever we hooked, so disable() can undo it.
local hook_handle = nil

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called once at startup. Never touches the game.
function M.initialize()
  strategy = nil
  baseline = nil
  hook_handle = nil
  logger.info("Ammo", "Module initialised. Awaiting discovery — no ammo API is known yet.")
end

--- @return boolean
function M.is_supported()
  return state.runtime.ammo_supported == true and strategy ~= nil
end

--- @return string
function M.status()
  if M.is_supported() then
    return "active via '" .. tostring(strategy) .. "' strategy"
  end
  return state.runtime.ammo_reason or "not yet discovered"
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.ammo_reason or "not yet discovered"
    logger.warn("Ammo", "Refusing to enable Infinite Ammo: " .. reason)
    return false, reason
  end

  if strategy == "hook" then
    -- TODO(discovery): sdk.hook the verified consumption method.
    logger.warn("Ammo", "Hook strategy selected but no verified method to hook.")
    return false, "hook strategy has no verified target"

  elseif strategy == "capture_restore" or strategy == "hold_baseline" then
    -- TODO(discovery): read the verified magazine field into `baseline`.
    logger.warn("Ammo", "Restore strategy selected but no verified field to read.")
    return false, "restore strategy has no verified field"
  end

  logger.warn("Ammo", "No usable strategy. This should be unreachable.")
  return false, "no strategy"
end

--- Turn the cheat off. Safe to call when never enabled, and safe twice.
function M.disable()
  if hook_handle ~= nil then
    -- TODO(discovery): unhook here once a hook exists.
    hook_handle = nil
  end

  baseline = nil
  logger.info("Ammo", "Disabled. Normal ammo consumption restored.")
end

--- Per-frame work. Returns immediately when unsupported.
function M.update()
  if not M.is_supported() then
    return
  end
  if not state.is_active() then
    return
  end

  -- TODO(discovery): dispatch on `strategy` here. Intentionally empty — see the
  -- module header. A placeholder write to an unverified field is exactly the
  -- invented behaviour this project forbids.
end

--- @return table|nil
function M.readout()
  if state.runtime.ammo_current == nil then
    return nil
  end
  return { current = state.runtime.ammo_current }
end

--- Called by discovery once a real strategy is established.
-- @param chosen string  "hook" | "capture_restore" | "hold_baseline"
-- @param reason string
function M.set_strategy(chosen, reason)
  strategy = chosen
  state.mark_supported("ammo", reason or ("strategy: " .. tostring(chosen)))
  logger.info("Ammo", "Strategy established: " .. tostring(chosen) .. " (" .. tostring(reason) .. ")")
end

--- Reset on scene change / script reset.
function M.reset()
  strategy = nil
  baseline = nil
  hook_handle = nil
end

return M
