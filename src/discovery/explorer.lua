--[[--------------------------------------------------------------------------
  re7trainer.discovery.explorer — the type/singleton dump tool.

  THIS IS THE MOST IMPORTANT FILE IN THE PROJECT.

  Everything else here is scaffolding. This is the part that turns an unknown
  game build into a known one.

  WHY IT EXISTS
  -------------
  We know, from the user's own REFramework log, the NAMES of 36,534 types in
  RE7's type database (TDB version 70). What that log does not contain — and
  what no amount of reading files can recover — is the MEMBERS of those types:
  their methods, their parameters, their fields. That information only exists
  inside the running game process.

  So this module asks the running game directly, and writes the answer
  somewhere durable.

  OUTPUT
  ------
  Two destinations, because they fail independently:

    1. A JSON file via json.dump_file. This is the primary output. It lands on
       disk regardless of REFramework's "Log to disk" setting, and it is what
       the user sends back for analysis.
    2. The REFramework log via logger. This is a human-readable summary so the
       user can confirm something happened without opening a file.

  RATE LIMITING
  -------------
  Nothing here runs per frame. Every dump is triggered by an explicit button
  press and is guarded by a re-entrancy flag, because walking every method of
  every type is genuinely expensive and doing it twice concurrently would stall
  the game.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local types = require("re7trainer.utils.type_helpers")
local objects = require("re7trainer.utils.object_helpers")

local M = {}

--- Where dumps are written, relative to the game working directory.
M.OUTPUT_FILE = "re7trainer_discovery.json"

--- Guard against two dumps running at once.
local running = false

-- ---------------------------------------------------------------------------
-- Candidate lists
--
-- These names are NOT guesses. Every one was extracted verbatim from the
-- user's own REFramework log (TDB version 70) and re-verified by exact-match
-- grep before being written here. The comment on each group records why it is
-- considered relevant, so a future reader can re-derive the reasoning instead
-- of trusting it.
--
-- Being on this list means "worth asking about", NOT "confirmed to be the
-- thing that controls X". The dump is how we find out which is which.
-- ---------------------------------------------------------------------------

--- Types to interrogate, grouped by the subsystem they might serve.
M.CANDIDATE_TYPES = {
  -- Main-game player status. `app.PlayerStatus` exists unprefixed alongside
  -- app.CH8PlayerStatus / app.CH9PlayerStatus; the unprefixed one is the
  -- main-game candidate, but which scenario each CH variant belongs to is an
  -- open question this dump is partly designed to answer.
  player_status = {
    "app.PlayerStatus",
    "app.CH8PlayerStatus",
    "app.CH9PlayerStatus",
    "app.IPlayerStatus",
    "app.PlayerStatus.PlayerSaveDataClass",
  },

  -- Health. app.PlayerMaxHealthTable is the single most promising name in the
  -- whole database: it implies health is bounded by table-driven maximums,
  -- which would give us a principled ceiling to preserve against rather than
  -- an invented constant.
  --
  -- app.fsm.HealthSet and app.HealthInfo came out of a broader sweep and are
  -- strong additions: RE Engine implements gameplay actions as FSM nodes, and
  -- a node literally named "HealthSet" is a plausible single place where the
  -- health value is written — which would make the "preserve" strategy far
  -- more tractable than watching a raw field.
  health = {
    "app.PlayerMaxHealthTable",
    "app.HealthInfo",
    "app.fsm.HealthSet",
    "app.CharacterCommonStatus",
    "app.PlayerBase",
    "app.PlayerResurrection",
    "app.PlayerBreathController",
    "app.PlayerBreathController.HealthConditionEnum",
    "app.CharacterDefine",
    "app.CharacterDefine.Vitality",
    "app.ItemHealthRecover",
    "app.PlayerLArmDamage",
  },

  -- Damage path. app.PlayerDamageController is the player's own controller;
  -- app.DamageController and app.Collision.DamageManager are the shared
  -- pipeline that everything routes through. Which of these is hookable, and
  -- which is merely a recorder, is exactly what we need to learn.
  damage = {
    "app.PlayerDamageController",
    "app.PlayerDamageController.DamageGUIController",
    "app.PlayerDamageControllerSaveData",
    "app.DamageController",
    "app.DamageController.DamageRecord",
    "app.Collision.DamageManager",
    "app.Collision.CalculateDamage",
    "app.Collision.DamageUserData",
    "app.Collision.HitController",
    "app.Collision.HitController.DamageInfo",
    "app.Collision.HitController.DamageValue",
    "app.fsm.CH8PlayerDamageCheck",
    "app.CH8HUDControl.Damage",
  },

  -- Weapons and ammunition. app.PlayerGun is the unprefixed main-game gun.
  -- Whether the magazine count lives on the gun or in the inventory is the
  -- central question for infinite ammo.
  --
  -- app.WeaponGun / app.WeaponGun.BulletInfo and app.Cartridge* came out of a
  -- broader sweep. A type literally named "Cartridge" is a strong candidate for
  -- the ammunition entity, and app.WeaponGun looks like the base or the actual
  -- implementation behind app.PlayerGun.
  weapon = {
    "app.PlayerGun",
    "app.CH8PlayerGun",
    "app.CH9PlayerGun",
    "app.WeaponGun",
    "app.WeaponGun.BulletInfo",
    "app.WeaponGun.WeaponGunSaveData",
    "app.WeaponGunParameter",
    "app.Weapon",
    "app.WeaponData",
    "app.WeaponItem",
    "app.Cartridge",
    "app.CartridgeData",
    "app.CartridgeRequester",
    "app.PlayerWeaponChange",
    "app.PlayerWeaponChange.ItemType",
    "app.PlayerReloadSpeedRateTable",
    "app.PlayerEquipCheck",
    "app.EquipManager",
    "app.PlayerMelee",
    "app.PlayerThrowable",
    "app.BulletBase",
    "app.BulletID",
  },

  -- Inventory and items. app.InventoryManager is a CONFIRMED managed
  -- singleton — it appeared as app.SingletonBehavior`1<app.InventoryManager>
  -- in the type dump, which is how the engine declares singleton managers.
  --
  -- The two most important additions from the broader sweep:
  --   app.Item.ItemCategoryType  — a category enum on the item itself. This is
  --     the leading candidate for distinguishing a stackable consumable from a
  --     key item, which is a HARD PRECONDITION for Infinite Items.
  --   app.Inventory / app.ItemSlotData / app.ItemSlotManager — the container
  --     and slot model, i.e. where a quantity plausibly lives.
  inventory = {
    "app.InventoryManager",
    "app.InventorySystem",
    "app.Inventory",
    "app.Inventory.ItemInfo",
    "app.InventoryItemInfo",
    "app.ItemManager",
    "app.ItemResourceManager",
    "app.Item",
    "app.Item.ItemCategoryType",
    "app.Item.ITEMSTATE",
    "app.Item.ItemSlotSize",
    "app.Item.ItemSaveData",
    "app.ItemID",
    "app.ItemData",
    "app.ItemSlotData",
    "app.ItemSlotManager",
    "app.ItemSettings",
    "app.ItemSettingsContainer",
    "app.ItemBoxData",
    "app.InventoryItemBox",
    "app.PlayerItem",
    "app.PlayerItemDesc",
    "app.AddItem",
    "app.AddItemListData",
    "app.CraftItemManager",
    "app.AdditionalItemManager",
  },

  -- Game/scene state. Needed so the trainer can refuse to act while the
  -- player is in a menu, a cutscene, a load, or dead.
  gamestate = {
    "app.GameManager",
    "app.GameManager.PlayerChangeState",
    "app.GameFlowFsmManager",
    "app.MenuManager",
    "app.AAASceneTransitionController",
    "app.NowLoadingMovieManager",
    "app.TimeLinePlayStateControlManager",
    "app.CH8PlayerSequenceManager",
  },
}

--- Managed singletons to probe.
--
-- Every name here appeared inside app.SingletonBehavior`1<...> in the user's
-- type dump, which is the engine's own declaration of "this is a managed
-- singleton". That makes this list unusually trustworthy: these are not
-- plausible names, they are the engine telling us these are singletons.
M.CANDIDATE_SINGLETONS = {
  "app.InventoryManager",
  "app.InventorySystem",
  "app.ItemManager",
  "app.ItemResourceManager",
  "app.CraftItemManager",
  "app.AdditionalItemManager",
  "app.Collision.DamageManager",
  "app.Collision.CollisionSystem",
  "app.GameManager",
  "app.GameFlowFsmManager",
  "app.MenuManager",
  "app.OptionManager",
  "app.SaveDataManager",
  "app.CharacterExistManager",
  "app.ObjectManager",
  "app.AAASceneTransitionController",
  "app.NowLoadingMovieManager",
  "app.PlayerJunkPartsManager",
}

-- ---------------------------------------------------------------------------
-- Dump operations
-- ---------------------------------------------------------------------------

--- Probe every candidate singleton and record which ones actually resolve.
--
-- A singleton that is not yet constructed (we are on the main menu) returns
-- nil even though the type exists. The dump records which of the three states
-- each name is in — type missing / type present but not constructed /
-- constructed — because those imply very different next steps.
-- @return table
function M.dump_singletons()
  local results = {}

  for _, name in ipairs(M.CANDIDATE_SINGLETONS) do
    local type_exists = types.exists(name)
    local instance = safe.singleton(name)
    local instance_type = nil

    if instance ~= nil then
      instance_type = objects.type_name(instance)
    end

    results[#results + 1] = {
      name = name,
      type_exists = type_exists,
      constructed = instance ~= nil,
      instance_type = instance_type,
    }
  end

  return results
end

--- Dump every candidate type, grouped by subsystem.
-- @return table
function M.dump_all_candidates()
  local groups = {}

  for group, names in pairs(M.CANDIDATE_TYPES) do
    local entries = {}
    for _, name in ipairs(names) do
      entries[#entries + 1] = types.dump_type(name)
    end
    groups[group] = entries
  end

  return groups
end

--- Assemble the full discovery payload.
-- @return table
function M.build_payload()
  local payload = {
    schema = "re7trainer-discovery",
    schema_version = 1,
    environment = {
      game_name = state.runtime.game_name,
      sdk_available = state.runtime.sdk_available,
      trainer_frame = logger.frame(),
    },
    singletons = M.dump_singletons(),
    types = M.dump_all_candidates(),
  }

  -- Flatten a one-line summary so the JSON is scannable without tooling.
  local found, missing = 0, 0
  for _, entries in pairs(payload.types) do
    for _, entry in ipairs(entries) do
      if entry.found then
        found = found + 1
      else
        missing = missing + 1
      end
    end
  end
  payload.summary = {
    candidate_types_found = found,
    candidate_types_missing = missing,
    singletons_constructed = 0,
  }

  for _, entry in ipairs(payload.singletons) do
    if entry.constructed then
      payload.summary.singletons_constructed = payload.summary.singletons_constructed + 1
    end
  end

  return payload
end

--- Run a full discovery pass and write the result to disk.
-- @return boolean ok, string|nil path_or_error
function M.run()
  if running then
    return false, "a discovery pass is already running"
  end

  if not state.runtime.sdk_available then
    return false, "REFramework SDK is not available"
  end

  running = true
  local started = logger.frame()

  local ok, payload = pcall(M.build_payload)
  if not ok then
    running = false
    logger.error("Discovery", "Discovery pass failed: " .. tostring(payload))
    state.note_error()
    return false, tostring(payload)
  end

  state.runtime.discovery_runs = state.runtime.discovery_runs + 1

  -- Primary output: a file on disk.
  local wrote_file = false
  if type(json) == "table" and type(json.dump_file) == "function" then
    local dump_ok, dump_err = pcall(json.dump_file, M.OUTPUT_FILE, payload)
    if dump_ok then
      wrote_file = true
      state.runtime.last_dump_path = M.OUTPUT_FILE
    else
      logger.error("Discovery", "Could not write " .. M.OUTPUT_FILE .. ": " .. tostring(dump_err))
    end
  end

  -- Secondary output: a human-readable summary in the log.
  logger.info("Discovery", string.format(
    "Pass complete in %d frame(s). Candidate types: %d found / %d missing. Singletons constructed: %d.",
    logger.frame() - started,
    payload.summary.candidate_types_found,
    payload.summary.candidate_types_missing,
    payload.summary.singletons_constructed))

  if wrote_file then
    logger.info("Discovery", "Full dump written to " .. M.OUTPUT_FILE)
  else
    logger.warn("Discovery", "Could not write the dump file. Details are in the log only.")
  end

  state.runtime.discovery_last = payload.summary
  running = false

  return true, wrote_file and M.OUTPUT_FILE or nil
end

--- Is a discovery pass currently running?
-- @return boolean
function M.is_running()
  return running
end

--- Names that were looked for and NOT found, for a given group.
-- Useful for a quick "what is different about this build" read.
-- @param group string
-- @return table array of string
function M.missing_in_group(group)
  local names = M.CANDIDATE_TYPES[group]
  if names == nil then
    return {}
  end

  local missing = {}
  for _, name in ipairs(names) do
    if not types.exists(name) then
      missing[#missing + 1] = name
    end
  end
  return missing
end

--- Every candidate type name across all groups, deduplicated.
-- Used by the probes so they search a known-good list rather than the whole DB.
-- @return table array of string
function M.all_candidate_names()
  local seen = {}
  local out = {}

  for _, names in pairs(M.CANDIDATE_TYPES) do
    for _, name in ipairs(names) do
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end

  return out
end

return M
