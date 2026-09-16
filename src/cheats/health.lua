--[[--------------------------------------------------------------------------
  re7trainer.cheats.health — Infinite Health / God Mode.

  WHY THIS DOES NOT USE A HOOK
  ----------------------------
  The first implementation hooked app.PlayerDamageController.doDamage and
  skipped it. In game, the method was confirmed to fire (a counting probe
  recorded it once per hit) and skipping it did NOT prevent health loss.

  The reason, from the discovery dump: app.PlayerDamageController derives from
  app.DamageController, and it is the BASE class that carries the health record:

      app.DamageController
        F app.HealthInfo HealthInfo
        M app.HealthInfo getHealthInfo()
        M System.Void    adjustHealth(?)
        M System.Void    recoveryHealth(?) / recoveryHealthAll(?)

  doDamage on the subclass is reaction and animation work, not the health
  write. Healing has its own separate methods, so adjustHealth is the damage
  path -- but its argument is a float we cannot reliably read from a hook
  argument table, and getting that wrong would silently block healing instead.

  So this uses the approach that is verifiable end to end: read the value, and
  put it back. Both halves are confirmed working in game -- health read as
  960/1000 live, and app.HealthInfo exposes a writable `Health` float plus
  set_health(float).

  HOW THE RESTORE WORKS
  ---------------------
  Track the last observed value each frame. If it DROPS, write the old value
  back. If it RISES, accept the new value.

  The rise case matters: healing, pickups and story events all legitimately
  increase health, and a naive "set it to maximum every frame" would fight them
  and could leave the player permanently pinned at a value the game does not
  expect. Only decreases are undone.

  TRADE-OFF, STATED PLAINLY
  -------------------------
  This is the second of the three strategies the project specified, not the
  first. Because the game applies the damage and we undo it on the next frame,
  there is a window of up to one frame in which the HUD can show the reduced
  value. The preferred "prevent it at the source" approach is not reachable
  here: the only interception point the probe could confirm is not the health
  write, and the actual write takes a float argument we cannot read reliably.
  A one-frame HUD flicker is a much better outcome than a cheat that silently
  does nothing, or a hook that corrupts memory.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local game = require("re7trainer.game")

local M = {}

M.NAME = "health"
M.LABEL = "Infinite Health / God Mode"

local enabled = false

--- Health as of the previous frame. Nil until the first successful read.
local baseline = nil

--- How many times damage has been undone, for the debug panel.
local restores = 0

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  baseline = nil
  restores = 0

  -- Confirm both halves of the mechanism exist before claiming support. A
  -- cheat that can read but not write is not a cheat, and it should say so
  -- rather than appear available.
  if game.health() == nil then
    state.mark_unsupported("health", "player health is not readable")
    logger.warn("Health", "Cannot read health; Infinite Health will stay disabled.")
    return
  end

  if game.health_info() == nil then
    state.mark_unsupported("health", "app.HealthInfo is not reachable, so health cannot be written")
    logger.warn("Health", "Cannot reach the writable health record; Infinite Health will stay disabled.")
    return
  end

  state.mark_supported("health", "health is both readable and writable")
  logger.info("Health", "Ready. Restoring health when it decreases.")
end

--- @return boolean
function M.is_supported()
  return state.runtime.health_supported == true
end

--- @return string
function M.status()
  if not M.is_supported() then
    return state.runtime.health_reason or "not available"
  end
  if not enabled then
    return "ready (off)"
  end
  return "active (" .. tostring(restores) .. " restored)"
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.health_reason or "not available"
    logger.warn("Health", "Refusing to enable: " .. reason)
    return false, reason
  end

  -- Seed the baseline from the current value so the first frame after enabling
  -- does not mistake a stale baseline for damage.
  local health = game.health()
  baseline = health and health.current or nil
  enabled = true

  logger.info("Health", "Enabled. Health will be restored whenever it drops.")
  return true, nil
end

function M.disable()
  enabled = false
  baseline = nil
  logger.info("Health", "Disabled. Normal damage behaviour restored.")
end

--- Per-frame work.
--
-- Runs on the game thread via re.on_frame, which is why writing here is safe.
function M.update()
  if not M.is_supported() then
    return
  end

  local health = game.health()
  if health == nil then
    -- Player object not available (menu, load, transition). Forget the
    -- baseline rather than carrying a value across a boundary where it is
    -- meaningless.
    baseline = nil
    return
  end

  state.runtime.health_current = health.current
  state.runtime.health_max = health.max

  if not enabled or state.prefs.trainer_enabled ~= true then
    baseline = health.current
    return
  end

  if baseline == nil then
    baseline = health.current
    return
  end

  if health.current < baseline then
    -- Damage was applied since the last frame. Put it back.
    if game.set_health(baseline) then
      restores = restores + 1
      logger.throttled("health:restore", 300, "debug", "Health",
                       string.format("Restored health %.1f -> %.1f", health.current, baseline))
    else
      logger.throttled("health:writefail", 600, "warn", "Health",
                       "Detected damage but could not write health back.")
    end
  else
    -- Same or higher: accept it, so healing and pickups are not undone.
    baseline = health.current
  end
end

--- @return table|nil
function M.readout()
  if state.runtime.health_current == nil then
    return nil
  end
  return {
    current = state.runtime.health_current,
    max = state.runtime.health_max,
  }
end

function M.reset()
  enabled = false
  baseline = nil
  restores = 0
end

return M
