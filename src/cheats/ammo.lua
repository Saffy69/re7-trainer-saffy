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
local objects = require("re7trainer.utils.object_helpers")
local game = require("re7trainer.game")

local M = {}

M.NAME = "ammo"
M.LABEL = "Infinite Ammo"

local enabled = false

--- Magazine count as of the previous frame.
local baseline = nil

--- Number of rounds restored, for the debug panel.
local restores = 0

--- Whether the game's own infinity flag is doing the work (preferred), rather
--- than the per-frame restore fallback.
local using_infinity_flag = false

--- Write attempts that did not change the value, and the last reason.
-- Kept separate from restores so the panel can tell a working cheat from one
-- calling a setter that silently does nothing.
local write_failures = 0
local last_write_error = nil

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

  if using_infinity_flag then
    return string.format("active (unlimited magazine, %d in the gun)", state.runtime.ammo_current)
  end

  if write_failures > 0 and restores == 0 then
    return "NOT WORKING -- " .. tostring(last_write_error or "writes have no effect")
  end

  return string.format("active (restoring, %d restored, %d failed)", restores, write_failures)
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

  -- Primary mechanism: the game's OWN unlimited-magazine flag.
  --
  -- app.WeaponGunParameter.IsLoadNumInfinity is a writable boolean that the
  -- game itself consults, exposed publicly via WeaponGun.get_isLoadNumInfinity().
  -- Setting it means the count is never decremented and never wrong -- not even
  -- for one frame -- and nothing is written per shot. This is the "prevent at
  -- source" strategy the project asked for, achieved with a first-class game
  -- feature rather than by intercepting code.
  local flag_ok, flag_detail = game.set_infinite_magazine(true)

  baseline = ammo.magazine
  enabled = true
  using_infinity_flag = flag_ok

  if flag_ok then
    state.runtime.ammo_reason = "unlimited magazine via " .. tostring(flag_detail)
    logger.info("Ammo", "Enabled using the game's own IsLoadNumInfinity flag (" ..
                        tostring(flag_detail) .. ").")
  else
    -- Fall back to restoring the value when it drops. Works, but can show the
    -- decremented number for up to a frame.
    state.runtime.ammo_reason = "restoring the magazine count (infinity flag unavailable: "
                                .. tostring(flag_detail) .. ")"
    logger.warn("Ammo", "Infinity flag unavailable (" .. tostring(flag_detail) ..
                        "); falling back to restoring the count each frame.")
  end

  return true, nil
end

function M.disable()
  enabled = false
  baseline = nil

  -- Clear the game's flag if we were the ones who set it. Leaving it on would
  -- make the cheat keep working after being switched off.
  if using_infinity_flag then
    local ok, detail = game.set_infinite_magazine(false)
    if not ok then
      logger.warn("Ammo", "Could not clear IsLoadNumInfinity: " .. tostring(detail))
    end
    using_infinity_flag = false
  end

  logger.info("Ammo", "Disabled. Normal ammo consumption restored.")
end

--- Per-frame work.
--
-- Does almost nothing when the infinity flag is carrying the cheat: there is no
-- value to watch, because the game never decrements it. The restore path only
-- runs when the flag was unavailable and this is working the hard way.
function M.update()
  if not M.is_supported() then
    return
  end

  local ammo = game.gun_ammo()
  if ammo == nil then
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

  if using_infinity_flag then
    -- Nothing to do. Confirm the flag is still set -- the game may clear it on
    -- a weapon swap -- and re-apply if so.
    local param = game.gun_parameter()
    if param ~= nil and objects.get(param, "IsLoadNumInfinity") ~= true then
      game.set_infinite_magazine(true)
    end
    return
  end

  if baseline == nil then
    baseline = ammo.magazine
    return
  end

  if ammo.magazine < baseline then
    local ok, detail = game.set_magazine(baseline)
    if ok then
      restores = restores + 1
      last_write_error = nil
      logger.throttled("ammo:restore", 300, "debug", "Ammo",
                       string.format("Restored magazine %d -> %d via %s",
                                     ammo.magazine, baseline, tostring(detail)))
    else
      write_failures = write_failures + 1
      last_write_error = tostring(detail)
      logger.throttled("ammo:writefail", 600, "warn", "Ammo",
                       "Could not restore the magazine: " .. tostring(detail))
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
  write_failures = 0
  last_write_error = nil
end

return M
