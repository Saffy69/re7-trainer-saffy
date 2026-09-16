--[[--------------------------------------------------------------------------
  re7trainer.cheats.ammo — Infinite Ammo.

  WHY THIS DOES NOT USE A HOOK
  ----------------------------
  The first implementation hooked app.WeaponGun.expendBullet. A counting probe
  run in game showed expendBullet NEVER fires -- not once while emptying a
  magazine and reloading. The methods that did fire were:

      app.WeaponGun.set_loadNum   x6
      app.WeaponGun.shoot         x2

  So the magazine is changed by set_loadNum, and that is the value to control.
  Rather than hook it, this tracks the count and rewrites it when it drops --
  the same read-and-restore approach as the health cheat, and for the same
  reason: both halves are confirmed working, whereas the hook target was wrong
  twice.

  THE REQUIREMENT THIS SATISFIES
  ------------------------------
  Firing must leave the count unchanged: twelve stays twelve, not 999999.
  Restoring the previous value does exactly that. Nothing is ever set to a
  large constant.

  WHERE THIS CANNOT HELP
  ----------------------
  An empty magazine cannot be refilled by this cheat, and that is deliberate.
  If the count is already 0 when enabled, there is nothing to restore, so the
  gun stays empty and the player must reload normally. Reloading is itself a
  legitimate increase, so it is accepted and becomes the new baseline. This
  cheat prevents rounds being lost; it does not manufacture them.

  The reserve count is not touched at all. Only the magazine is tracked, which
  keeps the HUD consistent -- the reserve number the player sees stays honest.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local game = require("re7trainer.game")

local M = {}

M.NAME = "ammo"
M.LABEL = "Infinite Ammo"

local enabled = false

--- Magazine count as of the previous frame.
local baseline = nil

--- Number of rounds restored, for the debug panel.
local restores = 0

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  baseline = nil
  restores = 0

  -- TYPE-LEVEL CHECK ONLY. See the note in cheats/health.lua: initialize() runs
  -- at script load, which is the main menu, where there is no equipped weapon.
  -- Requiring one here marked the subsystem unsupported for the whole session.
  if safe.type_definition("app.WeaponGun") == nil then
    state.mark_unsupported("ammo", "app.WeaponGun is not present in this build")
    logger.warn("Ammo", "Target type missing; Infinite Ammo will stay disabled.")
    return
  end

  state.mark_supported("ammo", "magazine is readable and writable (checked at enable time)")
  logger.info("Ammo", "Ready. Restoring the magazine count when it decreases.")
end

--- @return boolean
function M.is_supported()
  return state.runtime.ammo_supported == true
end

--- @return string
function M.status()
  if not M.is_supported() then
    return state.runtime.ammo_reason or "not available"
  end
  if not enabled then
    return "ready (off)"
  end
  if state.runtime.ammo_current == nil then
    return "enabled, waiting for a weapon"
  end
  return "active (" .. tostring(restores) .. " restored)"
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.ammo_reason or "not available"
    logger.warn("Ammo", "Refusing to enable: " .. reason)
    return false, reason
  end

  -- Live check at the moment of asking.
  local ammo = game.gun_ammo()
  if ammo == nil then
    local reason = "no weapon equipped or readable -- draw a weapon and try again"
    state.runtime.ammo_reason = reason
    logger.warn("Ammo", "Cannot enable: " .. reason)
    return false, reason
  end

  baseline = ammo.magazine
  enabled = true
  state.runtime.ammo_reason = "magazine is readable and writable"

  if baseline == 0 then
    logger.warn("Ammo", "Enabled while the magazine is empty, so there is nothing to preserve. "
                     .. "Reload once and the cheat will hold the count from then on.")
  else
    logger.info("Ammo", string.format("Enabled at %d round(s). Firing will not consume them.", baseline))
  end

  return true, nil
end

function M.disable()
  enabled = false
  baseline = nil
  logger.info("Ammo", "Disabled. Normal ammo consumption restored.")
end

--- Per-frame work.
function M.update()
  if not M.is_supported() then
    return
  end

  local ammo = game.gun_ammo()
  if ammo == nil then
    -- Weapon swapped, holstered, or a scene change. Drop the baseline rather
    -- than carrying a count from a different gun onto this one.
    baseline = nil
    state.runtime.ammo_current = nil
    if enabled then
      state.runtime.ammo_reason = "waiting for a weapon (none equipped, or a menu is open)"
    end
    return
  end

  state.runtime.ammo_current = ammo.magazine

  if not enabled or state.prefs.trainer_enabled ~= true then
    baseline = ammo.magazine
    return
  end

  if baseline == nil then
    baseline = ammo.magazine
    return
  end

  if ammo.magazine < baseline then
    if game.set_magazine(baseline) then
      restores = restores + 1
      logger.throttled("ammo:restore", 300, "debug", "Ammo",
                       string.format("Restored magazine %d -> %d", ammo.magazine, baseline))
    end
  else
    -- A reload or a pickup. Accept it as the new baseline, otherwise the cheat
    -- would immediately undo the player's own reload.
    baseline = ammo.magazine
  end
end

--- @return table|nil
function M.readout()
  if state.runtime.ammo_current == nil then
    return nil
  end
  return { current = state.runtime.ammo_current }
end

function M.reset()
  enabled = false
  baseline = nil
  restores = 0
end

return M
