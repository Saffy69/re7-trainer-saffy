--[[--------------------------------------------------------------------------
  re7trainer.discovery.hook_probe — find out which methods the game ACTUALLY
  calls when you do something.

  THE QUESTION THIS ANSWERS
  -------------------------
  The cheats hook a specific method each and had no effect in game, while every
  read still worked. That leaves exactly two possibilities, and they look
  identical from outside:

      (a) the game does not call that method for that action  -> wrong target
      (b) the game calls it, and changes the value elsewhere  -> right method,
                                                                 wrong assumption

  Guessing costs a round trip per guess. This installs count-only hooks across
  a spread of plausible candidates at once, so one play session reports which
  of them fire during "take a hit", "fire the gun" and "use an herb".

  HOW TO READ THE RESULT
  ----------------------
  Open Developer -> Hooks and toggles after each action. A candidate whose call
  count stayed at zero for the action you performed is NOT on that code path.
  A candidate that climbed IS, and is the one worth building the cheat on.

  THE HOOKS DO NOTHING
  --------------------
  Every callback here returns CALL_ORIGINAL unconditionally. They only count.
  Nothing is suppressed, blocked, or modified — this is purely observational,
  which is also why it is safe to run before knowing what anything does.

  Note this build has no unhook, so these counters stay installed for the
  session. They are cheap and inert, but their counts keep accumulating, so
  compare counts across an action rather than treating them as absolute.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local safe = require("re7trainer.utils.safe_call")

local M = {}

--- Methods worth watching, grouped by the action that should trigger them.
---
--- Deliberately wide. The point is to bracket the truth rather than bet on one
--- candidate: if none of the damage-side entries fire when you are hit, the
--- real path is somewhere none of them reach, which is itself decisive.
M.WATCH = {
  damage = {
    { "app.PlayerDamageController", "doDamage" },
    { "app.PlayerDamageController", "calcDamage" },
    { "app.PlayerDamageController", "calcDamageValue" },
    { "app.PlayerDamageController", "doUpdate" },
    { "app.PlayerDamageController", "doLateUpdate" },
    { "app.DamageController", "doDamage" },
    { "app.Collision.DamageManager", "doDamage" },
    { "app.Collision.HitController", "doDamage" },
  },
  ammo = {
    { "app.WeaponGun", "expendBullet" },
    { "app.WeaponGun", "shoot" },
    { "app.WeaponGun", "shootStart" },
    { "app.WeaponGun", "shootEnd" },
    { "app.WeaponGun", "set_loadNum" },
    { "app.WeaponGun", "reload" },
    { "app.WeaponGun", "doUpdate" },
  },
  items = {
    { "app.Item", "reduceNum" },
    { "app.Item", "useItem" },
    { "app.Item", "setStackNum" },
    { "app.Item", "destroyItem" },
    { "app.Item", "doUpdate" },
    { "app.Inventory", "reduceItem" },
    { "app.Inventory", "interimItemUse" },
  },
}

--- Methods that are already watched, so a re-run does not stack duplicates.
local watching = {}

--- Install count-only hooks on every candidate that exists.
--
-- Nonexistent types and methods are skipped silently: this list is deliberately
-- broad and several entries are expected to miss.
-- @return number installed, number attempted
function M.install()
  local installed_count, attempted = 0, 0

  for group, entries in pairs(M.WATCH) do
    for _, entry in ipairs(entries) do
      local type_name, method_name = entry[1], entry[2]
      local key = type_name .. "." .. method_name
      attempted = attempted + 1

      if not watching[key] then
        -- A counter-only callback. It returns CALL_ORIGINAL unconditionally so
        -- the observed behaviour is exactly the unmodified game behaviour.
        local ok = safe.hook_method(
          key, type_name, method_name,
          function()
            safe.note_invocation(key, "counted")
            return sdk.PreHookResult.CALL_ORIGINAL
          end,
          nil
        )

        if ok then
          watching[key] = group
          installed_count = installed_count + 1
        end
      end
    end
  end

  logger.info("HookProbe", string.format(
    "Watching %d of %d candidate methods. Play normally, then read the panel.",
    installed_count, attempted))

  return installed_count, attempted
end

--- Snapshot current counts, keyed by method.
-- @return table key -> count
function M.snapshot()
  local counts = {}
  for _, entries in pairs(M.WATCH) do
    for _, entry in ipairs(entries) do
      local key = entry[1] .. "." .. entry[2]
      counts[key] = safe.invocation_count(key)
    end
  end
  return counts
end

--- Compare two snapshots and report which methods fired in between.
--
-- This is the part that actually produces an answer: rather than reading raw
-- counters, the user presses "mark" before an action and reads the delta after.
-- @param before table
-- @param after table
-- @return table array of { key, delta }
function M.diff(before, after)
  local fired = {}
  for key, count in pairs(after) do
    local previous = before[key] or 0
    if count > previous then
      fired[#fired + 1] = { key = key, delta = count - previous }
    end
  end
  table.sort(fired, function(a, b) return a.delta > b.delta end)
  return fired
end

--- How many methods are currently being watched.
-- @return number
function M.watching_count()
  local n = 0
  for _ in pairs(watching) do n = n + 1 end
  return n
end

return M
