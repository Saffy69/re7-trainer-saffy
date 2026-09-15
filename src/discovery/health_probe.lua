--[[--------------------------------------------------------------------------
  re7trainer.discovery.health_probe — locate the health and damage path.

  WHAT WE KNOW (verified, from the user's own type dump)
  -----------------------------------------------------
    app.PlayerStatus                exists, unprefixed  -> main-game candidate
    app.PlayerMaxHealthTable        exists
    app.PlayerResurrection          exists
    app.PlayerDamageController      exists, unprefixed
    app.PlayerDamageController.DamageGUIController  exists
    app.DamageController            exists (shared damage pipeline)
    app.Collision.DamageManager     exists AND is a managed singleton
    app.Collision.CalculateDamage   exists
    app.CharacterDefine.Vitality    exists

  WHAT WE DO NOT KNOW
  -------------------
  Nothing about their members. Not one field name, not one method name, not
  one signature. The type dump that produced the list above contains type names
  only — members live in the running process and nowhere else.

  So this probe has exactly one job: get the members out of the running game.
  It does NOT attempt to read a health value, because we do not know what to
  read. Any number it printed would be a guess dressed up as a measurement,
  which is the specific failure this project exists to avoid.

  WHAT IT RETURNS
  ---------------
  For each candidate type: whether it exists, its inheritance chain, its full
  method list with signatures, and its full field list with types. Plus which
  candidate singletons actually construct.

  The method list is the prize. Once we can see the real methods on
  app.PlayerDamageController, choosing between "hook the damage function" and
  "preserve the health value" stops being speculation.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local types = require("re7trainer.utils.type_helpers")
local safe = require("re7trainer.utils.safe_call")

local M = {}

M.NAME = "health"

--- Types this probe interrogates, in priority order.
--
-- Ordered by how directly each is expected to lead to a usable health control,
-- so that if a future reader only reads the first few entries they still get
-- the useful ones.
M.TARGETS = {
  -- 1. The FSM node that writes the health value. RE Engine implements
  --    gameplay actions as FSM nodes, so a node named "HealthSet" is a
  --    plausible single choke point — and a single choke point is much easier
  --    to work with than a raw field that many code paths touch.
  "app.fsm.HealthSet",

  -- 2. The health record itself.
  "app.HealthInfo",
  "app.CharacterCommonStatus",

  -- 3. The player's own damage controller. If it exposes a method that applies
  --    or absorbs damage, that is the preferred hook point — it is the narrowest
  --    interception that leaves everything else untouched.
  "app.PlayerDamageController",

  -- 4. The player's health/status container. If a plain readable health value
  --    lives here, the "preserve and restore" approach becomes available as a
  --    fallback when hooking is not viable.
  "app.PlayerStatus",
  "app.PlayerBase",

  -- 5. The shared damage pipeline. Broader than (3) — hooking here would affect
  --    enemies too — so it is a fallback, not a first choice.
  "app.DamageController",
  "app.Collision.DamageManager",
  "app.Collision.CalculateDamage",
  "app.Collision.HitController",

  -- 6. Supporting types that bound or describe health.
  "app.PlayerMaxHealthTable",
  "app.PlayerResurrection",
  "app.ItemHealthRecover",
  "app.CharacterDefine",
}

--- Scenarios that mirror the main-game types. Dumped so we can compare them
--- against the unprefixed versions and see which one the running scenario is
--- actually using.
M.SCENARIO_TARGETS = {
  "app.CH8PlayerStatus",
  "app.CH8PlayerDamageController",
  "app.CH9PlayerStatus",
  "app.CH9PlayerDamageController",
}

--- Run the probe.
-- @return table structured result, safe to serialise
function M.run()
  local report = {
    probe = M.NAME,
    targets = {},
    scenario_targets = {},
    notes = {},
  }

  for _, name in ipairs(M.TARGETS) do
    report.targets[#report.targets + 1] = types.dump_type(name)
  end

  for _, name in ipairs(M.SCENARIO_TARGETS) do
    report.scenario_targets[#report.scenario_targets + 1] = types.dump_type(name)
  end

  -- Which candidate singletons are actually alive right now? A singleton that
  -- exists but is not constructed means "we are not far enough into the game
  -- yet", which is different from "this build does not have it".
  report.singletons = {}
  for _, name in ipairs({ "app.Collision.DamageManager", "app.GameManager", "app.CharacterExistManager" }) do
    local instance = safe.singleton(name)
    report.singletons[#report.singletons + 1] = {
      name = name,
      type_exists = types.exists(name),
      constructed = instance ~= nil,
    }
  end

  -- Be explicit in the output about what this probe did and did not establish,
  -- so the result cannot be misread as "health was found".
  report.notes[#report.notes + 1] =
    "This probe reports type MEMBERS only. It does not identify which method "
    .. "applies damage or which field stores health; that requires reading the "
    .. "method list below."

  local found = 0
  for _, entry in ipairs(report.targets) do
    if entry.found then
      found = found + 1
    end
  end

  logger.info("Health", string.format(
    "Probe complete: %d/%d primary targets present in this build.", found, #M.TARGETS))

  if found == 0 then
    logger.warn("Health", "None of the expected health types exist. This is not the build "
                       .. "the trainer was written against. Infinite Health must stay disabled.")
  end

  return report
end

--- One-line status for the UI.
-- @return string
function M.status()
  return "probe available; run Discovery to collect members"
end

return M
