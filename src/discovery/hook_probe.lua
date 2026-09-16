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
--- DELIBERATELY SMALL AND DELIBERATELY COLD.
---
--- An earlier version of this list included doUpdate and doLateUpdate. That was
--- a mistake: those run every frame, on EVERY instance of the type. Hooking
--- app.Item.doUpdate means every item in the world calls into Lua every frame,
--- and the Lua lock is held for each call. Installing a batch of those crashed
--- the game.
---
--- The rule now: only watch methods that run once per player ACTION -- one call
--- per shot, one call per hit, one call per item consumed. Those are the ones
--- whose call count is meaningful anyway; a per-frame method tells you nothing
--- about which action happened.
---
--- safe_call.hook_method additionally refuses any method with no resolved
--- implementation, so a stub target cannot be reached from here either.
M.WATCH = {
  damage = {
    { "app.PlayerDamageController", "doDamage" },
    { "app.PlayerDamageController", "calcDamage" },
    { "app.PlayerDamageController", "calcDamageValue" },
    { "app.DamageController", "doDamage" },
    { "app.Collision.DamageManager", "doDamage" },
  },
  ammo = {
    { "app.WeaponGun", "expendBullet" },
    { "app.WeaponGun", "shoot" },
    { "app.WeaponGun", "set_loadNum" },
    { "app.WeaponGun", "reload" },
  },
  items = {
    { "app.Item", "reduceNum" },
    { "app.Item", "useItem" },
    { "app.Item", "destroyItem" },
    { "app.Inventory", "reduceItem" },
    { "app.Inventory", "interimItemUse" },
  },
}

--- Methods that are already watched, so a re-run does not stack duplicates.
local watching = {}

--- Install count-only hooks for one group of candidates.
--
-- Group-scoped on purpose. An earlier version installed everything in one
-- press; when that crashed the game, there was no way to tell which of twenty
-- candidates was responsible. One group per press means a crash narrows to
-- four or five names instead of twenty.
--
-- @param group string  "damage" | "ammo" | "items"
-- @return number installed, number attempted, table array of failure reasons
function M.install(group)
  local entries = M.WATCH[group]
  if entries == nil then
    return 0, 0, { "unknown group: " .. tostring(group) }
  end

  local installed_count, attempted = 0, 0
  local failures = {}

  for _, entry in ipairs(entries) do
    local type_name, method_name = entry[1], entry[2]
    local key = type_name .. "." .. method_name
    attempted = attempted + 1

    if watching[key] then
      installed_count = installed_count + 1
    else
      -- A counter-only callback. It returns CALL_ORIGINAL unconditionally so
      -- the observed behaviour is exactly the unmodified game behaviour.
      --
      -- safe_call.hook_method refuses targets with no resolved implementation,
      -- which is the guard that matters here: hooking a stub patches stub
      -- memory, and that is a plausible cause of the earlier crash.
      local ok, detail = safe.hook_method(
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
      else
        failures[#failures + 1] = key .. ": " .. tostring(detail)
      end
    end
  end

  logger.info("HookProbe", string.format(
    "Group '%s': watching %d of %d candidates.", group, installed_count, attempted))

  return installed_count, attempted, failures
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
