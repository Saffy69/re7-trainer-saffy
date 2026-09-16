--[[--------------------------------------------------------------------------
  re7trainer.cheats.ammo — Infinite Ammo.

  THE API THIS USES IS REAL AND WAS READ OUT OF THE RUNNING GAME
  --------------------------------------------------------------
  From a live discovery dump (docs/DISCOVERY_RESULTS.md):

      app.WeaponGun
        M System.Boolean expendBullet()          <-- 0 params. The consumption op.
        M System.Int32   get_loadNum()           <-- magazine
        M System.Void    set_loadNum(System.Int32)
        M System.Int32   get_bulletStackNum()    <-- reserve
        M System.Boolean get_isLoadNumInfinity()
        M System.Boolean get_isBulletStackNumInfinity()

  STRATEGY: prevent consumption, do not rewrite a value.
  -----------------------------------------------------
      sdk.hook(expendBullet, pre = SKIP_ORIGINAL when enabled, post = nil)

  This is the project's stated requirement implemented literally: firing leaves
  the count unchanged, because the operation that would have changed it never
  runs. Twelve rounds stays twelve — not 999999.

  Setting a large constant was rejected on purpose. It would look wrong in the
  HUD, it desynchronises from the reserve count, and it is a strictly larger
  intervention than simply not decrementing.

  `expendBullet` returns System.Boolean. When the original body is skipped the
  return slot is left at its default, i.e. false — which reads as "no bullet was
  expended". That happens to be the semantically correct answer, but it is worth
  noting because it is not something the hook arranges deliberately.

  THE HOOK IS PERMANENT. THE FLAG IS NOT.
  ---------------------------------------
  No unhook exists in this build. The hook is installed once and gated on a
  flag; disable() clears the flag rather than removing anything.

  WHAT IS NOT TOUCHED
  -------------------
  Reload behaviour is left entirely alone — "No Reload" was not requested and
  suppressing it would change weapon handling beyond what was asked for. The
  reserve count is not modified either; only the consumption of a round from the
  magazine is prevented.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local game = require("re7trainer.game")

local M = {}

M.NAME = "ammo"
M.LABEL = "Infinite Ammo"

--- Read by the hook on every call.
local enabled = false

local hook_ready = false

local HOOK_KEY = "app.WeaponGun.expendBullet"

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false

  if safe.type_definition("app.WeaponGun") == nil then
    state.mark_unsupported("ammo", "app.WeaponGun is not present in this build")
    logger.warn("Ammo", "Target type missing; Infinite Ammo will stay disabled.")
    return
  end

  state.mark_supported("ammo", "app.WeaponGun.expendBullet discovered")
  logger.info("Ammo", "Ready. Hook target: app.WeaponGun.expendBullet")
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
  return hook_ready and "active (rounds not consumed)" or "enabling..."
end

local function ensure_hook()
  if hook_ready then
    return true, nil
  end

  local ok, detail = safe.hook_method(
    HOOK_KEY,
    "app.WeaponGun",
    "expendBullet",
    function()
      -- Runs on the game thread holding the Lua lock; keep it minimal.
      -- The counter distinguishes "expendBullet is not on the firing path"
      -- from "the hook is deciding wrong" -- see safe_call.hook_report.
      if not enabled or state.prefs.trainer_enabled ~= true then
        safe.note_invocation(HOOK_KEY, "pass (disabled)")
        return sdk.PreHookResult.CALL_ORIGINAL
      end
      safe.note_invocation(HOOK_KEY, "SKIP")
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
    local reason = state.runtime.ammo_reason or "not available"
    logger.warn("Ammo", "Refusing to enable: " .. reason)
    return false, reason
  end

  local ok, detail = ensure_hook()
  if not ok then
    logger.error("Ammo", "Could not hook expendBullet: " .. tostring(detail))
    return false, tostring(detail)
  end

  enabled = true
  logger.info("Ammo", "Enabled. Firing will not consume rounds.")
  return true, nil
end

--- Stop suppressing consumption. Does not remove the hook.
function M.disable()
  enabled = false
  logger.info("Ammo", "Disabled. Normal ammo consumption restored.")
end

--- Per-frame work: refresh the readout only.
function M.update()
  if not M.is_supported() then
    return
  end
  if logger.frame() % 30 ~= 0 then
    return
  end

  local ammo = game.gun_ammo()
  if ammo ~= nil then
    state.runtime.ammo_current = ammo.magazine
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
  -- hook_ready not cleared: the hook is permanent, so re-installing on a later
  -- enable() would stack a second hook on the same method.
end

return M
