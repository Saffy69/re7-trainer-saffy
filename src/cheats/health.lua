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
local safe = require("re7trainer.utils.safe_call")
local game = require("re7trainer.game")

local M = {}

M.NAME = "health"
M.LABEL = "Infinite Health / God Mode"

local enabled = false

--- Health as of the previous frame. Nil until the first successful read.
local baseline = nil

--- How many times damage has been undone, for the debug panel.
local restores = 0

--- Write attempts that did not actually change the value, and the last reason.
-- Tracked separately from restores so the panel can distinguish "working" from
-- "calling a setter that does nothing", which looked identical last time.
local write_failures = 0
local last_write_error = nil

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  baseline = nil
  restores = 0

  -- TYPE-LEVEL CHECK ONLY.
  --
  -- An earlier version also required a live player object here, and that was a
  -- bug with a nasty shape: initialize() runs at script load, which is the main
  -- menu, where no player exists. The subsystem was marked unsupported once and
  -- never reconsidered, so the toggle stayed dead for the entire session even
  -- though the player object appeared the moment a save was loaded.
  --
  -- Whether the player can be reached RIGHT NOW is a question for enable() and
  -- update(); whether the mechanism exists at all is a question for startup.
  if safe.type_definition("app.DamageController") == nil then
    state.mark_unsupported("health", "app.DamageController is not present in this build")
    logger.warn("Health", "Target type missing; Infinite Health will stay disabled.")
    return
  end

  if safe.type_definition("app.HealthInfo") == nil then
    state.mark_unsupported("health", "app.HealthInfo is not present in this build")
    logger.warn("Health", "Writable health record missing; Infinite Health will stay disabled.")
    return
  end

  state.mark_supported("health", "health is readable and writable (checked at enable time)")
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
  if state.runtime.health_current == nil then
    return "enabled, waiting for the player object"
  end

  if write_failures > 0 and restores == 0 then
    -- The mechanism is running but every write is being ignored. Saying
    -- "active" here would repeat the mistake this cheat already made once.
    return "NOT WORKING -- " .. tostring(last_write_error or "writes have no effect")
  end

  return string.format("active (%d restored, %d failed)", restores, write_failures)
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.health_reason or "not available"
    logger.warn("Health", "Refusing to enable: " .. reason)
    return false, reason
  end

  -- Live check, performed at the moment the user asks. This is where a missing
  -- player object legitimately blocks things -- and the message says so, rather
  -- than the toggle silently doing nothing.
  local health = game.health()
  if health == nil then
    local reason = "no player object yet -- load into gameplay and try again"
    state.runtime.health_reason = reason
    logger.warn("Health", "Cannot enable: " .. reason)
    return false, reason
  end

  if game.health_info() == nil then
    local reason = "the writable health record is not reachable right now"
    state.runtime.health_reason = reason
    logger.warn("Health", "Cannot enable: " .. reason)
    return false, reason
  end

  baseline = health.current
  enabled = true
  state.runtime.health_reason = "health is readable and writable"

  logger.info("Health", string.format("Enabled at %.1f. Health will be restored whenever it drops.",
                                      baseline))
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
    -- Player object not available (main menu, load, scene transition). Forget
    -- the baseline rather than carrying a value across a boundary where it is
    -- meaningless, and say so in the status line.
    baseline = nil
    state.runtime.health_current = nil
    if enabled then
      state.runtime.health_reason = "waiting for the player object (menu or loading?)"
    end
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

  -- The value to hold the player at: their maximum, not the level they happened
  -- to be on when the cheat was switched on.
  --
  -- The first version captured health at enable time and restored to THAT, so
  -- enabling the cheat after taking a hit froze the player at their wounded
  -- value for the rest of the session. That is not what "Infinite Health" means
  -- to anyone.
  local target = health.max
  if target == nil or target <= 0 then
    -- Maximum not readable; fall back to the level at enable time so the cheat
    -- still does something rather than silently refusing.
    target = baseline or health.current
  end

  if health.current < target - 0.01 then
    -- Damage was applied since the last frame. Put it back -- and only count it
    -- as a restore if the write actually took. An earlier version incremented
    -- this counter whenever the call did not error, which produced hundreds of
    -- "restored" reports while health kept dropping.
    local applier, detail = game.set_health(target)
    if applier then
      restores = restores + 1
      last_write_error = nil
      logger.throttled("health:restore", 300, "debug", "Health",
                       string.format("Restored health %.1f -> %.1f via %s",
                                     health.current, target, tostring(detail)))
    else
      write_failures = write_failures + 1
      last_write_error = tostring(detail)
      logger.throttled("health:writefail", 600, "warn", "Health",
                       "Could not restore health: " .. tostring(detail))
    end
  else
    -- At or above the target: a heal, a pickup, or a story event pushed it up.
    -- Track it so the baseline stays meaningful if max is ever unreadable.
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
  write_failures = 0
  last_write_error = nil
end

return M
