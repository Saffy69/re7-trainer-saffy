--[[--------------------------------------------------------------------------
  re7trainer.cheats.health — Infinite Health / God Mode.

  READ THIS BEFORE ASSUMING IT DOES ANYTHING
  ------------------------------------------
  This module is structurally complete and functionally EMPTY. That is the
  correct state for it.

  We know RE7's health-related TYPE names (app.PlayerStatus,
  app.PlayerDamageController, app.PlayerMaxHealthTable, ...) because they were
  extracted from the user's own REFramework log. We do NOT know a single method
  or field on any of them. The type dump contains type names only.

  Which means any implementation written today would be invented. It would
  compile, it would run, and it would either do nothing or — worse — write to
  an offset that happens to be valid and corrupt the save.

  So enable() refuses, and is_supported() returns false until the discovery
  subsystem has produced real member data. The UI renders that as a disabled
  toggle with a reason, which is honest. A toggle that silently does nothing is
  not.

  THE STRATEGY THIS MODULE IS BUILT TO IMPLEMENT, once discovery lands
  -------------------------------------------------------------------
  In preference order, from least invasive to most:

    1. HOOK THE DAMAGE PATH. If app.PlayerDamageController exposes a method that
       applies incoming damage to the player, hooking it and skipping the
       original call prevents damage at its source. Nothing else in the game is
       affected: enemies still take damage normally, healing still works, the
       damage UI simply never fires. This is the preferred approach.

    2. PRESERVE THE VALUE. If no suitable hook point exists but a plain health
       field is readable and writable, capture it while at full health and
       restore it whenever it drops. Slightly noisier — the damage UI and audio
       still play — but it never touches code, only data.

    3. RESTORE AFTER THE FACT. If the field is readable but not writable, watch
       it and restore on the next frame. Highest latency, highest chance of a
       visible flicker, last resort.

  Which of these is available is decided entirely by what the discovery dump
  reports. All three are wired into update() as separate, clearly-marked paths
  so that implementing the real one is a matter of filling in a known shape.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")

local M = {}

M.NAME = "health"
M.LABEL = "Infinite Health / God Mode"

--- Which approach is in use: nil until discovery chooses one.
-- One of "hook" | "preserve" | "restore", or nil.
local strategy = nil

--- Cached, validated value captured when the cheat was enabled.
-- For the "preserve" strategy this is the health level we hold the player at.
local baseline = nil

--- Handle to whatever we hooked, so disable() can undo it cleanly.
local hook_handle = nil

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called once at startup. Never touches the game.
function M.initialize()
  strategy = nil
  baseline = nil
  hook_handle = nil
  logger.info("Health", "Module initialised. Awaiting discovery — no health API is known yet.")
end

--- Can this cheat actually do anything right now?
--
-- Returns false until the discovery subsystem has identified a real, verified
-- intervention point AND marked the health subsystem supported.
-- @return boolean
function M.is_supported()
  return state.runtime.health_supported == true and strategy ~= nil
end

--- Human-readable reason the cheat is in its current state.
-- @return string
function M.status()
  if M.is_supported() then
    return "active via '" .. tostring(strategy) .. "' strategy"
  end
  return state.runtime.health_reason or "not yet discovered"
end

--- Turn the cheat on.
--
-- Returns false and explains itself when the game API has not been discovered.
-- It never enables a half-implemented path.
-- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.health_reason or "not yet discovered"
    logger.warn("Health", "Refusing to enable Infinite Health: " .. reason)
    return false, reason
  end

  -- Reached only once discovery has set a strategy. Each branch is a distinct,
  -- reviewable implementation — deliberately not collapsed into one clever
  -- function, because they have different failure modes.
  if strategy == "hook" then
    -- TODO(discovery): replace with a sdk.hook on the verified damage method.
    -- The pre-callback must return sdk.PreHookResult.SKIP_ORIGINAL to prevent
    -- the damage from being applied; the exact enum name must be read off the
    -- discovery dump before this is written.
    logger.warn("Health", "Hook strategy selected but no verified method to hook. This is a bug.")
    return false, "hook strategy has no verified target"

  elseif strategy == "preserve" then
    -- TODO(discovery): capture the current value of the verified health field.
    logger.warn("Health", "Preserve strategy selected but no verified field to read.")
    return false, "preserve strategy has no verified field"

  elseif strategy == "restore" then
    -- TODO(discovery): same requirement as "preserve", plus a per-frame write.
    logger.warn("Health", "Restore strategy selected but no verified field to read.")
    return false, "restore strategy has no verified field"
  end

  logger.warn("Health", "No usable strategy. This should be unreachable.")
  return false, "no strategy"
end

--- Turn the cheat off and restore normal game behaviour.
--
-- Must be safe to call when the cheat was never enabled, and safe to call twice.
function M.disable()
  if hook_handle ~= nil then
    -- TODO(discovery): unhook here once a hook exists. Until then this branch
    -- is unreachable, but leaving it in place documents the contract.
    hook_handle = nil
  end

  baseline = nil
  logger.info("Health", "Disabled. Normal damage behaviour restored.")
end

--- Per-frame work.
--
-- Called every frame by main.lua while the cheat is enabled. Returns
-- immediately when unsupported, so an undiscovered build pays no cost.
function M.update()
  if not M.is_supported() then
    return
  end
  if not state.is_active() then
    return
  end

  -- TODO(discovery): dispatch on `strategy` here. Intentionally empty: there is
  -- nothing to do until a real field or method is known, and a placeholder write
  -- would be exactly the invented behaviour this project forbids.
end

--- Values for the status panel, or nil when unknown.
-- @return table|nil
function M.readout()
  if state.runtime.health_current == nil then
    return nil
  end
  return {
    current = state.runtime.health_current,
    max = state.runtime.health_max,
  }
end

--- Called by the discovery subsystem when it has established a real strategy.
-- This is the only legitimate way for the cheat to become functional.
-- @param chosen string  "hook" | "preserve" | "restore"
-- @param reason string  human-readable justification
function M.set_strategy(chosen, reason)
  strategy = chosen
  state.mark_supported("health", reason or ("strategy: " .. tostring(chosen)))
  logger.info("Health", "Strategy established: " .. tostring(chosen) .. " (" .. tostring(reason) .. ")")
end

--- Reset on scene change / script reset. Drops anything session-specific.
function M.reset()
  strategy = nil
  baseline = nil
  hook_handle = nil
end

return M
