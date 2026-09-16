--[[--------------------------------------------------------------------------
  re7trainer.cheats.health — Infinite Health / God Mode.

  THE API THIS USES IS REAL AND WAS READ OUT OF THE RUNNING GAME
  --------------------------------------------------------------
  From a live discovery dump (docs/DISCOVERY_RESULTS.md):

      app.PlayerDamageController
        M System.Void doDamage(? (1 params))

  `doDamage` takes exactly one parameter, which means a hook that suppresses it
  needs no parameter handling at all — returning SKIP_ORIGINAL is sufficient.

  STRATEGY (the project's preferred one, in its stated order)
  -----------------------------------------------------------
  Prevent damage at the source rather than rewriting a value afterwards:

      sdk.hook(doDamage, pre = SKIP_ORIGINAL when enabled, post = nil)

  Nothing else in the game is affected. Enemies still take damage, healing still
  works, the damage-animation path is simply never entered. Because the health
  value is never written by us, there is no window in which a wrong value is
  visible, and there is no risk of clobbering a legitimate healing event.

  THE HOOK IS PERMANENT. THE FLAG IS NOT.
  ---------------------------------------
  This build has no unhook and no remove_hook (both confirmed absent from the
  installed binary). Once installed the hook stays for the life of the process.
  So disabling this cheat does NOT remove the hook — it flips `enabled`, which
  the callback reads before deciding whether to skip. The callback therefore
  has to be correct while disabled, which is why it checks the flag first and
  returns immediately.

  A SECOND, SOFTER OPTION EXISTS
  ------------------------------
  app.CharacterCommonStatus (inherited by app.PlayerStatus) exposes a writable
  `set_isForbidDamageReaction(System.Boolean)`. It is not used by default
  because it is NOT PROVEN to prevent health loss — the name suggests it may
  govern only the reaction animation while the health value still drops. It is
  exposed here as an explicit experiment rather than being silently relied on.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local game = require("re7trainer.game")

local M = {}

M.NAME = "health"
M.LABEL = "Infinite Health / God Mode"

--- Read by the hook on every call. This, not the hook's existence, is what
--- enable/disable actually controls.
local enabled = false

--- Whether the hook has been installed at least once.
local hook_ready = false

--- Optional secondary flag, off unless the user asks for the experiment.
local use_damage_reaction_flag = false

local HOOK_KEY = "app.PlayerDamageController.doDamage"

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  use_damage_reaction_flag = false

  -- Confirm the target exists, but do not hook yet. Hooking is deferred to the
  -- first enable() so that a player who never turns the cheat on never pays
  -- any hook cost at all.
  if safe.type_definition("app.PlayerDamageController") == nil then
    state.mark_unsupported("health",
      "app.PlayerDamageController is not present in this build")
    logger.warn("Health", "Target type missing; Infinite Health will stay disabled.")
    return
  end

  state.mark_supported("health", "app.PlayerDamageController.doDamage discovered")
  logger.info("Health", "Ready. Hook target: app.PlayerDamageController.doDamage")
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
  return hook_ready and "active (damage suppressed at source)" or "enabling..."
end

--- Install the hook if it is not already installed.
-- Safe to call repeatedly: safe_call.hook_method installs at most once per key.
-- @return boolean ok, string|nil detail
local function ensure_hook()
  if hook_ready then
    return true, nil
  end

  local ok, detail = safe.hook_method(
    HOOK_KEY,
    "app.PlayerDamageController",
    "doDamage",
    function(args)
      -- Runs on the game thread while holding the Lua lock. Keep it minimal.
      if not enabled then
        return sdk.PreHookResult.CALL_ORIGINAL
      end
      if state.prefs.trainer_enabled ~= true then
        return sdk.PreHookResult.CALL_ORIGINAL
      end
      return sdk.PreHookResult.SKIP_ORIGINAL
    end,
    nil
  )

  if ok then
    hook_ready = true
  end
  return ok, detail
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.health_reason or "not available"
    logger.warn("Health", "Refusing to enable: " .. reason)
    return false, reason
  end

  local ok, detail = ensure_hook()
  if not ok then
    logger.error("Health", "Could not hook doDamage: " .. tostring(detail))
    return false, tostring(detail)
  end

  enabled = true

  if use_damage_reaction_flag then
    M.set_damage_reaction_forbidden(true)
  end

  logger.info("Health", "Enabled. Damage to the player is suppressed at the source.")
  return true, nil
end

--- Stop suppressing damage.
--
-- Note this does NOT remove the hook — it cannot, this build has no unhook.
-- It clears the flag the hook reads.
function M.disable()
  enabled = false

  if use_damage_reaction_flag then
    M.set_damage_reaction_forbidden(false)
  end

  logger.info("Health", "Disabled. Normal damage behaviour restored.")
end

--- Per-frame work.
--
-- Deliberately almost empty: damage suppression happens in the hook, at the
-- moment of the call, rather than by polling. The only work here is keeping the
-- UI readout current.
function M.update()
  if not M.is_supported() then
    return
  end

  -- Refresh the displayed value at a low rate. Reading health is cheap, but
  -- doing it 60 times a second for a number the user cannot read that fast is
  -- pointless work on the game thread.
  if logger.frame() % 30 ~= 0 then
    return
  end

  local health = game.health()
  if health ~= nil then
    state.runtime.health_current = health.current
    state.runtime.health_max = health.max
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

-- ---------------------------------------------------------------------------
-- Optional experiment: the damage-reaction flag
-- ---------------------------------------------------------------------------

--- Toggle app.CharacterCommonStatus.set_isForbidDamageReaction.
--
-- Exposed deliberately as an experiment rather than as the default. The method
-- name says "forbid damage REACTION", which may mean it suppresses the stagger
-- animation while the health value still drops. That has to be established by
-- observation, not by reading the name.
--
-- Call this, take a hit, and compare get_health() before and after. If health
-- holds, this is a strictly better mechanism than the hook, because it changes
-- no code path at all.
--
-- @param forbidden boolean
-- @return boolean ok
function M.set_damage_reaction_forbidden(forbidden)
  local status = game.player_status()
  if status == nil then
    logger.warn("Health", "Cannot set damage-reaction flag: player status unavailable.")
    return false
  end

  local ok, result = safe.call_method(status, "set_isForbidDamageReaction", forbidden == true)
  if not ok or result == nil then
    logger.warn("Health", "set_isForbidDamageReaction call did not report success.")
    return false
  end

  logger.info("Health", "isForbidDamageReaction set to " .. tostring(forbidden) .. ".")
  return true
end

--- Enable the experiment mode. Used by the developer UI.
-- @param on boolean
function M.use_reaction_flag(on)
  use_damage_reaction_flag = on == true
  if enabled then
    M.set_damage_reaction_forbidden(use_damage_reaction_flag)
  end
end

function M.reset()
  enabled = false
  use_damage_reaction_flag = false
  -- hook_ready is intentionally NOT cleared: the hook cannot be uninstalled,
  -- so forgetting that it exists would let a later enable() try to install a
  -- second one on the same method.
end

return M
