--[[--------------------------------------------------------------------------
  re7trainer.discovery.ammo_probe — locate the weapon and ammunition path.

  WHAT WE KNOW (verified, from the user's own type dump)
  -----------------------------------------------------
    app.PlayerGun                   exists, unprefixed -> main-game weapon
    app.PlayerWeaponChange          exists, with nested .ItemType
    app.PlayerReloadSpeedRateTable  exists
    app.PlayerEquipCheck            exists
    app.PlayerMelee                 exists (with .WeaponParam)
    app.PlayerThrowable             exists
    app.BulletBase / app.BulletID   exist (likely projectiles, not inventory ammo)

  WHAT WE DO NOT KNOW
  -------------------
  Where the ammunition count actually lives, and what consumes it.

  THE DISTINCTION THAT MATTERS
  ----------------------------
  Three different quantities are all called "ammo" and they are not
  interchangeable:

    (a) magazine ammo   — rounds currently in the weapon
    (b) reserve ammo    — rounds held outside the weapon
    (c) ammo item       — the inventory stack that feeds (b)

  The trainer's stated requirement is that firing leaves the count unchanged:
  twelve rounds stays twelve. That is a very different intervention from
  "set the count to 999999", and it means we need (a), or the consumption
  operation that decrements (a), or both.

  Making this probe print a single "ammo" number would actively hide that
  distinction, so it deliberately does not.

  FALSE POSITIVES TO WATCH FOR
  ----------------------------
  app.CH8Gunturret / app.CH8GunturretManager are enemy turrets, not the
  player's gun — the substring "gun" matches them and they are not in the
  target list for that reason.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local types = require("re7trainer.utils.type_helpers")
local safe = require("re7trainer.utils.safe_call")

local M = {}

M.NAME = "ammo"

--- Types this probe interrogates, most-likely-first.
M.TARGETS = {
  -- The main-game weapon. If magazine ammo lives anywhere, it is most likely
  -- attached to this object.
  "app.PlayerGun",

  -- The likely implementation/base behind the player weapon, plus the type
  -- whose name most directly suggests the ammunition itself. app.Cartridge is
  -- the strongest candidate for "a round of ammunition" as an object.
  "app.WeaponGun",
  "app.WeaponGun.BulletInfo",
  "app.Cartridge",
  "app.CartridgeData",

  -- Weapon switching / equipping. If the weapon object is swapped rather than
  -- mutated, the swap is where a stale handle would break us.
  "app.PlayerWeaponChange",
  "app.PlayerEquipCheck",
  "app.EquipManager",

  -- Throwables and melee have their own counts; worth knowing whether they
  -- share a base class with firearms.
  "app.PlayerThrowable",
  "app.PlayerMelee",

  -- Reload behaviour. Not needed for "no consumption", but it tells us whether
  -- reloading is a separate code path we would have to account for.
  "app.PlayerReloadSpeedRateTable",
}

--- Scenario mirrors, dumped for comparison against the unprefixed versions.
M.SCENARIO_TARGETS = {
  "app.CH8PlayerGun",
  "app.CH9PlayerGun",
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

  report.notes[#report.notes + 1] =
    "Reports type members only. It does not distinguish magazine ammo from reserve "
    .. "ammo from the inventory ammo stack; separating those requires reading the "
    .. "field list and then observing which one changes when you fire."

  local found = 0
  for _, entry in ipairs(report.targets) do
    if entry.found then
      found = found + 1
    end
  end

  logger.info("Ammo", string.format(
    "Probe complete: %d/%d weapon targets present in this build.", found, #M.TARGETS))

  if found == 0 then
    logger.warn("Ammo", "No expected weapon types found. Infinite Ammo must stay disabled.")
  end

  return report
end

--- One-line status for the UI.
-- @return string
function M.status()
  return "probe available; run Discovery to collect members"
end

return M
