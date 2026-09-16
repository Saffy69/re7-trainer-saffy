--[[--------------------------------------------------------------------------
  re7trainer.game — RE7-specific accessors.

  This is the only module that knows the concrete shape of RE7's object graph.
  Keeping it in one place means that when a field is renamed by a game update,
  or a route turns out to be wrong, there is exactly one file to fix — and the
  cheats above it stay written in terms of "the inventory" and "the player"
  rather than in terms of field reads.

  EVERY ROUTE HERE CAME FROM A LIVE DISCOVERY DUMP. See docs/DISCOVERY_RESULTS.md.
  None of it is inferred from a type name.
----------------------------------------------------------------------------]]

local safe = require("re7trainer.utils.safe_call")
local objects = require("re7trainer.utils.object_helpers")
local logger = require("re7trainer.logger")

local M = {}

-- ---------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------

--- The active player inventory.
--
-- Two independent routes exist, and both are attempted because each can fail
-- in a different situation:
--
--   A. app.Inventory.getActivePlayerInventory() -- a static method, no
--      singleton lookup, no field read. Preferred: it cannot hold a stale
--      reference and it re-resolves against the live game every call.
--   B. sdk.get_managed_singleton("app.InventoryManager")._Inventory --
--      the singleton is confirmed constructed at runtime, and _Inventory is
--      its own field. Used as a fallback.
--
-- Called fresh every time on purpose. Caching either would risk holding a
-- reference across a scene change, which is where trainers crash.
--
-- @return userdata|nil app.Inventory
function M.inventory()
  -- Route A: app.Inventory.getActivePlayerInventory(), a static method.
  --
  -- Called through the REMethodDefinition's own `call`, which is registered on
  -- that type in this build. is_static is checked first: calling a method with
  -- a nil receiver is only correct for a static, and getting that wrong is the
  -- kind of mistake that reads as a game crash rather than a Lua error.
  local type_definition = safe.type_definition("app.Inventory")
  if type_definition ~= nil then
    local ok, method = pcall(function()
      return type_definition:get_method("getActivePlayerInventory")
    end)

    if ok and method ~= nil then
      local is_static = safe.try(method, "is_static")
      if is_static == true then
        local called, result = pcall(function()
          return method:call(nil)
        end)
        if called and result ~= nil then
          return result
        end
      end
    end
  end

  -- Route B: the managed singleton, whose _Inventory field is the inventory.
  local manager = safe.singleton("app.InventoryManager")
  if manager ~= nil then
    local inventory = objects.get(manager, "_Inventory")
    if inventory ~= nil then
      return inventory
    end
  end

  return nil
end

--- The player's status component.
--
-- app.PlayerStatus is the hub: it holds PlayerGun, Inventory, EquipManager and
-- PlayerDamageController as fields. Health accessors are inherited from
-- app.CharacterCommonStatus, which is where get_health / get_maxHealth /
-- get_IsDead / set_isForbidDamageReaction come from.
--
-- The field is typed app.IPlayerStatus (an interface). Method calls go through
-- REFramework's dynamic dispatch on the concrete object, so the inherited
-- accessors resolve normally — but the type check below is deliberately done
-- against the live object rather than trusting the declared field type.
--
-- @return userdata|nil
function M.player_status()
  local inventory = M.inventory()
  if inventory == nil then
    return nil
  end

  local status = objects.get(inventory, "PlayerStatus")
  if status == nil then
    return nil
  end

  if not objects.is_valid(status) then
    return nil
  end

  return status
end

--- The player's damage controller.
-- Preferred hook target for preventing damage; also a useful fallback source
-- for the max-health table reference.
-- @return userdata|nil
function M.damage_controller()
  local status = M.player_status()
  if status == nil then
    return nil
  end
  return objects.get(status, "PlayerDamageController")
end

-- ---------------------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------------------

--- Current and maximum health, or nil if unreadable.
-- @return table|nil { current = number, max = number, normalized = number }
function M.health()
  local status = M.player_status()
  if status == nil then
    return nil
  end

  local current = safe.to_number(objects.call(status, "get_health"))
  local maximum = safe.to_number(objects.call(status, "get_maxHealth"))

  if current == nil then
    return nil
  end

  return {
    current = current,
    max = maximum,
    normalized = safe.to_number(objects.call(status, "get_normalizedHealth")),
  }
end

--- Is the player dead, according to the game?
-- @return boolean|nil
function M.is_dead()
  local status = M.player_status()
  if status == nil then
    return nil
  end
  local value = objects.call(status, "get_IsDead")
  if type(value) == "boolean" then
    return value
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Items and their categories
-- ---------------------------------------------------------------------------

--- Item categories the trainer is allowed to conserve.
--
-- This is the list that makes Infinite Items safe. Everything NOT in this set
-- is treated as untouchable, which is the conservative direction and the one
-- that cannot corrupt a save.
--
--   Drug      herbs, first aid -- stackable, consumed
--   Material  chem fluids, crafting -- stackable, consumed
--   Shell     ammunition -- stackable, consumed
--
-- Deliberately absent, and therefore never touched:
--   KeyItem, UsableKeyItem, DiscardableKeyItem  -- key items gate puzzles;
--       duplicating one can make a run unrecoverable
--   Weapon, StackWeapon                          -- not consumables
--   File, Map                                    -- documents
--   SupplyBox, OtherItem                         -- not proven stackable
--
-- The enum members were read out of app.Item.ItemCategoryType in a live dump.
M.SAFE_CATEGORIES = {
  Drug = true,
  Material = true,
  Shell = true,
}

--- The carried items, as a plain Lua array of app.Inventory.ItemInfo.
-- @return table array (possibly empty)
function M.item_infos()
  local inventory = M.inventory()
  if inventory == nil then
    return {}
  end

  local raw = objects.call(inventory, "get_ItemList")
  return require("re7trainer.utils.type_helpers").to_array(raw)
end

--- The category name of an app.Item, or nil.
--
-- The category lives on app.ItemData, reached through the item's _ItemData
-- field. It is the engine's own classification, not something derived from the
-- item's name or id — which is what makes it trustworthy enough to gate a
-- destructive operation on.
--
-- @param item userdata app.Item
-- @return string|nil
function M.item_category(item)
  if item == nil then
    return nil
  end

  local item_data = objects.call(item, "get_ItemData")
  if item_data == nil then
    item_data = objects.get(item, "_ItemData")
  end
  if item_data == nil then
    return nil
  end

  -- The first enum member is the zero value and shares the enum's own name in
  -- some layouts; treat anything non-string as unknown rather than guessing.
  local category = objects.get(item_data, "Category")
  if type(category) == "string" then
    return category
  end

  -- Enum values can surface as userdata; try to read a name off it.
  local name = safe.try(category, "get_name") or safe.try(category, "ToString")
  if type(name) == "string" then
    return name
  end

  return nil
end

--- Is this item safe for the trainer to conserve?
--
-- Fails CLOSED: an item whose category cannot be read is not safe. That is the
-- whole point -- an unreadable category is exactly the case where a guess
-- could touch a key item.
--
-- @param item userdata app.Item
-- @return boolean safe, string reason
function M.is_safe_to_conserve(item)
  local category = M.item_category(item)

  if category == nil then
    return false, "category unreadable"
  end

  if M.SAFE_CATEGORIES[category] then
    return true, category
  end

  return false, "category '" .. category .. "' is not conservable"
end

--- How many items are currently classified as safe to conserve.
-- Surfaced in the UI so the state is visible rather than implied.
-- @return number safe, number total
function M.count_safe_items()
  local safe_count, total = 0, 0

  for _, info in ipairs(M.item_infos()) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      total = total + 1
      if M.is_safe_to_conserve(item) then
        safe_count = safe_count + 1
      end
    end
  end

  return safe_count, total
end

-- ---------------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------------

--- The currently equipped gun, or nil.
--
-- Reached from app.PlayerStatus.PlayerGun. The inventory item list also carries
-- a Gun reference per item (app.Inventory.ItemInfo.Gun), which is the better
-- route if this one returns nil — an equipped-weapon field can legitimately be
-- empty while the player is unarmed.
-- @return userdata|nil app.WeaponGun
function M.equipped_gun()
  local status = M.player_status()
  if status == nil then
    return nil
  end

  local gun = objects.get(status, "PlayerGun")
  if gun ~= nil and objects.is_valid(gun) then
    return gun
  end

  return nil
end

--- Magazine and reserve counts for a gun, or nil.
-- @param gun userdata|nil defaults to the equipped gun
-- @return table|nil { magazine = number, magazine_max = number, reserve = number }
function M.gun_ammo(gun)
  gun = gun or M.equipped_gun()
  if gun == nil then
    return nil
  end

  local magazine = safe.to_number(objects.call(gun, "get_loadNum"))
  if magazine == nil then
    return nil
  end

  return {
    magazine = magazine,
    magazine_max = safe.to_number(objects.call(gun, "get_maxLoadNum")),
    reserve = safe.to_number(objects.call(gun, "get_bulletStackNum")),
  }
end

return M
